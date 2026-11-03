import pytest
from bson import ObjectId


@pytest.fixture
def dispatcher(client, make_user):
    return make_user("logistics")


def _mark_pending(fake_db, post_id):
    """Seed the pre-confirm state: collect-vicinity marks posts pending."""
    fake_db["garbage_posts"].docs[ObjectId(post_id)]["status"] = "pending_confirmation"


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


def test_list_all_posts_and_filters(client, dispatcher, make_user, fake_db):
    me = make_user()
    other = make_user()
    _make_post(client, me, types=["plastic", "metal"])
    p2 = _make_post(client, other)
    _mark_pending(fake_db, p2["id"])
    confirmed = client.patch(
        f"/api/v1/garbage/{p2['id']}/confirm-collected", headers=other["headers"]
    )
    assert confirmed.status_code == 200, confirmed.text

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


def test_garbage_summary_counts(client, dispatcher, make_user, fake_db):
    me = make_user()
    _make_post(client, me, types=["plastic", "metal"])
    p2 = _make_post(client, me, types=["plastic"])
    _mark_pending(fake_db, p2["id"])
    confirmed = client.patch(
        f"/api/v1/garbage/{p2['id']}/confirm-collected", headers=me["headers"]
    )
    assert confirmed.status_code == 200, confirmed.text

    response = client.get("/api/v1/logistics/garbage/summary", headers=dispatcher["headers"])
    assert response.status_code == 200
    assert response.json() == {
        "total": 2,
        "by_status": {"posted": 1, "collected": 1},
        "by_type": {"plastic": 2, "metal": 1},
        "by_region": {},
    }


def test_garbage_summary_groups_by_ph_region(client, dispatcher, make_user):
    me = make_user()
    _make_post(client, me, longitude=120.98, latitude=14.59, types=["plastic"])
    _make_post(client, me, longitude=120.99, latitude=14.60, types=["metal"])
    _make_post(client, me, longitude=123.89, latitude=10.31, types=["plastic"])
    _make_post(client, me, longitude=3.37, latitude=6.45, types=["glass"])
    response = client.get(
        "/api/v1/logistics/garbage/summary?country=Philippines",
        headers=dispatcher["headers"],
    )
    assert response.status_code == 200, response.text
    body = response.json()
    # The Lagos post is outside the Philippines: pills match the map.
    assert body["total"] == 3
    assert body["by_status"] == {"posted": 3}
    assert body["by_type"] == {"plastic": 2, "metal": 1}
    ncr = body["by_region"]["National Capital Region (NCR)"]
    assert ncr["total"] == 2
    assert ncr["by_type"] == {"plastic": 1, "metal": 1}
    assert ncr["by_status"] == {"posted": 2}
    visayas = body["by_region"]["Region VII (Central Visayas)"]
    assert visayas == {"total": 1, "by_status": {"posted": 1}, "by_type": {"plastic": 1}}
    assert "Region XI (Davao Region)" not in body["by_region"]


def test_garbage_summary_region_empty_without_supported_country(
    client, dispatcher, make_user
):
    me = make_user()
    _make_post(client, me, longitude=120.98, latitude=14.59)
    plain = client.get(
        "/api/v1/logistics/garbage/summary", headers=dispatcher["headers"]
    )
    assert plain.json()["by_region"] == {}
    unsupported = client.get(
        "/api/v1/logistics/garbage/summary?country=Nigeria",
        headers=dispatcher["headers"],
    )
    assert unsupported.json()["by_region"] == {}


def test_garbage_summary_scopes_totals_to_country(client, dispatcher, make_user, fake_db):
    me = make_user()
    _make_post(client, me, types=["plastic"])
    ghana = _make_post(client, me, types=["metal"])
    fake_db["garbage_posts"].docs[ObjectId(ghana["id"])]["country"] = "Ghana"

    plain = client.get(
        "/api/v1/logistics/garbage/summary", headers=dispatcher["headers"]
    )
    assert plain.json()["total"] == 2

    # No Nigerian boundaries shipped: falls back to the stamped country.
    nigeria = client.get(
        "/api/v1/logistics/garbage/summary?country=Nigeria",
        headers=dispatcher["headers"],
    )
    assert nigeria.json()["total"] == 1
    assert nigeria.json()["by_type"] == {"plastic": 1}
    assert nigeria.json()["by_region"] == {}

    ghana_summary = client.get(
        "/api/v1/logistics/garbage/summary?country=ghana",
        headers=dispatcher["headers"],
    )
    assert ghana_summary.json()["total"] == 1
    assert ghana_summary.json()["by_type"] == {"metal": 1}


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
    depot = _make_facility(client, dispatcher["headers"])
    p1 = _make_post(client, me)
    p2 = _make_post(client, me)

    response = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": truck["id"],
            "name": "Morning run",
            "post_ids": [p1["id"], p2["id"]],
            "depot_ids": [depot["id"]],
        },
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


