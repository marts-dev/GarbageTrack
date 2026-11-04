import pytest


@pytest.fixture
def dispatcher(client, make_user):
    return make_user("logistics")


@pytest.fixture
def collector(client, make_user):
    return make_user("collector")


def _make_truck(client, headers, **overrides):
    payload = {
        "plate_number": "TRK-1",
        "garbage_types": ["plastic", "organic"],
        "status": "enroute",
        "current_location": {"longitude": 3.37, "latitude": 6.45},
        "capacity": 10,
    }
    payload.update(overrides)
    response = client.post("/api/v1/trucks/schedules", json=payload, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


def _assign(client, truck_id, operator_id, headers):
    response = client.patch(
        f"/api/v1/trucks/{truck_id}", json={"operator_id": operator_id}, headers=headers
    )
    assert response.status_code == 200, response.text
    return response.json()


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


def _make_facility(client, headers):
    payload = {
        "name": "North Depot",
        "kind": "dump_site",
        "location": {"longitude": 3.38, "latitude": 6.46},
        "accepted_types": ["plastic"],
        "address": "1 Depot Rd",
    }
    response = client.post("/api/v1/logistics/facilities", json=payload, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


def _make_route(client, headers, truck_id, depot_id, post_ids):
    response = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": truck_id, "post_ids": post_ids, "depot_ids": [depot_id]},
        headers=headers,
    )
    assert response.status_code == 201, response.text
    return response.json()


def test_read_truck_and_404(client, dispatcher, collector):
    truck = _make_truck(client, dispatcher["headers"])
    response = client.get(f"/api/v1/trucks/{truck['id']}", headers=collector["headers"])
    assert response.status_code == 200
    assert response.json()["plate_number"] == "TRK-1"
    assert response.json()["availability"] == "available"
    assert response.json()["load"] == 0

    assert (
        client.get("/api/v1/trucks/000000000000000000000000", headers=collector["headers"]).status_code
        == 404
    )
    assert client.get("/api/v1/trucks/not-an-id", headers=collector["headers"]).status_code == 404


def test_route_limited_by_capacity_and_truck_types(client, dispatcher, collector, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"], capacity=1)
    _make_post(client, resident, types=["plastic"])
    _make_post(client, resident, types=["plastic"])
    _make_post(client, resident, types=["glass"])

    response = client.get(f"/api/v1/trucks/{truck['id']}/route", headers=collector["headers"])
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["remaining_capacity"] == 1
    assert body["origin"] == {"type": "Point", "coordinates": [3.37, 6.45]}
    assert len(body["stops"]) == 1
    assert body["stops"][0]["types"] == ["plastic"]


def test_route_type_narrowing_intersects_truck_types(client, dispatcher, collector, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    plastic = _make_post(client, resident, types=["plastic"])
    organic = _make_post(client, resident, types=["organic"])

    narrowed = client.get(
        f"/api/v1/trucks/{truck['id']}/route",
        params={"types": "organic"},
        headers=collector["headers"],
    )
    assert narrowed.status_code == 200
    assert [s["post_id"] for s in narrowed.json()["stops"]] == [organic["id"]]

    outside = client.get(
        f"/api/v1/trucks/{truck['id']}/route",
        params={"types": "glass"},
        headers=collector["headers"],
    )
    assert outside.status_code == 200
    assert outside.json()["stops"] == []

    assert plastic["id"]
    default = client.get(f"/api/v1/trucks/{truck['id']}/route", headers=collector["headers"])
    assert len(default.json()["stops"]) == 2


def test_route_requires_a_location(client, dispatcher, collector, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"], current_location=None)
    _make_post(client, resident)

    missing = client.get(f"/api/v1/trucks/{truck['id']}/route", headers=collector["headers"])
    assert missing.status_code == 400

    override = client.get(
        f"/api/v1/trucks/{truck['id']}/route",
        params={"longitude": 3.37, "latitude": 6.45},
        headers=collector["headers"],
    )
    assert override.status_code == 200
    assert len(override.json()["stops"]) == 1


def test_route_empty_when_truck_full(client, dispatcher, collector, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"], capacity=1)
    _make_post(client, resident)
    _assign(client, truck["id"], collector["id"], dispatcher["headers"])
    collect = client.post(
        f"/api/v1/trucks/{truck['id']}/collect-vicinity", json={}, headers=collector["headers"]
    )
    assert collect.json()["load"] == 1

    response = client.get(f"/api/v1/trucks/{truck['id']}/route", headers=collector["headers"])
    assert response.status_code == 200
    assert response.json()["remaining_capacity"] == 0
    assert response.json()["stops"] == []


def test_collect_vicinity_marks_posts_and_updates_load(client, dispatcher, collector, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"], capacity=5)
    p1 = _make_post(client, resident, types=["plastic"])
    _make_post(client, resident, types=["glass"])
    _assign(client, truck["id"], collector["id"], dispatcher["headers"])

    response = client.post(
        f"/api/v1/trucks/{truck['id']}/collect-vicinity",
        json={"radius_meters": 1000},
        headers=collector["headers"],
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["collected_count"] == 1
    assert body["post_ids"] == [p1["id"]]
    assert body["load"] == 1
    assert body["availability"] == "available"

    marked = client.get(f"/api/v1/garbage/{p1['id']}", headers=resident["headers"]).json()
    assert marked["status"] == "pending_confirmation"
    assert marked["collected_at"] is not None


def test_collect_vicinity_defaults_to_30m_radius():
    from app.schemas.trucks import CollectVicinityRequest

    assert CollectVicinityRequest().radius_meters == 30


def test_collect_candidates_previews_without_collecting(
    client, dispatcher, collector, make_user
):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"], capacity=5)
    p1 = _make_post(client, resident, types=["plastic"])
    _make_post(client, resident, types=["glass"])
    _assign(client, truck["id"], collector["id"], dispatcher["headers"])

    response = client.get(
        f"/api/v1/trucks/{truck['id']}/collect-candidates",
        headers=collector["headers"],
    )
    assert response.status_code == 200, response.text
    assert [p["id"] for p in response.json()] == [p1["id"]]

    # Nothing was written: the post is still posted and the load untouched.
    assert (
        client.get(f"/api/v1/garbage/{p1['id']}", headers=resident["headers"]).json()["status"]
        == "posted"
    )
    assert (
        client.get(f"/api/v1/trucks/{truck['id']}", headers=collector["headers"]).json()["load"]
        == 0
    )


def test_collect_candidates_matches_collect_guard(client, dispatcher, collector, make_user):
    other = make_user("collector")
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    _make_post(client, resident)
    _assign(client, truck["id"], collector["id"], dispatcher["headers"])

    assert (
        client.get(
            f"/api/v1/trucks/{truck['id']}/collect-candidates", headers=other["headers"]
        ).status_code
        == 403
    )
    assert (
        client.get(
            f"/api/v1/trucks/{truck['id']}/collect-candidates",
            headers=dispatcher["headers"],
        ).status_code
        == 200
    )
    assert (
        client.get(
            "/api/v1/trucks/000000000000000000000000/collect-candidates",
            headers=collector["headers"],
        ).status_code
        == 404
    )


def test_collect_vicinity_needs_location_and_truck(client, dispatcher, collector):
    truck = _make_truck(client, dispatcher["headers"], current_location=None)
    _assign(client, truck["id"], collector["id"], dispatcher["headers"])
    assert (
        client.post(
            f"/api/v1/trucks/{truck['id']}/collect-vicinity", json={}, headers=collector["headers"]
        ).status_code
        == 400
    )
    assert (
        client.post(
            "/api/v1/trucks/000000000000000000000000/collect-vicinity",
            json={},
            headers=collector["headers"],
        ).status_code
        == 404
    )


def test_finish_route_closes_run_and_frees_truck(
    client, dispatcher, collector, make_user
):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"], capacity=5)
    collected_post = _make_post(client, resident)
    skipped_post = _make_post(client, resident, types=["organic"])
    _assign(client, truck["id"], collector["id"], dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    route = _make_route(
        client,
        dispatcher["headers"],
        truck["id"],
        depot["id"],
        [collected_post["id"], skipped_post["id"]],
    )
    assert route["status"] == "assigned"
    reread = client.get(
        f"/api/v1/trucks/{truck['id']}", headers=collector["headers"]
    )
    assert reread.json()["availability"] == "working"

    # The fake DB ignores distance, so narrow the run to plastic explicitly.
    collected = client.post(
        f"/api/v1/trucks/{truck['id']}/collect-vicinity",
        json={"types": ["plastic"]},
        headers=collector["headers"],
    )
    assert collected.json()["collected_count"] == 1
    started = client.get(
        f"/api/v1/logistics/routes/{route['id']}", headers=dispatcher["headers"]
    )
    assert started.json()["status"] == "in_progress"

    finished = client.post(
        f"/api/v1/trucks/{truck['id']}/finish-route", headers=collector["headers"]
    )
    assert finished.status_code == 200, finished.text
    assert finished.json()["availability"] == "available"

    done = client.get(
        f"/api/v1/logistics/routes/{route['id']}", headers=dispatcher["headers"]
    )
    assert done.json()["status"] == "done"
    skipped = client.get(
        f"/api/v1/garbage/{skipped_post['id']}", headers=resident["headers"]
    )
    assert skipped.json()["status"] == "posted"
    pending = client.get(
        f"/api/v1/garbage/{collected_post['id']}", headers=resident["headers"]
    )
    assert pending.json()["status"] == "pending_confirmation"

    again = client.post(
        f"/api/v1/trucks/{truck['id']}/finish-route", headers=collector["headers"]
    )
    assert again.status_code == 404


def test_collector_routes_require_collector_role(client, dispatcher, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    assert (
        client.get(f"/api/v1/trucks/{truck['id']}/route", headers=resident["headers"]).status_code
        == 403
    )
    assert (
        client.post(
            f"/api/v1/trucks/{truck['id']}/collect-vicinity", json={}, headers=resident["headers"]
        ).status_code
        == 403
    )
    assert (
        client.post(
            f"/api/v1/trucks/{truck['id']}/finish-route",
            headers=resident["headers"],
        ).status_code
        == 403
    )
    assert client.get(f"/api/v1/trucks/{truck['id']}/route").status_code == 401


@pytest.mark.parametrize("route", ["route", "collect-vicinity", "finish-route"])
def test_collector_routes_reject_unknown_truck(client, collector, route):
    if route == "route":
        response = client.get(
            "/api/v1/trucks/000000000000000000000000/route", headers=collector["headers"]
        )
    elif route == "collect-vicinity":
        response = client.post(
            "/api/v1/trucks/000000000000000000000000/collect-vicinity",
            json={},
            headers=collector["headers"],
        )
    else:
        response = client.post(
            "/api/v1/trucks/000000000000000000000000/finish-route",
            headers=collector["headers"],
        )
    assert response.status_code == 404
