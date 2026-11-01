"""Garbage post request/response schemas."""

from datetime import datetime

from pydantic import BaseModel, Field

from app.models.garbage import GarbageStatus, GarbageType
from app.models.geo import GeoPoint
from app.schemas.common import ImagePayload


class GarbagePostCreate(ImagePayload):
    user_id: str = Field(min_length=1)
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)
    types: list[GarbageType] = Field(min_length=1)
    description: str | None = Field(default=None, max_length=2000)
    district: str | None = Field(default=None, max_length=120)


class GarbagePostResponse(BaseModel):
    id: str
    user_id: str
    location: GeoPoint
    types: list[GarbageType]
    description: str | None
    district: str | None
    country: str | None
    has_image: bool
    image_content_type: str | None
    status: GarbageStatus
    created_at: datetime
    collected_at: datetime | None
