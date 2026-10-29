def test_create_schedule_and_list_enroute(client, make_user):
    dispatcher = make_user("logistics")
    resident = make_user()
    created = client.post(
        "/api/v1/trucks/schedules",
        json={
            "plate_number": "ABC-123",
            "garbage_types": ["plastic", "paper"],
            "status": "enroute",
            "current_location": {"longitude": 3.37, "latitude": 6.45},
            "eta_minutes": 25,
        },
        headers=dispatcher["headers"],
    )
    assert created.status_code == 201, created.text
    assert created.json()["status"] == "enroute"

    client.post(
        "/api/v1/trucks/schedules",
        json={"plate_number": "XYZ-999", "garbage_types": ["organic"]},
        headers=dispatcher["headers"],
    )

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
