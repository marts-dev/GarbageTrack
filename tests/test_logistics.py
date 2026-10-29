import pytest


@pytest.fixture
def dispatcher(client, make_user):
    return make_user("logistics")


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
        "plate_number": "LOG-1",
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


def test_list_all_posts_and_filters(client, dispatcher, make_user):
    me = make_user()
    other = make_user()
    _make_post(client, me, types=["plastic", "metal"])
    p2 = _make_post(client, other)
    client.patch(f"/api/v1/garbage/{p2['id']}/confirm-collected", headers=other["headers"])

    all_posts = client.get("/api/v1/logistics/garbage", headers=dispatcher["headers"])
    assert all_posts.status_code == 200
    assert len(all_posts.json()) == 2

    posted = client.get(
        "/api/v1/logistics/garbage", params={"status": "posted"}, headers=dispatcher["headers"]
    )
    assert len(posted.json()) == 1
    metal = client.get(
        "/api/v1/logistics/garbage", params={"type": "metal"}, headers=dispatcher["headers"]
    )
    assert len(metal.json()) == 1
    u2 = client.get(
        "/api/v1/logistics/garbage", params={"user_id": other["id"]}, headers=dispatcher["headers"]
    )
    assert len(u2.json()) == 1


def test_garbage_summary_counts(client, dispatcher, make_user):
    me = make_user()
    _make_post(client, me, types=["plastic", "metal"])
    p2 = _make_post(client, me, types=["plastic"])
    client.patch(f"/api/v1/garbage/{p2['id']}/confirm-collected", headers=me["headers"])

    response = client.get("/api/v1/logistics/garbage/summary", headers=dispatcher["headers"])
    assert response.status_code == 200
    assert response.json() == {
        "total": 2,
        "by_status": {"posted": 1, "collected": 1},
        "by_type": {"plastic": 2, "metal": 1},
    }


def test_truck_locations_and_filters(client, dispatcher):
    _make_truck(client, dispatcher["headers"], plate_number="A-1", status="enroute")
    _make_truck(
        client, dispatcher["headers"], plate_number="B-2", status="scheduled", current_location=None
    )

    all_trucks = client.get("/api/v1/logistics/trucks/locations", headers=dispatcher["headers"])
    assert all_trucks.status_code == 200
    assert {t["plate_number"] for t in all_trucks.json()} == {"A-1", "B-2"}

    enroute = client.get(
        "/api/v1/logistics/trucks/locations",
        params={"status": "enroute"},
        headers=dispatcher["headers"],
    )
    assert [t["plate_number"] for t in enroute.json()] == ["A-1"]

    located = next(t for t in all_trucks.json() if t["plate_number"] == "A-1")
    assert located["current_location"] == {"type": "Point", "coordinates": [3.37, 6.45]}
    assert located["availability"] == "available"


def test_facility_crud_lifecycle(client, dispatcher):
    created = _make_facility(client, dispatcher["headers"])
    facility_id = created["id"]
    assert created["kind"] == "dump_site"

    read = client.get(
        f"/api/v1/logistics/facilities/{facility_id}", headers=dispatcher["headers"]
    )
    assert read.status_code == 200
    assert read.json()["name"] == "Central Dump"

    edit = client.patch(
        f"/api/v1/logistics/facilities/{facility_id}",
        json={"name": "North Dump", "kind": "recycling"},
        headers=dispatcher["headers"],
    )
    assert edit.status_code == 200, edit.text
    assert edit.json()["name"] == "North Dump"
    assert edit.json()["kind"] == "recycling"

    delete = client.delete(
        f"/api/v1/logistics/facilities/{facility_id}", headers=dispatcher["headers"]
    )
    assert delete.status_code == 204
    assert (
        client.get(f"/api/v1/logistics/facilities/{facility_id}", headers=dispatcher["headers"]).status_code
        == 404
    )


