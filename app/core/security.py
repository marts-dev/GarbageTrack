"""Password hashing and JWT handling (HS256 access + refresh tokens)."""

import uuid
from datetime import timedelta

import bcrypt
import jwt

from app.core.config import settings
from app.models.common import utcnow

ACCESS_TOKEN_TYPE = "access"
REFRESH_TOKEN_TYPE = "refresh"


def hash_password(password: str) -> str:
    salt = bcrypt.gensalt(rounds=settings.password_hash_rounds)
    return bcrypt.hashpw(password.encode("utf-8"), salt).decode("utf-8")


def verify_password(password: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode("utf-8"), hashed.encode("utf-8"))
    except ValueError:
        return False


def _create_token(subject: str, token_type: str, expires: timedelta) -> str:
    now = utcnow()
    payload = {
        "sub": subject,
        "type": token_type,
        "jti": uuid.uuid4().hex,
        "iat": now,
        "exp": now + expires,
    }
    key = settings.jwt_secret_key.get_secret_value()
    return jwt.encode(payload, key, algorithm=settings.jwt_algorithm)


def create_access_token(subject: str) -> str:
    return _create_token(
        subject, ACCESS_TOKEN_TYPE, timedelta(minutes=settings.access_token_expire_minutes)
    )


def create_refresh_token(subject: str) -> str:
    return _create_token(
        subject, REFRESH_TOKEN_TYPE, timedelta(days=settings.refresh_token_expire_days)
    )


class TokenError(Exception):
    pass


def decode_token(token: str, expected_type: str) -> dict:
    try:
        key = settings.jwt_secret_key.get_secret_value()
        payload = jwt.decode(token, key, algorithms=[settings.jwt_algorithm])
    except jwt.ExpiredSignatureError as exc:
        raise TokenError("token has expired") from exc
    except jwt.InvalidTokenError as exc:
        raise TokenError("token is invalid") from exc
    if payload.get("type") != expected_type or not payload.get("sub"):
        raise TokenError("token is invalid")
    return payload
