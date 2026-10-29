import asyncio
import itertools
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from app.api.deps import get_db
from app.core.config import settings
from app.main import app
from app.models.auth import Role
from app.services import auth as auth_service
from tests.fakes import FakeDatabase


@pytest.fixture(scope="session", autouse=True)
def fast_password_hashing():
    settings.password_hash_rounds = 4
    yield
    settings.password_hash_rounds = 12


@pytest.fixture
def fake_db() -> FakeDatabase:
    return FakeDatabase()


@pytest.fixture
def client(fake_db: FakeDatabase):
    app.dependency_overrides[get_db] = lambda: fake_db
    with (
        patch("app.main.connect_to_mongo", new=AsyncMock()),
        patch("app.main.ensure_indexes", new=AsyncMock()),
        patch("app.main.ensure_default_admin", new=AsyncMock()),
        patch("app.main.close_mongo_connection", new=AsyncMock()),
        TestClient(app) as test_client,
    ):
        yield test_client
    app.dependency_overrides.clear()


@pytest.fixture
def make_user(client, fake_db: FakeDatabase):
    """Register (or seed, for admin) a user and return id/headers/tokens."""
    counter = itertools.count()

    def _make(*roles: str, password: str = "Password123"):
        role_enums = [Role(role) for role in roles] or [Role.RESIDENT]
        email = f"user{next(counter)}@example.com"
        if Role.ADMIN in role_enums:
            user = asyncio.run(auth_service.create_user(fake_db, email, password, role_enums))
            user_id = user.id
        else:
            response = client.post(
                "/api/v1/auth/register",
                json={
                    "email": email,
                    "password": password,
                    "roles": [role.value for role in role_enums],
                },
            )
            assert response.status_code == 201, response.text
            user_id = response.json()["id"]
        login = client.post(
            "/api/v1/auth/login", data={"username": email, "password": password}
        )
        assert login.status_code == 200, login.text
        tokens = login.json()
        return {
            "id": user_id,
            "email": email,
            "headers": {"Authorization": f"Bearer {tokens['access_token']}"},
            "tokens": tokens,
        }

    return _make