def test_create_route_geometry_ends_at_last_depot(client, dispatcher, make_user):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    first = _make_facility(client, dispatcher["headers"])
    second = _make_facility(
        client,
        dispatcher["headers"],
        name="Far Depot",
        location={"longitude": 9.99, "latitude": 9.99},
    )
    post = _make_post(client, me)

    response = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": truck["id"],
            "post_ids": [post["id"]],
            "depot_ids": [first["id"], second["id"]],
        },
        headers=dispatcher["headers"],
    )
    assert response.status_code == 201, response.text
    coords = response.json()["geometry"]["coordinates"]
    assert coords[-1] == [9.99, 9.99]


def test_create_route_auto_uses_truck_route(client, dispatcher, make_user):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"], capacity=1)
    depot = _make_facility(client, dispatcher["headers"])
    p1 = _make_post(client, me, types=["plastic"])
    _make_post(client, me, types=["glass"])

    response = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": truck["id"], "depot_ids": [depot["id"]]},
        headers=dispatcher["headers"],
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert [s["post_id"] for s in body["stops"]] == [p1["id"]]
    assert body["origin"] == {"type": "Point", "coordinates": [3.37, 6.45]}


def test_create_route_errors(client, dispatcher, make_user, fake_db):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    collected = _make_post(client, me)
    _mark_pending(fake_db, collected["id"])
    confirmed = client.patch(
        f"/api/v1/garbage/{collected['id']}/confirm-collected", headers=me["headers"]
    )
    assert confirmed.status_code == 200, confirmed.text

    unknown_truck = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": "000000000000000000000000", "depot_ids": [depot["id"]]},
        headers=dispatcher["headers"],
    )
    assert unknown_truck.status_code == 404

    missing_post = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": truck["id"],
            "post_ids": ["000000000000000000000000"],
            "depot_ids": [depot["id"]],
        },
        headers=dispatcher["headers"],
    )
    assert missing_post.status_code == 404

    collected_post = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": truck["id"], "post_ids": [collected["id"]], "depot_ids": [depot["id"]]},
        headers=dispatcher["headers"],
    )
    assert collected_post.status_code == 409

    no_location = _make_truck(client, dispatcher["headers"], plate_number="NOLOC", current_location=None)
    _make_post(client, me)
    assert (
        client.post(
            "/api/v1/logistics/routes",
            json={"truck_id": no_location["id"], "depot_ids": [depot["id"]]},
            headers=dispatcher["headers"],
        ).status_code
        == 400
    )


def test_create_route_manual_rejects_types_truck_cannot_carry(
    client, dispatcher, make_user
):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    glass_only = _make_post(client, me, types=["glass"])
    mixed = _make_post(client, me, types=["glass", "plastic"])

    rejected = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": truck["id"],
            "post_ids": [glass_only["id"]],
            "depot_ids": [depot["id"]],
        },
        headers=dispatcher["headers"],
    )
    assert rejected.status_code == 400, rejected.text

    # Any overlap with the truck's plastic capability is enough.
    accepted = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": truck["id"],
            "post_ids": [mixed["id"]],
            "depot_ids": [depot["id"]],
        },
        headers=dispatcher["headers"],
    )
    assert accepted.status_code == 201, accepted.text


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


def test_delete_route_releases_stops(client, dispatcher, make_user):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    p1 = _make_post(client, me)
    p2 = _make_post(client, me)
    created = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": truck["id"],
            "post_ids": [p1["id"], p2["id"]],
            "depot_ids": [depot["id"]],
        },
        headers=dispatcher["headers"],
    )
    assert created.status_code == 201, created.text
    route_id = created.json()["id"]

    deleted = client.delete(f"/api/v1/logistics/routes/{route_id}", headers=dispatcher["headers"])
    assert deleted.status_code == 204

    assert (
        client.get(f"/api/v1/logistics/routes/{route_id}", headers=dispatcher["headers"]).status_code
        == 404
    )
    listed = client.get("/api/v1/logistics/routes", headers=dispatcher["headers"])
    assert route_id not in [r["id"] for r in listed.json()]

    assert (
        client.get(f"/api/v1/garbage/{p1['id']}", headers=me["headers"]).json()["status"]
        == "posted"
    )
    assert (
        client.get(f"/api/v1/garbage/{p2['id']}", headers=me["headers"]).json()["status"]
        == "posted"
    )


