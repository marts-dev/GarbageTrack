"""Country/district scoping, resident-only posting, depots, and collection points."""

from datetime import UTC, datetime

import pytest
from bson import ObjectId

from app.core import security


@pytest.fixture
def dispatcher(client, make_user):
    return make_user("logistics")


def _register(client, email, country, **extra):
    payload = {
        "email": email,
        "password": "Password123",
        "full_name": "Test User",
        "country": country,
    }
    payload.update(extra)
    return client.post("/api/v1/auth/register", json=payload)


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
        "plate_number": "GEO-1",
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
        "name": "Depot",
        "kind": "dump_site",
        "location": {"longitude": 3.38, "latitude": 6.46},
        "accepted_types": ["plastic"],
    }
    payload.update(overrides)
    response = client.post("/api/v1/logistics/facilities", json=payload, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


def _route_payload(truck_id, depot_ids, **overrides):
    payload = {"truck_id": truck_id, "depot_ids": depot_ids}
    payload.update(overrides)
    return payload


# req1: country at registration, in profile, stamped on posts, filters candidates.


def test_register_requires_country(client):
    missing = client.post(
        "/api/v1/auth/register",
        json={"email": "a@example.com", "password": "Password123"},
    )
    assert missing.status_code == 422
    blank = _register(client, "b@example.com", "   ")
    assert blank.status_code == 422


def test_country_returned_in_profile_and_updatable(client, make_user):
    me = make_user()
    profile = client.get("/api/v1/auth/me", headers=me["headers"])
    assert profile.status_code == 200
    assert profile.json()["country"] == "Nigeria"

    updated = client.patch(
        "/api/v1/auth/me",
        json={"full_name": "New Name", "country": "Ghana"},
        headers=me["headers"],
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["country"] == "Ghana"
    assert updated.json()["full_name"] == "New Name"


def test_legacy_user_without_country_is_tolerated(client, fake_db):
    user_id = ObjectId()
    fake_db["users"].docs[user_id] = {
        "_id": user_id,
        "email": "legacy@example.com",
        "hashed_password": security.hash_password("Password123"),
        "full_name": "Legacy",
        "role": "resident",
        "is_active": True,
        "created_at": datetime.now(UTC),
    }
    login = client.post(
        "/api/v1/auth/login", data={"username": "legacy@example.com", "password": "Password123"}
    )
    assert login.status_code == 200
    me = client.get(
        "/api/v1/auth/me",
        headers={"Authorization": f"Bearer {login.json()['access_token']}"},
    )
    assert me.status_code == 200
    assert me.json()["country"] is None


def test_post_country_stamped_from_user_and_filterable(client, make_user):
    assert _register(client, "ghana@example.com", "Ghana").status_code == 201
    login = client.post(
        "/api/v1/auth/login", data={"username": "ghana@example.com", "password": "Password123"}
    )
    ghana = {"id": None, "headers": {"Authorization": f"Bearer {login.json()['access_token']}"}}
    ghana["id"] = client.get("/api/v1/auth/me", headers=ghana["headers"]).json()["id"]
    nigeria = make_user()

    ng_post = _make_post(client, nigeria)
    gh_post = _make_post(client, ghana)
    assert ng_post["country"] == "Nigeria"
    assert gh_post["country"] == "Ghana"
    assert ng_post["district"] is None

    ghana_only = client.get(
        "/api/v1/garbage", params={"country": "Ghana"}, headers=nigeria["headers"]
    )
    assert [p["id"] for p in ghana_only.json()] == [gh_post["id"]]
    no_match = client.get(
        "/api/v1/garbage", params={"country": "Kenya"}, headers=nigeria["headers"]
    )
    assert no_match.status_code == 200
    assert no_match.json() == []


# req2: only residents may post garbage.


@pytest.mark.parametrize("role", ["collector", "logistics", "admin"])
def test_non_resident_post_garbage_forbidden(client, make_user, role):
    user = make_user(role)
    response = client.post(
        "/api/v1/garbage",
        json={
            "user_id": user["id"],
            "longitude": 3.37,
            "latitude": 6.45,
            "types": ["plastic"],
        },
        headers=user["headers"],
    )
    assert response.status_code == 403


# req4: district on posts + filters.


def test_district_roundtrip_and_filters(client, make_user, dispatcher):
    me = make_user()
    ojota = _make_post(client, me, district="Ojota")
    ikeja = _make_post(client, me, district="Ikeja")
    _make_post(client, me)
    assert ojota["district"] == "Ojota"

    filtered = client.get("/api/v1/garbage", params={"district": "Ojota"}, headers=me["headers"])
    assert [p["id"] for p in filtered.json()] == [ojota["id"]]

    logistics = client.get(
        "/api/v1/logistics/garbage",
        params={"district": "Ikeja"},
        headers=dispatcher["headers"],
    )
    assert [p["id"] for p in logistics.json()] == [ikeja["id"]]

    combined = client.get(
        "/api/v1/logistics/garbage",
        params={"district": "Ojota", "country": "Nigeria"},
        headers=dispatcher["headers"],
    )
    assert [p["id"] for p in combined.json()] == [ojota["id"]]


# req5: logistics posted-garbage listing feeds the route-create map.


def test_logistics_posted_garbage_returns_map_data(client, make_user, dispatcher):
    me = make_user()
    post = _make_post(client, me, district="Ojota", longitude=3.375, latitude=6.455)
    response = client.get(
        "/api/v1/logistics/garbage",
        params={"status": "posted", "district": "Ojota"},
        headers=dispatcher["headers"],
    )
    assert response.status_code == 200
    body = response.json()
    assert len(body) == 1
    assert body[0]["id"] == post["id"]
    assert body[0]["location"] == {"type": "Point", "coordinates": [3.375, 6.455]}
    assert body[0]["status"] == "posted"


# req3: depots on routes.


def test_route_requires_existing_depots(client, make_user, dispatcher):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    post = _make_post(client, me)

    missing = client.post(
        "/api/v1/logistics/routes",
        json=_route_payload(truck["id"], ["000000000000000000000000"], post_ids=[post["id"]]),
        headers=dispatcher["headers"],
    )
    assert missing.status_code == 404

    bad_id = client.post(
        "/api/v1/logistics/routes",
        json=_route_payload(truck["id"], ["not-an-id"], post_ids=[post["id"]]),
        headers=dispatcher["headers"],
    )
    assert bad_id.status_code == 404

    empty = client.post(
        "/api/v1/logistics/routes",
        json=_route_payload(truck["id"], [], post_ids=[post["id"]]),
        headers=dispatcher["headers"],
    )
    assert empty.status_code == 422

    omitted = client.post(
        "/api/v1/logistics/routes",
        json={"truck_id": truck["id"], "post_ids": [post["id"]]},
        headers=dispatcher["headers"],
    )
    assert omitted.status_code == 422


def test_route_multi_depot_roundtrip_all_kinds(client, make_user, dispatcher):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    dump = _make_facility(client, dispatcher["headers"], name="Dump", kind="dump_site")
    recycler = _make_facility(client, dispatcher["headers"], name="Recycler", kind="recycling")
    post = _make_post(client, me)

    response = client.post(
        "/api/v1/logistics/routes",
        json=_route_payload(truck["id"], [dump["id"], recycler["id"]], post_ids=[post["id"]]),
        headers=dispatcher["headers"],
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["depot_ids"] == [dump["id"], recycler["id"]]
    assert body["collection_points"] == []

    reread = client.get(f"/api/v1/logistics/routes/{body['id']}", headers=dispatcher["headers"])
    assert reread.json()["depot_ids"] == [dump["id"], recycler["id"]]


# req4+req1: auto route narrows candidates by district/country.


def test_auto_route_narrows_by_district_and_country(client, make_user, dispatcher):
    assert _register(client, "ghana@example.com", "Ghana").status_code == 201
    login = client.post(
        "/api/v1/auth/login", data={"username": "ghana@example.com", "password": "Password123"}
    )
    ghana = {"id": None, "headers": {"Authorization": f"Bearer {login.json()['access_token']}"}}
    ghana["id"] = client.get("/api/v1/auth/me", headers=ghana["headers"]).json()["id"]
    nigeria = make_user()

    wanted = _make_post(client, nigeria, district="Ojota")
    _make_post(client, nigeria, district="Ikeja")
    _make_post(client, ghana, district="Ojota")

    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    response = client.post(
        "/api/v1/logistics/routes",
        json=_route_payload(truck["id"], [depot["id"]], district="Ojota", country="Nigeria"),
        headers=dispatcher["headers"],
    )
    assert response.status_code == 201, response.text
    assert [s["post_id"] for s in response.json()["stops"]] == [wanted["id"]]

    truck_route = client.get(
        f"/api/v1/trucks/{truck['id']}/route",
        params={"district": "Ikeja", "country": "Nigeria"},
        headers=dispatcher["headers"],
    )
    assert truck_route.status_code == 200
    assert len(truck_route.json()["stops"]) == 1


# req6: collection points on routes.


def test_route_collection_points_roundtrip(client, make_user, dispatcher):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)
    points = [
        {"longitude": 3.3725, "latitude": 6.4525},
        {"longitude": 3.3755, "latitude": 6.4555},
    ]
    response = client.post(
        "/api/v1/logistics/routes",
        json=_route_payload(
            truck["id"], [depot["id"]], post_ids=[post["id"]], collection_points=points
        ),
        headers=dispatcher["headers"],
    )
    assert response.status_code == 201, response.text
    assert response.json()["collection_points"] == [
        {"type": "Point", "coordinates": [3.3725, 6.4525]},
        {"type": "Point", "coordinates": [3.3755, 6.4555]},
    ]


def test_route_collection_points_reject_bad_coordinates(client, make_user, dispatcher):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)
    response = client.post(
        "/api/v1/logistics/routes",
        json=_route_payload(
            truck["id"],
            [depot["id"]],
            post_ids=[post["id"]],
            collection_points=[{"longitude": 999, "latitude": 6.45}],
        ),
        headers=dispatcher["headers"],
    )
    assert response.status_code == 422


def test_legacy_route_without_new_keys_reads_defaults(client, make_user, dispatcher, fake_db):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    post = _make_post(client, me)
    route_id = ObjectId()
    fake_db["planned_routes"].docs[route_id] = {
        "_id": route_id,
        "truck_id": ObjectId(truck["id"]),
        "name": "Legacy run",
        "origin": {"type": "Point", "coordinates": [3.37, 6.45]},
        "stops": [
            {
                "post_id": ObjectId(post["id"]),
                "location": {"type": "Point", "coordinates": [3.371, 6.451]},
                "types": ["plastic"],
            }
        ],
        "status": "assigned",
        "created_at": datetime.now(UTC),
    }
    response = client.get(f"/api/v1/logistics/routes/{route_id}", headers=dispatcher["headers"])
    assert response.status_code == 200
    assert response.json()["depot_ids"] == []
    assert response.json()["collection_points"] == []
    assert response.json()["geometry"] is None
    assert response.json()["geometry_source"] == "straight"
