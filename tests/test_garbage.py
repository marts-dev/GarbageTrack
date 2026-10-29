import base64

TINY_PNG = base64.b64encode(b"fake-image-bytes").decode()


def _post_payload(user_id, **overrides):
    payload = {
        "user_id": user_id,
        "longitude": 3.37,
        "latitude": 6.45,
        "types": ["plastic", "metal"],
        "description": "bags by the gate",
    }
    payload.update(overrides)
    return payload


def test_create_post_with_multiple_types_and_image(client, make_user, fake_db):
    me = make_user()
    response = client.post(
        "/api/v1/garbage",
        json=_post_payload(me["id"], image_base64=TINY_PNG, image_content_type="image/png"),
        headers=me["headers"],
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["user_id"] == me["id"]
    assert body["types"] == ["plastic", "metal"]
    assert body["status"] == "posted"
    assert body["has_image"] is True
    assert body["image_content_type"] == "image/png"
    assert body["location"] == {"type": "Point", "coordinates": [3.37, 6.45]}
    assert body["id"]

    stored = next(iter(fake_db["garbage_posts"].docs.values()))
    assert stored["image_base64"] == TINY_PNG


def test_create_post_rejects_empty_types(client, make_user):
    me = make_user()
    response = client.post(
        "/api/v1/garbage", json=_post_payload(me["id"], types=[]), headers=me["headers"]
    )
    assert response.status_code == 422


def test_create_post_rejects_bad_image(client, make_user):
    me = make_user()
    response = client.post(
        "/api/v1/garbage",
        json=_post_payload(me["id"], image_base64="!!!not-base64!!!"),
        headers=me["headers"],
    )
    assert response.status_code == 422


def test_create_post_as_other_user_forbidden(client, make_user):
    me = make_user()
    other = make_user()
    response = client.post(
        "/api/v1/garbage", json=_post_payload(other["id"]), headers=me["headers"]
    )
    assert response.status_code == 403


def test_create_post_requires_auth(client, make_user):
    me = make_user()
    response = client.post("/api/v1/garbage", json=_post_payload(me["id"]))
    assert response.status_code == 401


def test_read_post_and_missing_returns_404(client, make_user):
    me = make_user()
    created = client.post(
        "/api/v1/garbage", json=_post_payload(me["id"]), headers=me["headers"]
    ).json()
    response = client.get(f"/api/v1/garbage/{created['id']}", headers=me["headers"])
    assert response.status_code == 200
    assert response.json()["id"] == created["id"]

    assert (
        client.get("/api/v1/garbage/000000000000000000000000", headers=me["headers"]).status_code
        == 404
    )
    assert client.get("/api/v1/garbage/not-an-id", headers=me["headers"]).status_code == 404
    assert client.get(f"/api/v1/garbage/{created['id']}").status_code == 401


def test_list_posts_filters_by_user_and_status(client, make_user):
    me = make_user()
    other = make_user()
    client.post("/api/v1/garbage", json=_post_payload(me["id"]), headers=me["headers"])
    client.post("/api/v1/garbage", json=_post_payload(other["id"]), headers=other["headers"])

    mine = client.get("/api/v1/garbage", params={"user_id": me["id"]}, headers=me["headers"])
    assert len(mine.json()) == 1
    posted = client.get("/api/v1/garbage", params={"status": "posted"}, headers=me["headers"])
    assert len(posted.json()) == 2
    collected = client.get("/api/v1/garbage", params={"status": "collected"}, headers=me["headers"])
    assert collected.json() == []
    assert client.get("/api/v1/garbage").status_code == 401


def test_confirm_collected_transitions_and_conflicts(client, make_user):
    me = make_user()
    created = client.post(
        "/api/v1/garbage", json=_post_payload(me["id"]), headers=me["headers"]
    ).json()
    post_id = created["id"]

    first = client.patch(f"/api/v1/garbage/{post_id}/confirm-collected", headers=me["headers"])
    assert first.status_code == 200, first.text
    assert first.json()["status"] == "collected"
    assert first.json()["collected_at"] is not None

    second = client.patch(f"/api/v1/garbage/{post_id}/confirm-collected", headers=me["headers"])
    assert second.status_code == 409

    missing = client.patch(
        "/api/v1/garbage/000000000000000000000000/confirm-collected", headers=me["headers"]
    )
    assert missing.status_code == 404


def test_confirm_collected_by_stranger_forbidden_but_collector_allowed(client, make_user):
    me = make_user()
    stranger = make_user()
    collector = make_user("collector")
    created = client.post(
        "/api/v1/garbage", json=_post_payload(me["id"]), headers=me["headers"]
    ).json()

    denied = client.patch(
        f"/api/v1/garbage/{created['id']}/confirm-collected", headers=stranger["headers"]
    )
    assert denied.status_code == 403

    allowed = client.patch(
        f"/api/v1/garbage/{created['id']}/confirm-collected", headers=collector["headers"]
    )
    assert allowed.status_code == 200
