"""Two-step collect flow: collect-vicinity marks pending, resident confirms."""

import pytest
from bson import ObjectId


@pytest.fixture
def dispatcher(client, make_user):
    return make_user("logistics")


@pytest.fixture
def collector(client, make_user):
    return make_user("collector")


def _make_post(client, user, **overrides):
    payload = {
        "user_id": user["id"],
        "longitude": 3.371,
        "latitude": 6.451,
        "types": ["plastic"],
    }
    payload.update(overrides)
    response = client.post("/api/v1/garbage", json=payload, headers=user["headers"])
    assert response.status_code == 201, response.text
    return response.json()


def _make_truck(client, headers, **overrides):
    payload = {
        "plate_number": "TRK-2STEP",
        "garbage_types": ["plastic"],
        "status": "enroute",
        "current_location": {"longitude": 3.37, "latitude": 6.45},
        "capacity": 10,
    }
    payload.update(overrides)
    response = client.post("/api/v1/trucks/schedules", json=payload, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


def _make_facility(client, headers, **overrides):
    payload = {
        "name": "Central Dump",
        "kind": "dump_site",
        "location": {"longitude": 3.38, "latitude": 6.46},
        "accepted_types": ["plastic", "metal"],
        "address": "1 Depot Rd",
    }
    payload.update(overrides)
    response = client.post("/api/v1/logistics/facilities", json=payload, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


def _make_route(client, headers, truck_id, depot_id, post_ids, **overrides):
    payload = {
        "truck_id": truck_id,
        "name": "Morning run",
        "post_ids": post_ids,
        "depot_ids": [depot_id],
    }
    payload.update(overrides)
    response = client.post("/api/v1/logistics/routes", json=payload, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


def _assign(client, truck_id, operator_id, headers):
    response = client.patch(
        f"/api/v1/trucks/{truck_id}", json={"operator_id": operator_id}, headers=headers
    )
    assert response.status_code == 200, response.text
    return response.json()


def _collect(client, truck_id, headers, **payload):
    response = client.post(
        f"/api/v1/trucks/{truck_id}/collect-vicinity", json=payload, headers=headers
    )
    assert response.status_code == 200, response.text
    return response.json()


def _status(client, post_id, headers):
    return client.get(f"/api/v1/garbage/{post_id}", headers=headers).json()


def test_collect_marks_pending_and_skips_it_afterwards(
    client, dispatcher, collector, make_user
):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    post = _make_post(client, resident)
    _assign(client, truck["id"], collector["id"], dispatcher["headers"])

    candidates = client.get(
        f"/api/v1/trucks/{truck['id']}/collect-candidates", headers=collector["headers"]
    )
    assert [p["id"] for p in candidates.json()] == [post["id"]]

    first = _collect(client, truck["id"], collector["headers"])
    assert first["collected_count"] == 1
    assert first["post_ids"] == [post["id"]]
    marked = _status(client, post["id"], resident["headers"])
    assert marked["status"] == "pending_confirmation"
    assert marked["collected_at"] is not None

    # Pending is done from the collector view: excluded from candidates,
    # and a second sweep skips it without bumping the load.
    candidates = client.get(
        f"/api/v1/trucks/{truck['id']}/collect-candidates", headers=collector["headers"]
    )
    assert candidates.json() == []
    second = _collect(client, truck["id"], collector["headers"])
    assert second["collected_count"] == 0
    assert second["load"] == 1


def test_confirm_pending_then_collected(client, dispatcher, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    post = _make_post(client, resident)
    _collect(client, truck["id"], dispatcher["headers"])

    confirmed = client.patch(
        f"/api/v1/garbage/{post['id']}/confirm-collected", headers=resident["headers"]
    )
    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json()["status"] == "collected"
    assert confirmed.json()["collected_at"] is not None

    again = client.patch(
        f"/api/v1/garbage/{post['id']}/confirm-collected", headers=resident["headers"]
    )
    assert again.status_code == 409
    assert again.json()["detail"] == "garbage already collected"


def test_confirm_from_posted_or_scheduled_has_nothing_to_confirm(
    client, dispatcher, make_user
):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    posted = _make_post(client, resident)
    scheduled = _make_post(client, resident)
    _make_route(client, dispatcher["headers"], truck["id"], depot["id"], [scheduled["id"]])
    assert _status(client, scheduled["id"], resident["headers"])["status"] == "scheduled"

    for post_id in (posted["id"], scheduled["id"]):
        response = client.patch(
            f"/api/v1/garbage/{post_id}/confirm-collected", headers=resident["headers"]
        )
        assert response.status_code == 409
        assert response.json()["detail"] == "nothing to confirm yet"


def test_dispute_reopens_pending_post(client, dispatcher, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    post = _make_post(client, resident)
    _collect(client, truck["id"], dispatcher["headers"])
    assert _status(client, post["id"], resident["headers"])["status"] == "pending_confirmation"

    disputed = client.patch(
        f"/api/v1/garbage/{post['id']}/dispute-collected", headers=resident["headers"]
    )
    assert disputed.status_code == 200, disputed.text
    assert disputed.json()["status"] == "posted"
    assert disputed.json()["collected_at"] is None

    # Nothing left to confirm, but the post is collectable again.
    confirm = client.patch(
        f"/api/v1/garbage/{post['id']}/confirm-collected", headers=resident["headers"]
    )
    assert confirm.status_code == 409
    recollected = _collect(client, truck["id"], dispatcher["headers"])
    assert recollected["post_ids"] == [post["id"]]
    assert _status(client, post["id"], resident["headers"])["status"] == "pending_confirmation"


def test_dispute_non_pending_conflicts_and_unknown_404s(client, dispatcher, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    posted = _make_post(client, resident)
    collected = _make_post(client, resident)
    _collect(client, truck["id"], dispatcher["headers"], types=["plastic"])
    # Only `collected` should reach collected: dispute `posted` back first.
    client.patch(
        f"/api/v1/garbage/{posted['id']}/dispute-collected", headers=resident["headers"]
    )
    confirmed = client.patch(
        f"/api/v1/garbage/{collected['id']}/confirm-collected", headers=resident["headers"]
    )
    assert confirmed.status_code == 200, confirmed.text

    for post_id in (posted["id"], collected["id"]):
        response = client.patch(
            f"/api/v1/garbage/{post_id}/dispute-collected", headers=resident["headers"]
        )
        assert response.status_code == 409

    missing = client.patch(
        "/api/v1/garbage/000000000000000000000000/dispute-collected",
        headers=resident["headers"],
    )
    assert missing.status_code == 404


def test_dispute_is_owner_only(client, dispatcher, collector, make_user):
    resident = make_user()
    stranger = make_user()
    admin = make_user("admin")
    truck = _make_truck(client, dispatcher["headers"])
    post = _make_post(client, resident)
    _collect(client, truck["id"], dispatcher["headers"])

    for user in (stranger, collector, dispatcher, admin):
        response = client.patch(
            f"/api/v1/garbage/{post['id']}/dispute-collected", headers=user["headers"]
        )
        assert response.status_code == 403

    allowed = client.patch(
        f"/api/v1/garbage/{post['id']}/dispute-collected", headers=resident["headers"]
    )
    assert allowed.status_code == 200
    assert allowed.json()["status"] == "posted"


def test_confirm_guard_parity_owner_or_operations(
    client, dispatcher, collector, make_user
):
    resident = make_user()
    stranger = make_user()
    admin = make_user("admin")
    truck = _make_truck(client, dispatcher["headers"])
    posts = [_make_post(client, resident) for _ in range(4)]
    result = _collect(client, truck["id"], dispatcher["headers"])
    assert result["collected_count"] == 4

    denied = client.patch(
        f"/api/v1/garbage/{posts[0]['id']}/confirm-collected", headers=stranger["headers"]
    )
    assert denied.status_code == 403

    for post, user in (
        (posts[0], resident),
        (posts[1], collector),
        (posts[2], dispatcher),
        (posts[3], admin),
    ):
        response = client.patch(
            f"/api/v1/garbage/{post['id']}/confirm-collected", headers=user["headers"]
        )
        assert response.status_code == 200, response.text
        assert response.json()["status"] == "collected"


def test_planned_route_drops_pending_and_dispute_resurrects(
    client, dispatcher, collector, make_user
):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"], garbage_types=["plastic", "glass"])
    depot = _make_facility(client, dispatcher["headers"])
    plastic = _make_post(client, resident, types=["plastic"])
    glass = _make_post(client, resident, types=["glass"])
    _make_route(
        client, dispatcher["headers"], truck["id"], depot["id"], [plastic["id"], glass["id"]]
    )

    def stop_ids():
        planned = client.get(
            f"/api/v1/trucks/{truck['id']}/planned-route", headers=collector["headers"]
        )
        assert planned.status_code == 200, planned.text
        return [s["post_id"] for s in planned.json()["stops"]]

    assert stop_ids() == [plastic["id"], glass["id"]]

    # The fake DB ignores distance, so narrow the run to plastic explicitly.
    _collect(client, truck["id"], dispatcher["headers"], types=["plastic"])
    assert _status(client, plastic["id"], resident["headers"])["status"] == "pending_confirmation"
    assert stop_ids() == [glass["id"]]

    disputed = client.patch(
        f"/api/v1/garbage/{plastic['id']}/dispute-collected", headers=resident["headers"]
    )
    assert disputed.status_code == 200, disputed.text
    assert stop_ids() == [plastic["id"], glass["id"]]


def test_collection_assignment_returns_truck_and_route(
    client, dispatcher, collector, make_user
):
    resident = make_user()
    admin = make_user("admin")
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, resident)
    route = _make_route(
        client, dispatcher["headers"], truck["id"], depot["id"], [post["id"]]
    )

    for user in (resident, collector, dispatcher, admin):
        response = client.get(
            f"/api/v1/garbage/{post['id']}/collection", headers=user["headers"]
        )
        assert response.status_code == 200, response.text
        body = response.json()
        assert body == {
            "truck_id": truck["id"],
            "plate_number": truck["plate_number"],
            "truck_status": truck["status"],
            "route_id": route["id"],
            "route_name": route["name"],
            "route_status": route["status"],
        }


def test_collection_assignment_prefers_most_recent_route(
    client, dispatcher, make_user, fake_db
):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, resident)
    first = _make_route(
        client, dispatcher["headers"], truck["id"], depot["id"], [post["id"]], name="Old run"
    )
    second = _make_route(
        client, dispatcher["headers"], truck["id"], depot["id"], [post["id"]], name="New run"
    )
    assert first["id"] != second["id"]

    response = client.get(
        f"/api/v1/garbage/{post['id']}/collection", headers=resident["headers"]
    )
    assert response.status_code == 200, response.text
    assert response.json()["route_id"] == second["id"]
    assert response.json()["route_name"] == "New run"

    # A done route still attributes the pickup.
    fake_db["planned_routes"].docs[ObjectId(second["id"])]["status"] = "done"
    done = client.get(
        f"/api/v1/garbage/{post['id']}/collection", headers=resident["headers"]
    )
    assert done.status_code == 200
    assert done.json()["route_status"] == "done"

    # Cancelled routes are excluded: with both gone, there is no assignment.
    fake_db["planned_routes"].docs[ObjectId(first["id"])]["status"] = "cancelled"
    fake_db["planned_routes"].docs[ObjectId(second["id"])]["status"] = "cancelled"
    gone = client.get(
        f"/api/v1/garbage/{post['id']}/collection", headers=resident["headers"]
    )
    assert gone.status_code == 404


def test_collection_assignment_404_and_403(client, dispatcher, make_user):
    resident = make_user()
    stranger = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, resident)
    _make_route(client, dispatcher["headers"], truck["id"], depot["id"], [post["id"]])
    routeless = _make_post(client, resident)

    forbidden = client.get(
        f"/api/v1/garbage/{post['id']}/collection", headers=stranger["headers"]
    )
    assert forbidden.status_code == 403

    assert (
        client.get(
            f"/api/v1/garbage/{routeless['id']}/collection", headers=resident["headers"]
        ).status_code
        == 404
    )
    assert (
        client.get(
            "/api/v1/garbage/000000000000000000000000/collection",
            headers=resident["headers"],
        ).status_code
        == 404
    )
