"""Scheduled pickup dates on routes + the resident my-pickups query."""

from datetime import UTC, date, datetime, timedelta

from bson import ObjectId


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


def _make_truck(client, headers, plate="PICK-1"):
    response = client.post(
        "/api/v1/trucks/schedules",
        json={
            "plate_number": plate,
            "garbage_types": ["plastic"],
            "current_location": {"longitude": 3.37, "latitude": 6.45},
            "capacity": 10,
        },
        headers=headers,
    )
    assert response.status_code == 201, response.text
    return response.json()


def _make_facility(client, headers):
    response = client.post(
        "/api/v1/logistics/facilities",
        json={
            "name": "Pickup Depot",
            "kind": "waste_center",
            "location": {"longitude": 3.38, "latitude": 6.46},
            "accepted_types": ["plastic"],
        },
        headers=headers,
    )
    assert response.status_code == 201, response.text
    return response.json()


def _make_route(client, headers, truck_id, depot_id, post_ids, **overrides):
    payload = {
        "truck_id": truck_id,
        "name": "Pickup run",
        "post_ids": post_ids,
        "depot_ids": [depot_id],
    }
    payload.update(overrides)
    response = client.post("/api/v1/logistics/routes", json=payload, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


def test_create_route_defaults_scheduled_for_today(client, make_user):
    dispatcher = make_user("logistics")
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)

    body = _make_route(client, dispatcher["headers"], truck["id"], depot["id"], [post["id"]])
    # The server default is a UTC day, so compare in UTC, not local time.
    assert body["scheduled_for"] == datetime.now(UTC).date().isoformat()


def test_create_route_explicit_scheduled_for_roundtrip(client, make_user):
    dispatcher = make_user("logistics")
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)

    body = _make_route(
        client,
        dispatcher["headers"],
        truck["id"],
        depot["id"],
        [post["id"]],
        scheduled_for="2026-12-25",
    )
    assert body["scheduled_for"] == "2026-12-25"

    read = client.get(
        f"/api/v1/logistics/routes/{body['id']}", headers=dispatcher["headers"]
    )
    assert read.status_code == 200
    assert read.json()["scheduled_for"] == "2026-12-25"


def test_my_pickups_lists_own_scheduled_sorted(client, make_user):
    dispatcher = make_user("logistics")
    me = make_user()
    depot = _make_facility(client, dispatcher["headers"])
    truck_a = _make_truck(client, dispatcher["headers"], plate="PICK-A")
    truck_b = _make_truck(client, dispatcher["headers"], plate="PICK-B")
    early = _make_post(client, me)
    late = _make_post(client, me)
    today = date.today()
    _make_route(
        client,
        dispatcher["headers"],
        truck_a["id"],
        depot["id"],
        [late["id"]],
        name="Late run",
        scheduled_for=(today + timedelta(days=3)).isoformat(),
    )
    _make_route(
        client,
        dispatcher["headers"],
        truck_b["id"],
        depot["id"],
        [early["id"]],
        name="Early run",
        scheduled_for=(today + timedelta(days=1)).isoformat(),
    )

    response = client.get("/api/v1/garbage/mine/pickups", headers=me["headers"])
    assert response.status_code == 200, response.text
    pickups = response.json()
    assert [p["post_id"] for p in pickups] == [early["id"], late["id"]]
    assert pickups[0]["route_name"] == "Early run"
    assert pickups[0]["route_status"] == "assigned"
    assert pickups[0]["plate_number"] == "PICK-B"
    assert pickups[0]["types"] == ["plastic"]
    assert pickups[0]["scheduled_for"] == (today + timedelta(days=1)).isoformat()


def test_my_pickups_excludes_others_unscheduled_and_collected(client, make_user, fake_db):
    dispatcher = make_user("logistics")
    me = make_user()
    other = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    mine = _make_post(client, me)
    theirs = _make_post(client, other)
    unscheduled = _make_post(client, me)
    collected = _make_post(client, me)
    _make_route(
        client,
        dispatcher["headers"],
        truck["id"],
        depot["id"],
        [mine["id"], theirs["id"], collected["id"]],
    )
    # Collected posts stay on the route's stop list; the status filter drops them.
    fake_db["garbage_posts"].docs[ObjectId(collected["id"])]["status"] = "collected"

    response = client.get("/api/v1/garbage/mine/pickups", headers=me["headers"])
    assert response.status_code == 200, response.text
    assert [p["post_id"] for p in response.json()] == [mine["id"]]
    assert unscheduled["status"] == "posted"


def test_my_pickups_resolves_active_route_not_done(client, make_user, fake_db):
    dispatcher = make_user("logistics")
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)
    body = _make_route(client, dispatcher["headers"], truck["id"], depot["id"], [post["id"]])

    # A stale done-route copy of the same stop must not win attribution.
    active = fake_db["planned_routes"].docs[ObjectId(body["id"])]
    decoy = dict(active)
    decoy["_id"] = ObjectId()
    decoy["status"] = "done"
    decoy["name"] = "Old run"
    fake_db["planned_routes"].docs[decoy["_id"]] = decoy
    # The run started: the pickup reports in_progress.
    active["status"] = "in_progress"

    response = client.get("/api/v1/garbage/mine/pickups", headers=me["headers"])
    assert response.status_code == 200, response.text
    (pickup,) = response.json()
    assert pickup["route_name"] == "Pickup run"
    assert pickup["route_status"] == "in_progress"


def test_my_pickups_requires_auth(client):
    assert client.get("/api/v1/garbage/mine/pickups").status_code == 401


def test_my_pickups_rejects_non_residents(client, make_user):
    for role in ("collector", "logistics", "depot", "admin"):
        user = make_user(role)
        response = client.get("/api/v1/garbage/mine/pickups", headers=user["headers"])
        assert response.status_code == 403, (role, response.text)
        assert response.json()["detail"] == "only residents can view scheduled pickups"


def test_collection_assignment_includes_scheduled_for(client, make_user):
    dispatcher = make_user("logistics")
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)
    _make_route(
        client,
        dispatcher["headers"],
        truck["id"],
        depot["id"],
        [post["id"]],
        scheduled_for="2026-12-25",
    )

    response = client.get(
        f"/api/v1/garbage/{post['id']}/collection", headers=me["headers"]
    )
    assert response.status_code == 200, response.text
    assert response.json()["scheduled_for"] == "2026-12-25"
