from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.security import OAuth2PasswordRequestForm

from app.api.deps import CurrentUser, Db, require_roles
from app.core import security
from app.models.auth import Role
from app.schemas.auth import (
    ProfileUpdateRequest,
    RefreshRequest,
    RegisterRequest,
    RoleUpdateRequest,
    TokenResponse,
    UserResponse,
)
from app.services import auth as auth_service
from app.services.auth import InvalidCredentialsError, UserExistsError, UserNotFoundError

router = APIRouter(prefix="/auth", tags=["auth"])

Admin = Annotated[UserResponse, Depends(require_roles(Role.ADMIN))]
Dispatcher = Annotated[UserResponse, Depends(require_roles(Role.LOGISTICS))]

PUBLIC_ROLES = {Role.RESIDENT, Role.COLLECTOR, Role.LOGISTICS}


@router.post("/register", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
async def register(payload: RegisterRequest, db: Db):
    if payload.role not in PUBLIC_ROLES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="admin role cannot be self-granted; ask an administrator",
        )
    try:
        return await auth_service.create_user(
            db, payload.email, payload.password, payload.role, payload.full_name, payload.country
        )
    except UserExistsError:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="email already registered"
        ) from None


@router.post("/login", response_model=TokenResponse)
async def login(form: Annotated[OAuth2PasswordRequestForm, Depends()], db: Db):
    try:
        user = await auth_service.authenticate_user(db, form.username, form.password)
    except InvalidCredentialsError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        ) from None
    return TokenResponse(
        access_token=security.create_access_token(user.id),
        refresh_token=security.create_refresh_token(user.id),
    )


@router.post("/refresh", response_model=TokenResponse)
async def refresh(payload: RefreshRequest, db: Db):
    try:
        decoded = security.decode_token(payload.refresh_token, security.REFRESH_TOKEN_TYPE)
        user = await auth_service.get_user_by_id(db, decoded["sub"])
    except (security.TokenError, UserNotFoundError):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid refresh token"
        ) from None
    if not user.is_active:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="user is inactive")
    return TokenResponse(
        access_token=security.create_access_token(user.id),
        refresh_token=security.create_refresh_token(user.id),
    )


@router.get("/me", response_model=UserResponse)
async def read_me(user: CurrentUser):
    return user


@router.patch("/me", response_model=UserResponse)
async def update_me(payload: ProfileUpdateRequest, user: CurrentUser, db: Db):
    try:
        return await auth_service.update_profile(db, user.id, payload.full_name, payload.country)
    except UserNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user not found") from None


@router.get("/users", response_model=list[UserResponse])
async def list_users(
    user: Dispatcher,
    db: Db,
    limit: Annotated[int, Query(ge=1, le=200)] = 100,
    role: Role | None = None,
):
    _ = user
    return await auth_service.list_users(db, limit, role)


@router.patch("/users/{user_id}/role", response_model=UserResponse)
async def update_role(user_id: str, payload: RoleUpdateRequest, user: Admin, db: Db):
    _ = user
    try:
        return await auth_service.update_user_role(db, user_id, payload.role)
    except UserNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user not found") from None
