"""User documents and roles."""

from datetime import datetime
from enum import StrEnum

from pydantic import Field

from app.models.common import MongoDocument, utcnow

COLLECTION = "users"


class Role(StrEnum):
    RESIDENT = "resident"
    COLLECTOR = "collector"
    LOGISTICS = "logistics"
    ADMIN = "admin"


class UserDocument(MongoDocument):
    email: str
    hashed_password: str
    full_name: str | None = None
    role: Role
    is_active: bool = True
    created_at: datetime = Field(default_factory=utcnow)
