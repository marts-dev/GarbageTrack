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


def _make_truck(client, **overrides):
    payload = {
        "plate_number": "LOG-1",
        "garbage_types": ["plastic"],
        "status": "enroute",
        "current_location": {"longitude": 3.37, "latitude": 6.45},
        "capacity": 10,
    }
    payload.update(overrides)
    response = client.post("/api/v1/trucks/schedules", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def _make_facility(client, **overrides):
    payload = {
        "name": "Central Dump",
        "kind": "dump_site",
        "location": {"longitude": 3.38, "latitude": 6.46},
        "accepted_types": ["plastic", "metal"],
        "address": "1 Depot Rd",
    }
    payload.update(overrides)
    response = client.post("/api/v1/logistics/facilities", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def test_list_all_posts_and_filters(client):
    _make_post(client, user_id="u1", types=["plastic", "metal"])
    p2 = _make_post(client, user_id="u2", types=["organic"])
    client.patch(f"/api/v1/garbage/{p2['id']}/confirm-collected")

    all_posts = client.get("/api/v1/logistics/garbage")
    assert all_posts.status_code == 200
    assert len(all_posts.json()) == 2

    posted = client.get("/api/v1/logistics/garbage", params={"status": "posted"})
    assert len(posted.json()) == 1
    metal = client.get("/api/v1/logistics/garbage", params={"type": "metal"})
    assert len(metal.json()) == 1
    u2 = client.get("/api/v1/logistics/garbage", params={"user_id": "u2"})
    assert len(u2.json()) == 1


def test_garbage_summary_counts(client):
    _make_post(client, types=["plastic", "metal"])
    p2 = _make_post(client, types=["plastic"])
    client.patch(f"/api/v1/garbage/{p2['id']}/confirm-collected")

    response = client.get("/api/v1/logistics/garbage/summary")
    assert response.status_code == 200
    assert response.json() == {
        "total": 2,
        "by_status": {"posted": 1, "collected": 1},
        "by_type": {"plastic": 2, "metal": 1},
    }


def test_truck_locations_and_filters(client):
    _make_truck(client, plate_number="A-1", status="enroute")
    _make_truck(client, plate_number="B-2", status="scheduled", current_location=None)

    all_trucks = client.get("/api/v1/logistics/trucks/locations")
    assert all_trucks.status_code == 200
    assert {t["plate_number"] for t in all_trucks.json()} == {"A-1", "B-2"}

    enroute = client.get("/api/v1/logistics/trucks/locations", params={"status": "enroute"})
    assert [t["plate_number"] for t in enroute.json()] == ["A-1"]

    located = next(t for t in all_trucks.json() if t["plate_number"] == "A-1")
    assert located["current_location"] == {"type": "Point", "coordinates": [3.37, 6.45]}
    assert located["availability"] == "available"


def test_facility_crud_lifecycle(client):
    created = _make_facility(client)
    facility_id = created["id"]
    assert created["kind"] == "dump_site"

    read = client.get(f"/api/v1/logistics/facilities/{facility_id}")
    assert read.status_code == 200
    assert read.json()["name"] == "Central Dump"

    edit = client.patch(
        f"/api/v1/logistics/facilities/{facility_id}",
        json={"name": "North Dump", "kind": "recycling"},
    )
    assert edit.status_code == 200, edit.text
    assert edit.json()["name"] == "North Dump"
    assert edit.json()["kind"] == "recycling"

    delete = client.delete(f"/api/v1/logistics/facilities/{facility_id}")
    assert delete.status_code == 204
    assert client.get(f"/api/v1/logistics/facilities/{facility_id}").status_code == 404


def test_facility_list_filter_and_errors(client):
    _make_facility(client, name="Dump", kind="dump_site")
    _make_facility(client, name="Recycler", kind="recycling")

    all_facilities = client.get("/api/v1/logistics/facilities")
    assert len(all_facilities.json()) == 2
    recycling = client.get("/api/v1/logistics/facilities", params={"kind": "recycling"})
    assert [f["name"] for f in recycling.json()] == ["Recycler"]

    assert client.get("/api/v1/logistics/facilities/000000000000000000000000").status_code == 404
    assert client.get("/api/v1/logistics/facilities/nope").status_code == 404
    assert (
        client.delete("/api/v1/logistics/facilities/000000000000000000000000").status_code == 404
    )
    facility_id = all_facilities.json()[0]["id"]
    assert client.patch(f"/api/v1/logistics/facilities/{facility_id}", json={}).status_code == 400


def test_create_route_manual_marks_posts_scheduled(client):
    truck = _make_truck(client)
    p1 = _make_post(client)
    p2 = _make_post(client)

    response = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": truck["id"], "name": "Morning run", "post_ids": [p1["id"], p2["id"]]},
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["truck_id"] == truck["id"]
    assert body["status"] == "assigned"
    assert [s["post_id"] for s in body["stops"]] == [p1["id"], p2["id"]]

    assert client.get(f"/api/v1/garbage/{p1['id']}").json()["status"] == "scheduled"

    listed = client.get("/api/v1/logistics/routes", params={"truck_id": truck["id"]})
    assert len(listed.json()) == 1
    read = client.get(f"/api/v1/logistics/routes/{body['id']}")
    assert read.status_code == 200
    assert client.get("/api/v1/logistics/routes/000000000000000000000000").status_code == 404


def test_create_route_auto_uses_truck_route(client):
    truck = _make_truck(client, capacity=1)
    p1 = _make_post(client, types=["plastic"])
    _make_post(client, types=["glass"])

    response = client.post("/api/v1/logistics/routes", json={"truck_id": truck["id"]})
    assert response.status_code == 201, response.text
    body = response.json()
    assert [s["post_id"] for s in body["stops"]] == [p1["id"]]
    assert body["origin"] == {"type": "Point", "coordinates": [3.37, 6.45]}


def test_create_route_errors(client):
    truck = _make_truck(client)
    collected = _make_post(client)
    client.patch(f"/api/v1/garbage/{collected['id']}/confirm-collected")

    unknown_truck = client.post(
        "/api/v1/logistics/routes", json={"truck_id": "000000000000000000000000"}
    )
    assert unknown_truck.status_code == 404

    missing_post = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": truck["id"], "post_ids": ["000000000000000000000000"]},
    )
    assert missing_post.status_code == 404

    collected_post = client.post(
        "/api/v1/logistics/routes", json={"truck_id": truck["id"], "post_ids": [collected["id"]]}
    )
    assert collected_post.status_code == 409

    no_location = _make_truck(client, plate_number="NOLOC", current_location=None)
    _make_post(client)
    assert (
        client.post("/api/v1/logistics/routes", json={"truck_id": no_location["id"]}).status_code
        == 400
    )
