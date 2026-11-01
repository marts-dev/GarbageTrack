"""Collection truck documents."""

from datetime import datetime
from enum import StrEnum

from pydantic import Field

from app.models.common import MongoDocument, utcnow
from app.models.garbage import GarbageType
from app.models.geo import GeoPoint

COLLECTION = "trucks"


class TruckStatus(StrEnum):
    SCHEDULED = "scheduled"
    ENROUTE = "enroute"
    DONE = "done"


class TruckAvailability(StrEnum):
    AVAILABLE = "available"
    WORKING = "working"
    FULL = "full"


class TruckDocument(MongoDocument):
    plate_number: str
    status: TruckStatus = TruckStatus.SCHEDULED
    availability: TruckAvailability = TruckAvailability.AVAILABLE
    garbage_types: list[GarbageType] = Field(min_length=1)
    current_location: GeoPoint | None = None
    eta_minutes: int | None = Field(default=None, ge=0)
    capacity: int | None = Field(default=None, ge=1)
    load: int = Field(default=0, ge=0)
    operator_id: str | None = None
    created_at: datetime = Field(default_factory=utcnow)
