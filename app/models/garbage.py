"""Garbage post documents."""

from datetime import datetime
from enum import StrEnum

from pydantic import Field

from app.models.common import MongoDocument, utcnow
from app.models.geo import GeoPoint

COLLECTION = "garbage_posts"


class GarbageType(StrEnum):
    PLASTIC = "plastic"
    ORGANIC = "organic"
    PAPER = "paper"
    GLASS = "glass"
    METAL = "metal"
    ELECTRONIC = "electronic"
    HAZARDOUS = "hazardous"
    TEXTILE = "textile"
    GENERAL = "general"


class GarbageStatus(StrEnum):
    POSTED = "posted"
    SCHEDULED = "scheduled"
    PENDING_CONFIRMATION = "pending_confirmation"
    COLLECTED = "collected"


class GarbagePostDocument(MongoDocument):
    user_id: str
    location: GeoPoint
    types: list[GarbageType] = Field(min_length=1)
    description: str | None = None
    district: str | None = None
    country: str | None = None
    image_base64: str | None = None
    image_content_type: str | None = None
    status: GarbageStatus = GarbageStatus.POSTED
    created_at: datetime = Field(default_factory=utcnow)
    collected_at: datetime | None = None
