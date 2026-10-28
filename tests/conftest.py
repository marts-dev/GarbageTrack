from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from app.api.deps import get_db
from app.main import app
from tests.fakes import FakeDatabase


@pytest.fixture
def fake_db() -> FakeDatabase:
    return FakeDatabase()


@pytest.fixture
def client(fake_db: FakeDatabase):
    app.dependency_overrides[get_db] = lambda: fake_db
    with (
        patch("app.main.connect_to_mongo", new=AsyncMock()),
        patch("app.main.ensure_indexes", new=AsyncMock()),
        patch("app.main.close_mongo_connection", new=AsyncMock()),
        TestClient(app) as test_client,
    ):
        yield test_client
    app.dependency_overrides.clear()