def test_facility_list_filter_and_errors(client, dispatcher):
    _make_facility(client, dispatcher["headers"], name="Dump", kind="dump_site")
    _make_facility(client, dispatcher["headers"], name="Recycler", kind="recycling")

    all_facilities = client.get("/api/v1/logistics/facilities", headers=dispatcher["headers"])
    assert len(all_facilities.json()) == 2
    recycling = client.get(
        "/api/v1/logistics/facilities", params={"kind": "recycling"}, headers=dispatcher["headers"]
    )
    assert [f["name"] for f in recycling.json()] == ["Recycler"]

    assert (
        client.get(
            "/api/v1/logistics/facilities/000000000000000000000000", headers=dispatcher["headers"]
        ).status_code
        == 404
    )
    assert (
        client.get("/api/v1/logistics/facilities/nope", headers=dispatcher["headers"]).status_code
        == 404
    )
    assert (
        client.delete(
            "/api/v1/logistics/facilities/000000000000000000000000", headers=dispatcher["headers"]
        ).status_code
        == 404
    )
    facility_id = all_facilities.json()[0]["id"]
    assert (
        client.patch(
            f"/api/v1/logistics/facilities/{facility_id}", json={}, headers=dispatcher["headers"]
        ).status_code
        == 400
    )


def test_create_route_manual_marks_posts_scheduled(client, dispatcher, make_user):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    p1 = _make_post(client, me)
    p2 = _make_post(client, me)

    response = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": truck["id"], "name": "Morning run", "post_ids": [p1["id"], p2["id"]]},
        headers=dispatcher["headers"],
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["truck_id"] == truck["id"]
    assert body["status"] == "assigned"
    assert [s["post_id"] for s in body["stops"]] == [p1["id"], p2["id"]]

    assert (
        client.get(f"/api/v1/garbage/{p1['id']}", headers=me["headers"]).json()["status"]
        == "scheduled"
    )

    listed = client.get(
        "/api/v1/logistics/routes",
        params={"truck_id": truck["id"]},
        headers=dispatcher["headers"],
    )
    assert len(listed.json()) == 1
    read = client.get(f"/api/v1/logistics/routes/{body['id']}", headers=dispatcher["headers"])
    assert read.status_code == 200
    assert (
        client.get(
            "/api/v1/logistics/routes/000000000000000000000000", headers=dispatcher["headers"]
        ).status_code
        == 404
    )


def test_create_route_auto_uses_truck_route(client, dispatcher, make_user):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"], capacity=1)
    p1 = _make_post(client, me, types=["plastic"])
    _make_post(client, me, types=["glass"])

    response = client.post(
        "/api/v1/logistics/routes", json={"truck_id": truck["id"]}, headers=dispatcher["headers"]
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert [s["post_id"] for s in body["stops"]] == [p1["id"]]
    assert body["origin"] == {"type": "Point", "coordinates": [3.37, 6.45]}


def test_create_route_errors(client, dispatcher, make_user):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    collected = _make_post(client, me)
    client.patch(f"/api/v1/garbage/{collected['id']}/confirm-collected", headers=me["headers"])

    unknown_truck = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": "000000000000000000000000"},
        headers=dispatcher["headers"],
    )
    assert unknown_truck.status_code == 404

    missing_post = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": truck["id"], "post_ids": ["000000000000000000000000"]},
        headers=dispatcher["headers"],
    )
    assert missing_post.status_code == 404

    collected_post = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": truck["id"], "post_ids": [collected["id"]]},
        headers=dispatcher["headers"],
    )
    assert collected_post.status_code == 409

    no_location = _make_truck(client, dispatcher["headers"], plate_number="NOLOC", current_location=None)
    _make_post(client, me)
    assert (
        client.post(
            "/api/v1/logistics/routes", json={"truck_id": no_location["id"]}, headers=dispatcher["headers"]
        ).status_code
        == 400
    )


def test_logistics_routes_require_logistics_role(client, make_user):
    resident = make_user()
    assert client.get("/api/v1/logistics/garbage", headers=resident["headers"]).status_code == 403
    assert client.get("/api/v1/logistics/garbage/summary", headers=resident["headers"]).status_code == 403
    assert (
        client.get("/api/v1/logistics/trucks/locations", headers=resident["headers"]).status_code
        == 403
    )
    assert (
        client.post(
            "/api/v1/logistics/facilities",
            json={
                "name": "X",
                "kind": "dump_site",
                "location": {"longitude": 0, "latitude": 0},
                "accepted_types": ["plastic"],
            },
            headers=resident["headers"],
        ).status_code
        == 403
    )
    assert client.get("/api/v1/logistics/garbage").status_code == 401
