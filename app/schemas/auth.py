"""Auth request/response schemas."""

from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, EmailStr, Field, StringConstraints

from app.models.auth import Role

CountryName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=72)
    full_name: str | None = None
    role: Role = Role.RESIDENT
    country: CountryName


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=1)


class UserResponse(BaseModel):
    id: str
    email: str
    full_name: str | None
    role: Role
    country: str | None
    is_active: bool
    depot_id: str | None = None
    created_at: datetime


class RoleUpdateRequest(BaseModel):
    role: Role


class DepotUpdateRequest(BaseModel):
    depot_id: str | None = None


class ActiveUpdateRequest(BaseModel):
    is_active: bool


class ProfileUpdateRequest(BaseModel):
    full_name: str = Field(min_length=1, max_length=100)
    country: CountryName | None = None
