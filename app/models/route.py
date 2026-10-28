"""Planned collection route documents assigned to trucks."""

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, Field

from app.models.common import MongoDocument, PyObjectId, utcnow
from app.models.garbage import GarbageType
from app.models.geo import GeoPoint

COLLECTION = "planned_routes"


class PlannedRouteStatus(StrEnum):
    ASSIGNED = "assigned"
    IN_PROGRESS = "in_progress"
    DONE = "done"
    CANCELLED = "cancelled"


class PlannedStop(BaseModel):
    post_id: PyObjectId
    location: GeoPoint
    types: list[GarbageType]
    distance_meters: float | None = None


class PlannedRouteDocument(MongoDocument):
    truck_id: PyObjectId
    name: str | None = None
    origin: GeoPoint
    stops: list[PlannedStop] = Field(min_length=1)
    status: PlannedRouteStatus = PlannedRouteStatus.ASSIGNED
    created_at: datetime = Field(default_factory=utcnow)
