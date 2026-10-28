import base64

TINY_PNG = base64.b64encode(b"fake-image-bytes").decode()


def _post_payload(**overrides):
    payload = {
        "user_id": "u1",
        "longitude": 3.37,
        "latitude": 6.45,
        "types": ["plastic", "metal"],
        "description": "bags by the gate",
    }
    payload.update(overrides)
    return payload


def test_create_post_with_multiple_types_and_image(client, fake_db):
    response = client.post(
        "/api/v1/garbage",
        json=_post_payload(image_base64=TINY_PNG, image_content_type="image/png"),
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["user_id"] == "u1"
    assert body["types"] == ["plastic", "metal"]
    assert body["status"] == "posted"
    assert body["has_image"] is True
    assert body["image_content_type"] == "image/png"
    assert body["location"] == {"type": "Point", "coordinates": [3.37, 6.45]}
    assert body["id"]

    stored = next(iter(fake_db["garbage_posts"].docs.values()))
    assert stored["image_base64"] == TINY_PNG


def test_create_post_rejects_empty_types(client):
    response = client.post("/api/v1/garbage", json=_post_payload(types=[]))
    assert response.status_code == 422


def test_create_post_rejects_bad_image(client):
    response = client.post("/api/v1/garbage", json=_post_payload(image_base64="!!!not-base64!!!"))
    assert response.status_code == 422


def test_read_post_and_missing_returns_404(client):
    created = client.post("/api/v1/garbage", json=_post_payload()).json()
    response = client.get(f"/api/v1/garbage/{created['id']}")
    assert response.status_code == 200
    assert response.json()["id"] == created["id"]

    assert client.get("/api/v1/garbage/000000000000000000000000").status_code == 404
    assert client.get("/api/v1/garbage/not-an-id").status_code == 404


def test_list_posts_filters_by_user_and_status(client):
    client.post("/api/v1/garbage", json=_post_payload(user_id="u1"))
    client.post("/api/v1/garbage", json=_post_payload(user_id="u2"))

    assert len(client.get("/api/v1/garbage", params={"user_id": "u1"}).json()) == 1
    assert len(client.get("/api/v1/garbage", params={"status": "posted"}).json()) == 2
    assert client.get("/api/v1/garbage", params={"status": "collected"}).json() == []


def test_confirm_collected_transitions_and_conflicts(client):
    created = client.post("/api/v1/garbage", json=_post_payload()).json()
    post_id = created["id"]

    first = client.patch(f"/api/v1/garbage/{post_id}/confirm-collected")
    assert first.status_code == 200, first.text
    assert first.json()["status"] == "collected"
    assert first.json()["collected_at"] is not None

    second = client.patch(f"/api/v1/garbage/{post_id}/confirm-collected")
    assert second.status_code == 409

    missing = client.patch("/api/v1/garbage/000000000000000000000000/confirm-collected")
    assert missing.status_code == 404
