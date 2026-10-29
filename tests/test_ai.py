def test_classify_placeholder_returns_stub(client, make_user):
    me = make_user()
    response = client.post(
        "/api/v1/ai/classify", json={"description": "old phone battery"}, headers=me["headers"]
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["placeholder"] is True
    assert body["suggested_types"] == ["general"]
    assert body["confidence"] == 0.0
    assert body["message"]


def test_classify_rejects_empty_description(client, make_user):
    me = make_user()
    response = client.post(
        "/api/v1/ai/classify", json={"description": ""}, headers=me["headers"]
    )
    assert response.status_code == 422


def test_classify_requires_auth(client):
    assert client.post("/api/v1/ai/classify", json={"description": "x"}).status_code == 401
