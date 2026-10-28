"""Waste facility documents (dump sites, recycling, management centers)."""

from datetime import datetime
from enum import StrEnum

from pydantic import Field

from app.models.common import MongoDocument, utcnow
from app.models.garbage import GarbageType
from app.models.geo import GeoPoint

COLLECTION = "facilities"


class FacilityKind(StrEnum):
    DUMP_SITE = "dump_site"
    RECYCLING = "recycling"
    WASTE_CENTER = "waste_center"


class FacilityDocument(MongoDocument):
    name: str
    kind: FacilityKind
    location: GeoPoint
    accepted_types: list[GarbageType] = Field(min_length=1)
    address: str | None = None
    created_at: datetime = Field(default_factory=utcnow)
    updated_at: datetime = Field(default_factory=utcnow)
