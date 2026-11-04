"""Truck CRUD: list, PATCH, DELETE for logistics/admin."""

import pytest


@pytest.fixture
def dispatcher(client, make_user):
    return make_user("logistics")


@pytest.fixture
def collector(client, make_user):
    return make_user("collector")


def _make_truck(client, headers, **overrides):
    payload = {
        "plate_number": "CRUD-1",
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


def test_list_trucks_roles(client, dispatcher, collector, make_user):
    resident = make_user()
    admin = make_user("admin")
    _make_truck(client, dispatcher["headers"])
    _make_truck(client, dispatcher["headers"], plate_number="CRUD-2")

    for user in (dispatcher, collector, admin):
        listed = client.get("/api/v1/trucks", headers=user["headers"])
        assert listed.status_code == 200, user
        assert len(listed.json()) == 2

    assert client.get("/api/v1/trucks", headers=resident["headers"]).status_code == 403
    assert client.get("/api/v1/trucks").status_code == 401


def test_list_trucks_filters(client, dispatcher, make_user):
    resident = make_user()
    idle = _make_truck(client, dispatcher["headers"], plate_number="CRUD-E")
    busy = _make_truck(client, dispatcher["headers"], plate_number="CRUD-S")
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, resident)
    assigned = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": busy["id"],
            "post_ids": [post["id"]],
            "depot_ids": [depot["id"]],
        },
        headers=dispatcher["headers"],
    )
    assert assigned.status_code == 201, assigned.text
    assert idle["availability"] == "available"

    by_availability = client.get(
        "/api/v1/trucks", params={"availability": "working"}, headers=dispatcher["headers"]
    )
    assert [t["plate_number"] for t in by_availability.json()] == ["CRUD-S"]

    limited = client.get("/api/v1/trucks", params={"limit": 1}, headers=dispatcher["headers"])
    assert len(limited.json()) == 1


def test_patch_truck_fields(client, dispatcher, collector, make_user):
    admin = make_user("admin")
    truck = _make_truck(client, dispatcher["headers"])
    updated = client.patch(
        f"/api/v1/trucks/{truck['id']}",
        json={
            "plate_number": "CRUD-X",
            "capacity": 4,
            "garbage_types": ["organic"],
            "operator_id": collector["id"],
        },
        headers=dispatcher["headers"],
    )
    assert updated.status_code == 200, updated.text
    body = updated.json()
    assert body["plate_number"] == "CRUD-X"
    assert body["capacity"] == 4
    assert body["garbage_types"] == ["organic"]
    assert body["operator_id"] == collector["id"]

    admin_edit = client.patch(
        f"/api/v1/trucks/{truck['id']}",
        json={"plate_number": "CRUD-Y"},
        headers=admin["headers"],
    )
    assert admin_edit.status_code == 200
    assert admin_edit.json()["plate_number"] == "CRUD-Y"


def test_patch_truck_validation_422(client, dispatcher):
    truck = _make_truck(client, dispatcher["headers"])
    for payload in (
        {"plate_number": ""},
        {"capacity": 0},
        {"garbage_types": []},
    ):
        response = client.patch(
            f"/api/v1/trucks/{truck['id']}", json=payload, headers=dispatcher["headers"]
        )
        assert response.status_code == 422, payload


def test_delete_truck(client, dispatcher, collector, make_user):
    admin = make_user("admin")
    truck = _make_truck(client, dispatcher["headers"])
    assigned = _make_truck(client, dispatcher["headers"], plate_number="CRUD-BOUND")
    bound = client.patch(
        f"/api/v1/trucks/{assigned['id']}",
        json={"operator_id": collector["id"]},
        headers=dispatcher["headers"],
    )
    assert bound.status_code == 200

    # A bound truck with no planned routes can still be deleted.
    assert (
        client.delete(f"/api/v1/trucks/{assigned['id']}", headers=admin["headers"]).status_code
        == 204
    )
    assert (
        client.delete(f"/api/v1/trucks/{truck['id']}", headers=dispatcher["headers"]).status_code
        == 204
    )
    assert (
        client.get(f"/api/v1/trucks/{truck['id']}", headers=dispatcher["headers"]).status_code
        == 404
    )
    assert (
        client.delete(
            "/api/v1/trucks/000000000000000000000000", headers=dispatcher["headers"]
        ).status_code
        == 404
    )
    assert (
        client.delete("/api/v1/trucks/not-an-id", headers=dispatcher["headers"]).status_code
        == 404
    )


def test_delete_truck_with_route_409(client, dispatcher, collector, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, resident)
    created = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": truck["id"],
            "post_ids": [post["id"]],
            "depot_ids": [depot["id"]],
        },
        headers=dispatcher["headers"],
    )
    assert created.status_code == 201, created.text

    refused = client.delete(f"/api/v1/trucks/{truck['id']}", headers=dispatcher["headers"])
    assert refused.status_code == 409

    other = _make_truck(client, dispatcher["headers"], plate_number="CRUD-FREE")
    assert (
        client.delete(f"/api/v1/trucks/{other['id']}", headers=dispatcher["headers"]).status_code
        == 204
    )


def test_delete_requires_logistics_role(client, dispatcher, collector, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    assert (
        client.delete(f"/api/v1/trucks/{truck['id']}", headers=collector["headers"]).status_code
        == 403
    )
    assert (
        client.delete(f"/api/v1/trucks/{truck['id']}", headers=resident["headers"]).status_code
        == 403
    )
    assert client.delete(f"/api/v1/trucks/{truck['id']}").status_code == 401