def test_delete_route_keeps_collected_untouched(client, dispatcher, make_user, fake_db):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    p1 = _make_post(client, me)
    p2 = _make_post(client, me)
    created = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": truck["id"],
            "post_ids": [p1["id"], p2["id"]],
            "depot_ids": [depot["id"]],
        },
        headers=dispatcher["headers"],
    )
    route_id = created.json()["id"]
    _mark_pending(fake_db, p1["id"])
    assert (
        client.patch(
            f"/api/v1/garbage/{p1['id']}/confirm-collected", headers=me["headers"]
        ).status_code
        == 200
    )

    assert (
        client.delete(
            f"/api/v1/logistics/routes/{route_id}", headers=dispatcher["headers"]
        ).status_code
        == 204
    )
    assert (
        client.get(f"/api/v1/garbage/{p1['id']}", headers=me["headers"]).json()["status"]
        == "collected"
    )
    assert (
        client.get(f"/api/v1/garbage/{p2['id']}", headers=me["headers"]).json()["status"]
        == "posted"
    )


def test_delete_route_404(client, dispatcher):
    assert (
        client.delete(
            "/api/v1/logistics/routes/000000000000000000000000", headers=dispatcher["headers"]
        ).status_code
        == 404
    )
    assert (
        client.delete("/api/v1/logistics/routes/not-an-id", headers=dispatcher["headers"]).status_code
        == 404
    )


def test_delete_route_requires_logistics_role(client, dispatcher, make_user):
    me = make_user()
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)
    created = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": truck["id"],
            "post_ids": [post["id"]],
            "depot_ids": [depot["id"]],
        },
        headers=dispatcher["headers"],
    )
    route_id = created.json()["id"]
    assert (
        client.delete(
            f"/api/v1/logistics/routes/{route_id}", headers=resident["headers"]
        ).status_code
        == 403
    )
    assert client.delete(f"/api/v1/logistics/routes/{route_id}").status_code == 401


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


def test_truck_planned_route_returns_plan_with_depots(client, dispatcher, make_user):
    me = make_user()
    collector = make_user("collector")
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    p1 = _make_post(client, me)
    p2 = _make_post(client, me)
    _make_route(client, dispatcher["headers"], truck["id"], depot["id"], [p1["id"], p2["id"]])

    for headers in (collector["headers"], dispatcher["headers"]):
        response = client.get(f"/api/v1/trucks/{truck['id']}/planned-route", headers=headers)
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["truck_id"] == truck["id"]
        assert body["status"] == "assigned"
        assert [s["post_id"] for s in body["stops"]] == [p1["id"], p2["id"]]
        assert [d["id"] for d in body["depots"]] == [depot["id"]]
        assert body["depots"][0]["name"] == depot["name"]
        assert body["depots"][0]["location"] == depot["location"]


def test_truck_planned_route_404s(client, dispatcher, make_user):
    collector = make_user("collector")
    truck = _make_truck(client, dispatcher["headers"])
    assert (
        client.get(
            f"/api/v1/trucks/{truck['id']}/planned-route", headers=collector["headers"]
        ).status_code
        == 404
    )
    assert (
        client.get(
            "/api/v1/trucks/000000000000000000000000/planned-route",
            headers=collector["headers"],
        ).status_code
        == 404
    )
    resident = make_user()
    assert (
        client.get(
            f"/api/v1/trucks/{truck['id']}/planned-route", headers=resident["headers"]
        ).status_code
        == 403
    )


def test_truck_planned_route_ignores_finished_plans(client, dispatcher, make_user, fake_db):
    from bson import ObjectId

    me = make_user()
    collector = make_user("collector")
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)
    route = _make_route(client, dispatcher["headers"], truck["id"], depot["id"], [post["id"]])
    fake_db["planned_routes"].docs[ObjectId(route["id"])]["status"] = "done"

    assert (
        client.get(
            f"/api/v1/trucks/{truck['id']}/planned-route", headers=collector["headers"]
        ).status_code
        == 404
    )


def test_truck_planned_route_filters_collected_stops(client, dispatcher, make_user):
    me = make_user()
    collector = make_user("collector")
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    p1 = _make_post(client, me)
    p2 = _make_post(client, me)
    _make_route(client, dispatcher["headers"], truck["id"], depot["id"], [p1["id"], p2["id"]])

    before = client.get(
        f"/api/v1/trucks/{truck['id']}/planned-route", headers=collector["headers"]
    )
    assert len(before.json()["stops"]) == 2

    collected = client.post(
        f"/api/v1/trucks/{truck['id']}/collect-vicinity",
        json={},
        headers=dispatcher["headers"],
    )
    assert collected.status_code == 200, collected.text

    after = client.get(
        f"/api/v1/trucks/{truck['id']}/planned-route", headers=collector["headers"]
    )
    assert after.status_code == 200
    assert after.json()["stops"] == []
