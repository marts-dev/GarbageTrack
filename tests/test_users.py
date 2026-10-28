def test_save_and_read_location(client):
    put = client.put("/api/v1/users/u1/location", json={"longitude": 3.37, "latitude": 6.45})
    assert put.status_code == 200, put.text
    assert put.json()["user_id"] == "u1"
    assert put.json()["location"] == {"type": "Point", "coordinates": [3.37, 6.45]}

    get = client.get("/api/v1/users/u1/location")
    assert get.status_code == 200
    assert get.json()["location"]["coordinates"] == [3.37, 6.45]


def test_save_location_overwrites_previous(client):
    client.put("/api/v1/users/u1/location", json={"longitude": 0.0, "latitude": 0.0})
    put = client.put("/api/v1/users/u1/location", json={"longitude": 3.37, "latitude": 6.45})
    assert put.status_code == 200
    assert put.json()["location"]["coordinates"] == [3.37, 6.45]


def test_read_location_missing_returns_404(client):
    response = client.get("/api/v1/users/nobody/location")
    assert response.status_code == 404


def test_save_location_rejects_bad_coordinates(client):
    response = client.put("/api/v1/users/u1/location", json={"longitude": 999.0, "latitude": 6.45})
    assert response.status_code == 422
