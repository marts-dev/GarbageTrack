def test_save_and_read_location(client, make_user):
    me = make_user()
    put = client.put(
        f"/api/v1/users/{me['id']}/location",
        json={"longitude": 3.37, "latitude": 6.45},
        headers=me["headers"],
    )
    assert put.status_code == 200, put.text
    assert put.json()["user_id"] == me["id"]
    assert put.json()["location"] == {"type": "Point", "coordinates": [3.37, 6.45]}

    get = client.get(f"/api/v1/users/{me['id']}/location", headers=me["headers"])
    assert get.status_code == 200
    assert get.json()["location"]["coordinates"] == [3.37, 6.45]


def test_save_location_overwrites_previous(client, make_user):
    me = make_user()
    client.put(
        f"/api/v1/users/{me['id']}/location",
        json={"longitude": 0.0, "latitude": 0.0},
        headers=me["headers"],
    )
    put = client.put(
        f"/api/v1/users/{me['id']}/location",
        json={"longitude": 3.37, "latitude": 6.45},
        headers=me["headers"],
    )
    assert put.status_code == 200
    assert put.json()["location"]["coordinates"] == [3.37, 6.45]


def test_read_location_missing_returns_404(client, make_user):
    me = make_user()
    response = client.get(f"/api/v1/users/{me['id']}/location", headers=me["headers"])
    assert response.status_code == 404


def test_save_location_rejects_bad_coordinates(client, make_user):
    me = make_user()
    response = client.put(
        f"/api/v1/users/{me['id']}/location",
        json={"longitude": 999.0, "latitude": 6.45},
        headers=me["headers"],
    )
    assert response.status_code == 422


def test_location_requires_authentication(client, make_user):
    me = make_user()
    assert client.put(f"/api/v1/users/{me['id']}/location", json={"longitude": 0, "latitude": 0}).status_code == 401
    assert client.get(f"/api/v1/users/{me['id']}/location").status_code == 401


def test_location_forbidden_for_other_user(client, make_user):
    me = make_user()
    other = make_user()
    put = client.put(
        f"/api/v1/users/{other['id']}/location",
        json={"longitude": 0, "latitude": 0},
        headers=me["headers"],
    )
    assert put.status_code == 403
    get = client.get(f"/api/v1/users/{other['id']}/location", headers=me["headers"])
    assert get.status_code == 403


def test_admin_can_access_any_location(client, make_user):
    admin = make_user("admin")
    other = make_user()
    put = client.put(
        f"/api/v1/users/{other['id']}/location",
        json={"longitude": 1.0, "latitude": 2.0},
        headers=admin["headers"],
    )
    assert put.status_code == 200, put.text
