"""Auth request/response schemas."""

from datetime import datetime

from pydantic import BaseModel, EmailStr, Field

from app.models.auth import Role


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=72)
    full_name: str | None = None
    role: Role = Role.RESIDENT


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
    is_active: bool
    created_at: datetime


class RoleUpdateRequest(BaseModel):
    role: Role


class ProfileUpdateRequest(BaseModel):
    full_name: str = Field(min_length=1, max_length=100)
