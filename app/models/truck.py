"""Collection truck documents."""

from datetime import datetime
from enum import StrEnum

from pydantic import Field

from app.models.common import MongoDocument, utcnow
from app.models.garbage import GarbageType
from app.models.geo import GeoPoint

COLLECTION = "trucks"


class TruckAvailability(StrEnum):
    """Assignability mirror: free for a route, or committed to one.

    Process-owned (route assign/close flips it); fullness is derived from
    load vs capacity wherever displayed, never stored.
    """

    AVAILABLE = "available"
    WORKING = "working"


class TruckDocument(MongoDocument):
    plate_number: str
    availability: TruckAvailability = TruckAvailability.AVAILABLE
    garbage_types: list[GarbageType] = Field(min_length=1)
    current_location: GeoPoint | None = None
    eta_minutes: int | None = Field(default=None, ge=0)
    capacity: int | None = Field(default=None, ge=1)
    load: int = Field(default=0, ge=0)
    load_by_type: dict[str, int] = Field(default_factory=dict)
    operator_id: str | None = None
    created_at: datetime = Field(default_factory=utcnow)
