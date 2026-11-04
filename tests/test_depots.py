import pytest


@pytest.fixture
def dispatcher(client, make_user):
    return make_user("logistics")


@pytest.fixture
def depot_user(client, make_user):
    return make_user("depot")


def _make_truck(client, headers, **overrides):
    payload = {
        "plate_number": "DEP-1",
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
        "name": "North Depot",
        "kind": "dump_site",
        "location": {"longitude": 3.38, "latitude": 6.46},
        "accepted_types": ["plastic"],
        "address": "1 Depot Rd",
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


def _collect(client, truck_id, headers, **payload):
    response = client.post(
        f"/api/v1/trucks/{truck_id}/collect-vicinity", json=payload, headers=headers
    )
    assert response.status_code == 200, response.text
    return response.json()


def _bind(client, admin_headers, user_id, depot_id):
    return client.patch(
        f"/api/v1/auth/users/{user_id}/depot",
        json={"depot_id": depot_id},
        headers=admin_headers,
    )


def test_depot_registers_publicly_with_no_binding(client, make_user):
    user = make_user("depot")
    me = client.get("/api/v1/auth/me", headers=user["headers"])
    assert me.status_code == 200, me.text
    assert me.json()["role"] == "depot"
    assert me.json()["depot_id"] is None


def test_admin_binds_and_unbinds_depot_user(client, dispatcher, depot_user, make_user):
    admin = make_user("admin")
    depot = _make_facility(client, dispatcher["headers"])

    bound = _bind(client, admin["headers"], depot_user["id"], depot["id"])
    assert bound.status_code == 200, bound.text
    assert bound.json()["depot_id"] == depot["id"]

    unbound = _bind(client, admin["headers"], depot_user["id"], None)
    assert unbound.status_code == 200, unbound.text
    assert unbound.json()["depot_id"] is None


def test_binding_rejects_wrong_role_and_unknown_ids(
    client, dispatcher, depot_user, make_user
):
    admin = make_user("admin")
    resident = make_user()
    depot = _make_facility(client, dispatcher["headers"])

    wrong_role = _bind(client, admin["headers"], resident["id"], depot["id"])
    assert wrong_role.status_code == 400

    unknown_depot = _bind(
        client, admin["headers"], depot_user["id"], "000000000000000000000000"
    )
    assert unknown_depot.status_code == 404

    unknown_user = _bind(
        client, admin["headers"], "000000000000000000000000", depot["id"]
    )
    assert unknown_user.status_code == 404

    forbidden = _bind(client, dispatcher["headers"], depot_user["id"], depot["id"])
    assert forbidden.status_code == 403


def test_role_change_clears_binding(client, dispatcher, depot_user, make_user):
    admin = make_user("admin")
    depot = _make_facility(client, dispatcher["headers"])
    assert _bind(client, admin["headers"], depot_user["id"], depot["id"]).status_code == 200

    changed = client.patch(
        f"/api/v1/auth/users/{depot_user['id']}/role",
        json={"role": "logistics"},
        headers=admin["headers"],
    )
    assert changed.status_code == 200, changed.text
    assert changed.json()["depot_id"] is None


def test_facility_delete_releases_binding(client, dispatcher, depot_user, make_user):
    admin = make_user("admin")
    depot = _make_facility(client, dispatcher["headers"])
    assert _bind(client, admin["headers"], depot_user["id"], depot["id"]).status_code == 200

    deleted = client.delete(
        f"/api/v1/logistics/facilities/{depot['id']}", headers=dispatcher["headers"]
    )
    assert deleted.status_code == 204, deleted.text

    me = client.get("/api/v1/auth/me", headers=depot_user["headers"])
    assert me.status_code == 200, me.text
    assert me.json()["depot_id"] is None


def test_receive_clears_load_and_records_receipt(
    client, dispatcher, depot_user, make_user
):
    admin = make_user("admin")
    resident = make_user()
    depot = _make_facility(client, dispatcher["headers"])
    assert _bind(client, admin["headers"], depot_user["id"], depot["id"]).status_code == 200
    truck = _make_truck(client, dispatcher["headers"])
    _make_post(client, resident)
    _make_post(client, resident)
    _collect(client, truck["id"], dispatcher["headers"])

    mine = client.get("/api/v1/depots/mine", headers=depot_user["headers"])
    assert mine.status_code == 200, mine.text
    assert mine.json()["name"] == "North Depot"

    inbound = client.get("/api/v1/depots/mine/trucks", headers=depot_user["headers"])
    assert inbound.status_code == 200, inbound.text
    assert [t["id"] for t in inbound.json()] == [truck["id"]]

    received = client.post(
        "/api/v1/depots/mine/receive",
        json={"truck_id": truck["id"]},
        headers=depot_user["headers"],
    )
    assert received.status_code == 200, received.text
    body = received.json()
    assert body["depot_id"] == depot["id"]
    assert body["truck_id"] == truck["id"]
    assert body["plate_number"] == "DEP-1"
    assert body["load_cleared"] == 2
    assert body["load_by_type"] == {"plastic": 2}
    assert body["received_by"] == depot_user["id"]

    truck_after = client.get(
        f"/api/v1/trucks/{truck['id']}", headers=dispatcher["headers"]
    )
    assert truck_after.json()["load"] == 0
    assert truck_after.json()["load_by_type"] == {}
    assert truck_after.json()["availability"] == "available"

    assert (
        client.get("/api/v1/depots/mine/trucks", headers=depot_user["headers"]).json()
        == []
    )
    receipts = client.get(
        "/api/v1/depots/mine/receipts", headers=depot_user["headers"]
    )
    assert receipts.status_code == 200, receipts.text
    assert [r["id"] for r in receipts.json()] == [body["id"]]


def test_receive_rejects_types_depot_cannot_accept(
    client, dispatcher, depot_user, make_user
):
    admin = make_user("admin")
    resident = make_user()
    depot = _make_facility(client, dispatcher["headers"])
    assert _bind(client, admin["headers"], depot_user["id"], depot["id"]).status_code == 200
    truck = _make_truck(
        client, dispatcher["headers"], garbage_types=["plastic", "glass"]
    )
    # A two-type post consumes two capacity units, tracked per type.
    _make_post(client, resident, types=["glass", "plastic"])
    collected = _collect(client, truck["id"], dispatcher["headers"])
    assert collected["load"] == 2
    assert collected["load_by_type"] == {"glass": 1, "plastic": 1}

    # The depot accepts plastic only.
    rejected = client.post(
        "/api/v1/depots/mine/receive",
        json={"truck_id": truck["id"]},
        headers=depot_user["headers"],
    )
    assert rejected.status_code == 400, rejected.text
    assert "glass" in rejected.json()["detail"]

    truck_after = client.get(
        f"/api/v1/trucks/{truck['id']}", headers=dispatcher["headers"]
    )
    assert truck_after.json()["load"] == 2
    receipts = client.get(
        "/api/v1/depots/mine/receipts", headers=depot_user["headers"]
    )
    assert receipts.json() == []


def test_depot_endpoints_enforce_role_and_binding(client, dispatcher, depot_user, make_user):
    resident = make_user()

    assert (
        client.get("/api/v1/depots/mine", headers=resident["headers"]).status_code == 403
    )
    assert (
        client.post(
            "/api/v1/depots/mine/receive",
            json={"truck_id": "000000000000000000000000"},
            headers=resident["headers"],
        ).status_code
        == 403
    )

    # Bound to nothing yet: actionable endpoints fail open with guidance.
    assert (
        client.get("/api/v1/depots/mine", headers=depot_user["headers"]).status_code
        == 400
    )
    assert (
        client.post(
            "/api/v1/depots/mine/receive",
            json={"truck_id": "000000000000000000000000"},
            headers=depot_user["headers"],
        ).status_code
        == 400
    )

    admin = make_user("admin")
    depot = _make_facility(client, dispatcher["headers"])
    assert _bind(client, admin["headers"], depot_user["id"], depot["id"]).status_code == 200
    missing = client.post(
        "/api/v1/depots/mine/receive",
        json={"truck_id": "000000000000000000000000"},
        headers=depot_user["headers"],
    )
    assert missing.status_code == 404


def test_depot_registers_own_depot_and_binds(client, depot_user):
    payload = {
        "name": "South Depot",
        "kind": "dump_site",
        "location": {"longitude": 3.41, "latitude": 6.47},
        "accepted_types": ["plastic", "general"],
        "address": "9 South Rd",
    }
    created = client.post(
        "/api/v1/depots/mine/register", json=payload, headers=depot_user["headers"]
    )
    assert created.status_code == 201, created.text
    assert created.json()["name"] == "South Depot"

    me = client.get("/api/v1/auth/me", headers=depot_user["headers"])
    assert me.json()["depot_id"] == created.json()["id"]

    mine = client.get("/api/v1/depots/mine", headers=depot_user["headers"])
    assert mine.status_code == 200, mine.text
    assert mine.json()["id"] == created.json()["id"]


def test_depot_joins_existing_depot(client, dispatcher, depot_user, make_user):
    depot = _make_facility(client, dispatcher["headers"])
    second = make_user("depot")

    joined = client.post(
        "/api/v1/depots/mine/join",
        json={"facility_id": depot["id"]},
        headers=second["headers"],
    )
    assert joined.status_code == 200, joined.text
    assert joined.json()["id"] == depot["id"]

    me = client.get("/api/v1/auth/me", headers=second["headers"])
    assert me.json()["depot_id"] == depot["id"]

    missing = client.post(
        "/api/v1/depots/mine/join",
        json={"facility_id": "000000000000000000000000"},
        headers=depot_user["headers"],
    )
    assert missing.status_code == 404


def test_register_and_join_enforce_depot_role(client, dispatcher, make_user):
    resident = make_user()
    payload = {
        "name": "Rogue Depot",
        "kind": "dump_site",
        "location": {"longitude": 3.41, "latitude": 6.47},
        "accepted_types": ["plastic"],
    }
    assert (
        client.post(
            "/api/v1/depots/mine/register", json=payload, headers=resident["headers"]
        ).status_code
        == 403
    )
    assert (
        client.post(
            "/api/v1/depots/mine/join",
            json={"facility_id": "000000000000000000000000"},
            headers=dispatcher["headers"],
        ).status_code
        == 403
    )


def test_depot_can_browse_facilities_to_join(client, dispatcher, depot_user, make_user):
    resident = make_user()
    _make_facility(client, dispatcher["headers"])
    listed = client.get(
        "/api/v1/logistics/facilities", headers=depot_user["headers"]
    )
    assert listed.status_code == 200, listed.text
    assert len(listed.json()) == 1
    assert (
        client.get(
            "/api/v1/logistics/facilities", headers=resident["headers"]
        ).status_code
        == 403
    )


def test_dispute_returns_load_to_collecting_truck(
    client, dispatcher, depot_user, make_user
):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    p1 = _make_post(client, resident)
    p2 = _make_post(client, resident)
    _collect(client, truck["id"], dispatcher["headers"])

    def truck_state():
        return client.get(
            f"/api/v1/trucks/{truck['id']}", headers=dispatcher["headers"]
        ).json()

    def load():
        return truck_state()["load"]

    assert load() == 2
    assert truck_state()["load_by_type"] == {"plastic": 2}
    assert (
        client.patch(
            f"/api/v1/garbage/{p1['id']}/dispute-collected", headers=resident["headers"]
        ).status_code
        == 200
    )
    assert load() == 1
    assert (
        client.patch(
            f"/api/v1/garbage/{p2['id']}/dispute-collected", headers=resident["headers"]
        ).status_code
        == 200
    )
    assert load() == 0
    assert truck_state()["load_by_type"] == {"plastic": 0}


def test_dispute_after_receipt_floors_load_at_zero(
    client, dispatcher, depot_user, make_user
):
    admin = make_user("admin")
    resident = make_user()
    depot = _make_facility(client, dispatcher["headers"])
    assert _bind(client, admin["headers"], depot_user["id"], depot["id"]).status_code == 200
    truck = _make_truck(client, dispatcher["headers"])
    post = _make_post(client, resident)
    _collect(client, truck["id"], dispatcher["headers"])
    received = client.post(
        "/api/v1/depots/mine/receive",
        json={"truck_id": truck["id"]},
        headers=depot_user["headers"],
    )
    assert received.status_code == 200, received.text

    disputed = client.patch(
        f"/api/v1/garbage/{post['id']}/dispute-collected", headers=resident["headers"]
    )
    assert disputed.status_code == 200, disputed.text
    truck_after = client.get(
        f"/api/v1/trucks/{truck['id']}", headers=dispatcher["headers"]
    )
    assert truck_after.json()["load"] == 0


def test_dispute_returns_load_without_touching_availability(
    client, dispatcher, make_user
):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"], capacity=1)
    post = _make_post(client, resident)
    _collect(client, truck["id"], dispatcher["headers"])

    def truck_state():
        return client.get(
            f"/api/v1/trucks/{truck['id']}", headers=dispatcher["headers"]
        ).json()

    assert truck_state()["load"] == 1
    assert truck_state()["availability"] == "available"
    assert (
        client.patch(
            f"/api/v1/garbage/{post['id']}/dispute-collected", headers=resident["headers"]
        ).status_code
        == 200
    )
    assert truck_state()["load"] == 0
    assert truck_state()["load_by_type"] == {"plastic": 0}
    assert truck_state()["availability"] == "available"
