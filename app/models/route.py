"""Planned collection route documents assigned to trucks."""

from datetime import date, datetime
from enum import StrEnum

from pydantic import BaseModel, Field

from app.models.common import MongoDocument, PyObjectId, utcnow
from app.models.garbage import GarbageType
from app.models.geo import GeoLineString, GeoPoint

COLLECTION = "planned_routes"


class PlannedRouteStatus(StrEnum):
    ASSIGNED = "assigned"
    IN_PROGRESS = "in_progress"
    DONE = "done"
    CANCELLED = "cancelled"


def scheduled_day(route_doc: dict) -> date:
    """The calendar day a route collects on.

    Stored as an ISO YYYY-MM-DD string (a day, not an instant, so it never
    shifts across timezones). Legacy routes without the field fall back to
    their creation day so every route lands on the calendar.
    """
    raw = route_doc.get("scheduled_for")
    if raw:
        return date.fromisoformat(str(raw))
    created = route_doc.get("created_at")
    if isinstance(created, datetime):
        return created.date()
    return utcnow().date()


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
    depot_ids: list[PyObjectId] = Field(min_length=1)
    collection_points: list[GeoPoint] = Field(default_factory=list)
    status: PlannedRouteStatus = PlannedRouteStatus.ASSIGNED
    # ISO calendar day (YYYY-MM-DD); a string so Mongo stores it natively.
    scheduled_for: str | None = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    geometry: GeoLineString | None = None
    geometry_source: str = "straight"
    created_at: datetime = Field(default_factory=utcnow)
