import pytest


def _make_truck(client, **overrides):
    payload = {
        "plate_number": "TRK-1",
        "garbage_types": ["plastic", "organic"],
        "status": "enroute",
        "current_location": {"longitude": 3.37, "latitude": 6.45},
        "capacity": 10,
    }
    payload.update(overrides)
    response = client.post("/api/v1/trucks/schedules", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def _make_post(client, **overrides):
    payload = {
        "user_id": "u1",
        "longitude": 3.371,
        "latitude": 6.451,
        "types": ["plastic"],
    }
    payload.update(overrides)
    response = client.post("/api/v1/garbage", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def test_read_truck_and_404(client):
    truck = _make_truck(client)
    response = client.get(f"/api/v1/trucks/{truck['id']}")
    assert response.status_code == 200
    assert response.json()["plate_number"] == "TRK-1"
    assert response.json()["availability"] == "available"
    assert response.json()["load"] == 0

    assert client.get("/api/v1/trucks/000000000000000000000000").status_code == 404
    assert client.get("/api/v1/trucks/not-an-id").status_code == 404


def test_route_limited_by_capacity_and_truck_types(client):
    truck = _make_truck(client, capacity=1)
    _make_post(client, types=["plastic"])
    _make_post(client, types=["plastic"])
    _make_post(client, types=["glass"])

    response = client.get(f"/api/v1/trucks/{truck['id']}/route")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["remaining_capacity"] == 1
    assert body["origin"] == {"type": "Point", "coordinates": [3.37, 6.45]}
    assert len(body["stops"]) == 1
    assert body["stops"][0]["types"] == ["plastic"]


def test_route_type_narrowing_intersects_truck_types(client):
    truck = _make_truck(client)
    plastic = _make_post(client, types=["plastic"])
    organic = _make_post(client, types=["organic"])

    narrowed = client.get(f"/api/v1/trucks/{truck['id']}/route", params={"types": "organic"})
    assert narrowed.status_code == 200
    assert [s["post_id"] for s in narrowed.json()["stops"]] == [organic["id"]]

    outside = client.get(f"/api/v1/trucks/{truck['id']}/route", params={"types": "glass"})
    assert outside.status_code == 200
    assert outside.json()["stops"] == []

    assert plastic["id"]  # created for the default-types case below
    default = client.get(f"/api/v1/trucks/{truck['id']}/route")
    assert len(default.json()["stops"]) == 2


def test_route_requires_a_location(client):
    truck = _make_truck(client, current_location=None)
    _make_post(client)

    missing = client.get(f"/api/v1/trucks/{truck['id']}/route")
    assert missing.status_code == 400

    override = client.get(
        f"/api/v1/trucks/{truck['id']}/route", params={"longitude": 3.37, "latitude": 6.45}
    )
    assert override.status_code == 200
    assert len(override.json()["stops"]) == 1


def test_route_empty_when_truck_full(client):
    truck = _make_truck(client, capacity=1)
    _make_post(client)
    collect = client.post(f"/api/v1/trucks/{truck['id']}/collect-vicinity", json={})
    assert collect.json()["availability"] == "full"

    response = client.get(f"/api/v1/trucks/{truck['id']}/route")
    assert response.status_code == 200
    assert response.json()["remaining_capacity"] == 0
    assert response.json()["stops"] == []


def test_collect_vicinity_marks_posts_and_updates_load(client):
    truck = _make_truck(client, capacity=5)
    p1 = _make_post(client, types=["plastic"])
    _make_post(client, types=["glass"])

    response = client.post(
        f"/api/v1/trucks/{truck['id']}/collect-vicinity", json={"radius_meters": 1000}
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["collected_count"] == 1
    assert body["post_ids"] == [p1["id"]]
    assert body["load"] == 1
    assert body["availability"] == "available"

    assert client.get(f"/api/v1/garbage/{p1['id']}").json()["status"] == "collected"


def test_collect_vicinity_needs_location_and_truck(client):
    truck = _make_truck(client, current_location=None)
    assert client.post(f"/api/v1/trucks/{truck['id']}/collect-vicinity", json={}).status_code == 400
    assert (
        client.post(
            "/api/v1/trucks/000000000000000000000000/collect-vicinity", json={}
        ).status_code
        == 404
    )


def test_update_availability_and_load_reset(client):
    truck = _make_truck(client, capacity=5)
    _make_post(client)
    client.post(f"/api/v1/trucks/{truck['id']}/collect-vicinity", json={})

    working = client.patch(f"/api/v1/trucks/{truck['id']}/availability", json={"availability": "working"})
    assert working.status_code == 200
    assert working.json()["availability"] == "working"
    assert working.json()["load"] == 1

    available = client.patch(
        f"/api/v1/trucks/{truck['id']}/availability", json={"availability": "available"}
    )
    assert available.json()["availability"] == "available"
    assert available.json()["load"] == 0

    bad = client.patch(f"/api/v1/trucks/{truck['id']}/availability", json={"availability": "napping"})
    assert bad.status_code == 422

    missing = client.patch(
        "/api/v1/trucks/000000000000000000000000/availability", json={"availability": "full"}
    )
    assert missing.status_code == 404


@pytest.mark.parametrize("route", ["route", "collect-vicinity", "availability"])
def test_collector_routes_reject_unknown_truck(client, route):
    if route == "route":
        response = client.get("/api/v1/trucks/000000000000000000000000/route")
    elif route == "collect-vicinity":
        response = client.post("/api/v1/trucks/000000000000000000000000/collect-vicinity", json={})
    else:
        response = client.patch(
            "/api/v1/trucks/000000000000000000000000/availability", json={"availability": "full"}
        )
    assert response.status_code == 404
