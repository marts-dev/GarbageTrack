from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient


def test_liveness_reports_db_down_when_mongo_unreachable():
    with (
        patch("app.main.connect_to_mongo", new=AsyncMock()),
        patch("app.main.ensure_indexes", new=AsyncMock()),
        patch("app.main.ensure_default_admin", new=AsyncMock()),
        patch("app.main.close_mongo_connection", new=AsyncMock()),
    ):
        from app.main import app

        with TestClient(app) as client:
            response = client.get("/api/v1/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "database": "down"}


def test_liveness_reports_db_up_when_mongo_reachable():
    ping = AsyncMock(return_value={"ok": 1.0})
    fake_client = AsyncMock()
    fake_client.admin.command = ping
    with (
        patch("app.main.connect_to_mongo", new=AsyncMock()),
        patch("app.main.ensure_indexes", new=AsyncMock()),
        patch("app.main.ensure_default_admin", new=AsyncMock()),
        patch("app.main.close_mongo_connection", new=AsyncMock()),
        patch("app.api.v1.endpoints.health.database.get_client", return_value=fake_client),
    ):
        from app.main import app

        with TestClient(app) as client:
            response = client.get("/api/v1/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "database": "up"}
    ping.assert_awaited_once_with("ping")
