def test_classify_placeholder_returns_stub(client):
    response = client.post("/api/v1/ai/classify", json={"description": "old phone battery"})
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["placeholder"] is True
    assert body["suggested_types"] == ["general"]
    assert body["confidence"] == 0.0
    assert body["message"]


def test_classify_rejects_empty_description(client):
    response = client.post("/api/v1/ai/classify", json={"description": ""})
    assert response.status_code == 422
