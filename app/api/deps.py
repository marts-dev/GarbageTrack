"""Shared API dependencies: database handle and auth."""

from typing import Annotated

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from pymongo.asynchronous.database import AsyncDatabase

from app.core import security
from app.core.database import get_database
from app.models.auth import Role
from app.schemas.auth import UserResponse
from app.services import auth as auth_service
from app.services.auth import UserNotFoundError

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/login")


def get_db() -> AsyncDatabase:
    return get_database()


Db = Annotated[AsyncDatabase, Depends(get_db)]
Token = Annotated[str, Depends(oauth2_scheme)]


async def get_current_user(db: Db, token: Token) -> UserResponse:
    try:
        payload = security.decode_token(token, security.ACCESS_TOKEN_TYPE)
        user = await auth_service.get_user_by_id(db, payload["sub"])
    except (security.TokenError, UserNotFoundError):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="could not validate credentials",
            headers={"WWW-Authenticate": "Bearer"},
        ) from None
    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="user is inactive",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user


CurrentUser = Annotated[UserResponse, Depends(get_current_user)]


def require_roles(*roles: Role):
    async def checker(user: CurrentUser) -> UserResponse:
        if user.role == Role.ADMIN or user.role in roles:
            return user
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="forbidden")

    return checker


def require_collector():
    """Operating a truck (collect/start/finish/claim/release/ping) is
    collector-only, with no admin bypass: admins and logistics monitor
    and manage through their own screens, never the cab."""

    async def checker(user: CurrentUser) -> UserResponse:
        if user.role == Role.COLLECTOR:
            return user
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="forbidden")

    return checker


def is_self_or_admin(user: UserResponse, user_id: str) -> bool:
    return user.role == Role.ADMIN or user.id == user_id
