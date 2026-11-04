"""Operator binding: logistics-assigned 1:1 collector <-> truck binding.

Replaces the old collector truck-claim system. Binding is set only by
logistics/admin via PATCH /trucks/{id}; collectors may collect-vicinity or
finish-route only on the truck whose operator_id is their own id.
"""

import pytest


@pytest.fixture
def dispatcher(client, make_user):
    return make_user("logistics")


@pytest.fixture
def collector(client, make_user):
    return make_user("collector")


@pytest.fixture
def collector2(client, make_user):
    return make_user("collector")


def _make_truck(client, headers, **overrides):
    payload = {
        "plate_number": "OP-1",
        "garbage_types": ["plastic"],
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


def test_assign_and_unassign_roundtrip(client, dispatcher, collector):
    truck = _make_truck(client, dispatcher["headers"])
    assert truck["operator_id"] is None

    assigned = _assign(client, truck["id"], collector["id"], dispatcher["headers"])
    assert assigned["operator_id"] == collector["id"]

    reread = client.get(f"/api/v1/trucks/{truck['id']}", headers=dispatcher["headers"])
    assert reread.json()["operator_id"] == collector["id"]

    unassigned = _assign(client, truck["id"], None, dispatcher["headers"])
    assert unassigned["operator_id"] is None


def test_double_bind_conflict(client, dispatcher, collector):
    first = _make_truck(client, dispatcher["headers"], plate_number="OP-A")
    second = _make_truck(client, dispatcher["headers"], plate_number="OP-B")
    _assign(client, first["id"], collector["id"], dispatcher["headers"])

    conflict = client.patch(
        f"/api/v1/trucks/{second['id']}",
        json={"operator_id": collector["id"]},
        headers=dispatcher["headers"],
    )
    assert conflict.status_code == 409

    # Re-assigning the same collector to the same truck is idempotent.
    retry = client.patch(
        f"/api/v1/trucks/{first['id']}",
        json={"operator_id": collector["id"]},
        headers=dispatcher["headers"],
    )
    assert retry.status_code == 200

    # After unassigning, the collector can be bound to the other truck.
    _assign(client, first["id"], None, dispatcher["headers"])
    moved = _assign(client, second["id"], collector["id"], dispatcher["headers"])
    assert moved["operator_id"] == collector["id"]


def test_assign_unknown_user_404(client, dispatcher):
    truck = _make_truck(client, dispatcher["headers"])
    response = client.patch(
        f"/api/v1/trucks/{truck['id']}",
        json={"operator_id": "000000000000000000000000"},
        headers=dispatcher["headers"],
    )
    assert response.status_code == 404


def test_assign_malformed_user_422(client, dispatcher):
    truck = _make_truck(client, dispatcher["headers"])
    response = client.patch(
        f"/api/v1/trucks/{truck['id']}",
        json={"operator_id": "not-an-id"},
        headers=dispatcher["headers"],
    )
    assert response.status_code == 422


def test_assign_non_collector_422(client, dispatcher, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    for user_id in (resident["id"], dispatcher["id"]):
        response = client.patch(
            f"/api/v1/trucks/{truck['id']}",
            json={"operator_id": user_id},
            headers=dispatcher["headers"],
        )
        assert response.status_code == 422, response.text


def test_patch_requires_logistics_role(client, dispatcher, collector, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    payload = {"operator_id": collector["id"]}
    assert (
        client.patch(f"/api/v1/trucks/{truck['id']}", json=payload, headers=collector["headers"])
    ).status_code == 403
    assert (
        client.patch(f"/api/v1/trucks/{truck['id']}", json=payload, headers=resident["headers"])
    ).status_code == 403
    assert client.patch(f"/api/v1/trucks/{truck['id']}", json=payload).status_code == 401


def test_patch_empty_body_400(client, dispatcher):
    truck = _make_truck(client, dispatcher["headers"])
    response = client.patch(
        f"/api/v1/trucks/{truck['id']}", json={}, headers=dispatcher["headers"]
    )
    assert response.status_code == 400


def test_collect_and_finish_require_assignment(client, dispatcher, collector):
    truck = _make_truck(client, dispatcher["headers"])
    other = _make_truck(client, dispatcher["headers"], plate_number="OP-OTHER")

    collect_denied = client.post(
        f"/api/v1/trucks/{truck['id']}/collect-vicinity", json={}, headers=collector["headers"]
    )
    assert collect_denied.status_code == 403
    assert "not assigned" in collect_denied.json()["detail"]

    finish_denied = client.post(
        f"/api/v1/trucks/{truck['id']}/finish-route",
        headers=collector["headers"],
    )
    assert finish_denied.status_code == 403
    assert "not assigned" in finish_denied.json()["detail"]

    _assign(client, truck["id"], collector["id"], dispatcher["headers"])
    assert (
        client.post(
            f"/api/v1/trucks/{truck['id']}/collect-vicinity",
            json={},
            headers=collector["headers"],
        ).status_code
        == 200
    )
    # Binding passes now; the 404 is the missing active route, not the gate.
    assert (
        client.post(
            f"/api/v1/trucks/{truck['id']}/finish-route",
            headers=collector["headers"],
        ).status_code
        == 404
    )

    assert (
        client.post(
            f"/api/v1/trucks/{other['id']}/collect-vicinity",
            json={},
            headers=collector["headers"],
        ).status_code
        == 403
    )
    assert (
        client.post(
            f"/api/v1/trucks/{other['id']}/finish-route",
            headers=collector["headers"],
        ).status_code
        == 403
    )


def test_reads_stay_assignment_free(client, dispatcher, collector, make_user):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    post = client.post(
        "/api/v1/garbage",
        json={
            "user_id": resident["id"],
            "longitude": 3.371,
            "latitude": 6.451,
            "types": ["plastic"],
        },
        headers=resident["headers"],
    )
    assert post.status_code == 201

    assert (
        client.get(f"/api/v1/trucks/{truck['id']}", headers=collector["headers"]).status_code
        == 200
    )
    route = client.get(f"/api/v1/trucks/{truck['id']}/route", headers=collector["headers"])
    assert route.status_code == 200
    listed = client.get("/api/v1/trucks", headers=collector["headers"])
    assert listed.status_code == 200
    assert [t["operator_id"] for t in listed.json()] == [None]


def test_logistics_and_admin_bypass_assignment(client, dispatcher, make_user):
    admin = make_user("admin")
    truck = _make_truck(client, dispatcher["headers"])
    for headers in (dispatcher["headers"], admin["headers"]):
        assert (
            client.post(
                f"/api/v1/trucks/{truck['id']}/collect-vicinity", json={}, headers=headers
            ).status_code
            == 200
        )
        # Binding bypassed; the 404 is the missing active route, not the gate.
        assert (
            client.post(
                f"/api/v1/trucks/{truck['id']}/finish-route", headers=headers
            ).status_code
            == 404
        )


def test_claim_and_release_routes_available(client, dispatcher, collector):
    truck = _make_truck(client, dispatcher["headers"])
    claim = client.post(
        f"/api/v1/trucks/{truck['id']}/claim", headers=collector["headers"]
    )
    assert claim.status_code == 200
    release = client.post(
        f"/api/v1/trucks/{truck['id']}/release", headers=collector["headers"]
    )
    assert release.status_code == 200


def test_binding_unknown_truck_404(client, dispatcher, collector):
    payload = {"operator_id": collector["id"]}
    assert (
        client.patch(
            "/api/v1/trucks/000000000000000000000000",
            json=payload,
            headers=dispatcher["headers"],
        ).status_code
        == 404
    )
    assert (
        client.patch("/api/v1/trucks/not-an-id", json=payload, headers=dispatcher["headers"])
    ).status_code == 404
    assert (
        client.delete(
            "/api/v1/trucks/000000000000000000000000", headers=dispatcher["headers"]
        ).status_code
        == 404
    )


def _ping(client, truck_id, headers, lon=3.38, lat=6.46):
    return client.post(
        f"/api/v1/trucks/{truck_id}/location",
        json={"longitude": lon, "latitude": lat},
        headers=headers,
    )


def test_collector_pings_own_truck(client, dispatcher, collector):
    truck = _make_truck(client, dispatcher["headers"])
    _assign(client, truck["id"], collector["id"], dispatcher["headers"])
    response = _ping(client, truck["id"], collector["headers"])
    assert response.status_code == 200, response.text
    assert response.json()["current_location"]["coordinates"] == [3.38, 6.46]


def test_collector_ping_other_or_unassigned_truck_403(client, dispatcher, collector, collector2):
    truck = _make_truck(client, dispatcher["headers"])
    _assign(client, truck["id"], collector2["id"], dispatcher["headers"])
    forbidden = _ping(client, truck["id"], collector["headers"])
    assert forbidden.status_code == 403

    free = _make_truck(client, dispatcher["headers"], plate_number="OP-FREE")
    assert _ping(client, free["id"], collector["headers"]).status_code == 403


def test_logistics_pings_any_truck(client, dispatcher, collector):
    truck = _make_truck(client, dispatcher["headers"])
    _assign(client, truck["id"], collector["id"], dispatcher["headers"])
    response = _ping(client, truck["id"], dispatcher["headers"], lon=1.0, lat=2.0)
    assert response.status_code == 200, response.text
    assert response.json()["current_location"]["coordinates"] == [1.0, 2.0]


def test_ping_unknown_truck_404_and_bad_coords_422(client, dispatcher):
    assert (
        _ping(client, "000000000000000000000000", dispatcher["headers"]).status_code == 404
    )
    truck = _make_truck(client, dispatcher["headers"])
    bad = client.post(
        f"/api/v1/trucks/{truck['id']}/location",
        json={"longitude": 999, "latitude": 6.46},
        headers=dispatcher["headers"],
    )
    assert bad.status_code == 422


def test_patch_updates_location_as_geojson(client, dispatcher):
    truck = _make_truck(client, dispatcher["headers"])
    response = client.patch(
        f"/api/v1/trucks/{truck['id']}",
        json={"current_location": {"longitude": 9.0, "latitude": 8.0}},
        headers=dispatcher["headers"],
    )
    assert response.status_code == 200, response.text
    location = response.json()["current_location"]
    assert location == {"type": "Point", "coordinates": [9.0, 8.0]}
