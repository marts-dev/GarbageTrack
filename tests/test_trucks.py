def test_create_schedule_and_list_enroute(client, make_user):
    dispatcher = make_user("logistics")
    resident = make_user()
    collector = make_user("collector")
    created = client.post(
        "/api/v1/trucks/schedules",
        json={
            "plate_number": "ABC-123",
            "garbage_types": ["plastic", "paper"],
            "current_location": {"longitude": 3.37, "latitude": 6.45},
            "eta_minutes": 25,
        },
        headers=dispatcher["headers"],
    )
    assert created.status_code == 201, created.text
    assert created.json()["availability"] == "available"

    client.post(
        "/api/v1/trucks/schedules",
        json={"plate_number": "XYZ-999", "garbage_types": ["organic"]},
        headers=dispatcher["headers"],
    )

    # Nothing runs yet: the live map is empty.
    assert (
        client.get("/api/v1/trucks/enroute", headers=resident["headers"]).json() == []
    )

    # Assign a route and pick up once: the run goes live.
    post = client.post(
        "/api/v1/garbage",
        json={
            "user_id": resident["id"],
            "longitude": 3.371,
            "latitude": 6.451,
            "types": ["plastic"],
        },
        headers=resident["headers"],
    ).json()
    depot = client.post(
        "/api/v1/logistics/facilities",
        json={
            "name": "North Depot",
            "kind": "dump_site",
            "location": {"longitude": 3.38, "latitude": 6.46},
            "accepted_types": ["plastic"],
        },
        headers=dispatcher["headers"],
    ).json()
    assigned = client.post(
        "/api/v1/logistics/routes",
        json={
            "truck_id": created.json()["id"],
            "post_ids": [post["id"]],
            "depot_ids": [depot["id"]],
        },
        headers=dispatcher["headers"],
    )
    assert assigned.status_code == 201, assigned.text
    assert (
        client.get("/api/v1/trucks/enroute", headers=resident["headers"]).json() == []
    )
    bound = client.patch(
        f"/api/v1/trucks/{created.json()['id']}",
        json={"operator_id": collector["id"]},
        headers=dispatcher["headers"],
    )
    assert bound.status_code == 200, bound.text
    collect = client.post(
        f"/api/v1/trucks/{created.json()['id']}/collect-vicinity",
        json={},
        headers=collector["headers"],
    )
    assert collect.status_code == 200, collect.text

    response = client.get("/api/v1/trucks/enroute", headers=resident["headers"])
    assert response.status_code == 200
    trucks = response.json()
    assert len(trucks) == 1
    assert trucks[0]["plate_number"] == "ABC-123"
    assert trucks[0]["garbage_types"] == ["plastic", "paper"]
    assert trucks[0]["eta_minutes"] == 25
    assert trucks[0]["current_location"] == {"type": "Point", "coordinates": [3.37, 6.45]}


def test_enroute_empty_when_no_trucks(client, make_user):
    resident = make_user()
    assert client.get("/api/v1/trucks/enroute", headers=resident["headers"]).json() == []
    assert client.get("/api/v1/trucks/enroute").status_code == 401


def test_create_schedule_rejects_empty_types(client, make_user):
    dispatcher = make_user("logistics")
    response = client.post(
        "/api/v1/trucks/schedules",
        json={"plate_number": "ABC-123", "garbage_types": []},
        headers=dispatcher["headers"],
    )
    assert response.status_code == 422


def test_create_schedule_requires_logistics_role(client, make_user):
    resident = make_user()
    response = client.post(
        "/api/v1/trucks/schedules",
        json={"plate_number": "ABC-123", "garbage_types": ["plastic"]},
        headers=resident["headers"],
    )
    assert response.status_code == 403
    assert (
        client.post(
            "/api/v1/trucks/schedules",
            json={"plate_number": "ABC-123", "garbage_types": ["plastic"]},
        ).status_code
        == 401
    )
