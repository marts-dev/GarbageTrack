import asyncio


def _register(client, email="ada@example.com", password="Password123", **extra):
    payload = {"email": email, "password": password, "full_name": "Ada Test"}
    payload.update(extra)
    return client.post("/api/v1/auth/register", json=payload)


def _login(client, email="ada@example.com", password="Password123"):
    return client.post("/api/v1/auth/login", data={"username": email, "password": password})


def test_register_login_me_refresh_flow(client):
    registered = _register(client)
    assert registered.status_code == 201, registered.text
    assert registered.json()["role"] == "resident"
    assert registered.json()["full_name"] == "Ada Test"
    assert "hashed_password" not in registered.json()

    login = _login(client)
    assert login.status_code == 200, login.text
    tokens = login.json()
    assert tokens["token_type"] == "bearer"
    headers = {"Authorization": f"Bearer {tokens['access_token']}"}

    me = client.get("/api/v1/auth/me", headers=headers)
    assert me.status_code == 200
    assert me.json()["email"] == "ada@example.com"

    refreshed = client.post("/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert refreshed.status_code == 200, refreshed.text
    assert refreshed.json()["access_token"] != tokens["access_token"]


def test_register_duplicate_email_conflicts(client):
    assert _register(client).status_code == 201
    assert _register(client).status_code == 409
    assert _register(client, email="ADA@example.com").status_code == 409


def test_login_rejects_bad_credentials(client):
    _register(client)
    assert _login(client, password="Wrongpass1").status_code == 401
    assert _login(client, email="nobody@example.com").status_code == 401


def test_register_validates_input(client):
    assert _register(client, email="not-an-email").status_code == 422
    assert _register(client, password="short").status_code == 422


def test_register_name_is_optional(client):
    response = client.post(
        "/api/v1/auth/register",
        json={"email": "noname@example.com", "password": "Password123"},
    )
    assert response.status_code == 201, response.text
    assert response.json()["full_name"] is None


def test_register_allows_operational_roles_but_not_admin(client):
    collector = _register(client, email="c@example.com", role="collector")
    assert collector.status_code == 201
    assert collector.json()["role"] == "collector"

    admin = _register(client, email="root@example.com", role="admin")
    assert admin.status_code == 400


def test_protected_routes_reject_bad_tokens(client):
    assert client.get("/api/v1/auth/me").status_code == 401
    assert (
        client.get("/api/v1/auth/me", headers={"Authorization": "Bearer garbage"}).status_code
        == 401
    )
    login = _login(client, email="ghost@example.com", password="Password123")
    assert login.status_code == 401


def test_refresh_rejects_access_token_and_garbage(client, make_user):
    me = make_user()
    assert (
        client.post(
            "/api/v1/auth/refresh", json={"refresh_token": me["tokens"]["access_token"]}
        ).status_code
        == 401
    )
    assert client.post("/api/v1/auth/refresh", json={"refresh_token": "garbage"}).status_code == 401


def test_admin_can_list_and_promote_users(client, make_user):
    admin = make_user("admin")
    resident = make_user()

    listed = client.get("/api/v1/auth/users", headers=admin["headers"])
    assert listed.status_code == 200
    assert len(listed.json()) == 2

    promoted = client.patch(
        f"/api/v1/auth/users/{resident['id']}/role",
        json={"role": "logistics"},
        headers=admin["headers"],
    )
    assert promoted.status_code == 200, promoted.text
    assert promoted.json()["role"] == "logistics"

    assert (
        client.patch(
            "/api/v1/auth/users/000000000000000000000000/role",
            json={"role": "logistics"},
            headers=admin["headers"],
        ).status_code
        == 404
    )


def test_user_admin_routes_forbidden_for_non_admin(client, make_user):
    resident = make_user()
    assert client.get("/api/v1/auth/users", headers=resident["headers"]).status_code == 403
    assert (
        client.patch(
            f"/api/v1/auth/users/{resident['id']}/role",
            json={"role": "admin"},
            headers=resident["headers"],
        ).status_code
        == 403
    )


def test_legacy_user_document_is_read(client, fake_db):
    from datetime import UTC, datetime

    from bson import ObjectId

    from app.core import security

    fake_db["users"].docs[ObjectId()] = {
        "_id": ObjectId(),
        "email": "legacy@example.com",
        "hashed_password": security.hash_password("Password123"),
        "roles": ["collector"],
        "is_active": True,
        "created_at": datetime.now(UTC),
    }
    login = _login(client, email="legacy@example.com", password="Password123")
    assert login.status_code == 200
    me = client.get(
        "/api/v1/auth/me",
        headers={"Authorization": f"Bearer {login.json()['access_token']}"},
    )
    assert me.json()["role"] == "collector"
    assert me.json()["full_name"] is None


def test_update_own_profile_name(client, make_user):
    me = make_user()
    response = client.patch(
        "/api/v1/auth/me", json={"full_name": "Ada Lovelace"}, headers=me["headers"]
    )
    assert response.status_code == 200, response.text
    assert response.json()["full_name"] == "Ada Lovelace"

    reread = client.get("/api/v1/auth/me", headers=me["headers"])
    assert reread.json()["full_name"] == "Ada Lovelace"

    assert client.patch("/api/v1/auth/me", json={"full_name": ""}, headers=me["headers"]).status_code == 422
    assert client.patch("/api/v1/auth/me", json={"full_name": "X"}).status_code == 401


def test_password_is_stored_hashed(client, fake_db):
    _register(client)
    stored = next(iter(fake_db["users"].docs.values()))
    assert stored["hashed_password"] != "Password123"
    assert stored["email"] == "ada@example.com"


def test_jwt_secret_is_masked_and_length_enforced():
    import pytest
    from pydantic import SecretStr, ValidationError

    from app.core.config import Settings, settings

    assert isinstance(settings.jwt_secret_key, SecretStr)
    assert settings.jwt_secret_key.get_secret_value() not in repr(settings)
    with pytest.raises(ValidationError):
        Settings(jwt_secret_key=SecretStr("too-short"))


def test_ensure_default_admin_seeds_once(client, fake_db, monkeypatch):
    from app.core.config import settings
    from app.services import auth as auth_service

    monkeypatch.setattr(settings, "admin_email", "ops@example.com")
    monkeypatch.setattr(settings, "admin_password", "OpsPassword123")
    asyncio.run(auth_service.ensure_default_admin(fake_db))
    asyncio.run(auth_service.ensure_default_admin(fake_db))
    assert len(fake_db["users"].docs) == 1

    login = _login(client, email="ops@example.com", password="OpsPassword123")
    assert login.status_code == 200
