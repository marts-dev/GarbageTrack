"""Garbage post request/response schemas."""

from datetime import date, datetime

from pydantic import BaseModel, Field

from app.models.garbage import GarbageStatus, GarbageType
from app.models.geo import GeoPoint
from app.models.route import PlannedRouteStatus
from app.schemas.common import ImagePayload


class GarbagePostCreate(ImagePayload):
    user_id: str = Field(min_length=1)
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)
    types: list[GarbageType] = Field(min_length=1)
    description: str | None = Field(default=None, max_length=2000)
    district: str | None = Field(default=None, max_length=120)
    training_consent: bool = False


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
    training_consent: bool
    status: GarbageStatus
    created_at: datetime
    collected_at: datetime | None

    @classmethod
    def from_doc(cls, doc: dict) -> "GarbagePostResponse":
        """Build from a stored post document. The single mapper every
        service uses, so new fields only ever land in one place."""
        return cls(
            id=str(doc["_id"]),
            user_id=doc["user_id"],
            location=doc["location"],
            types=doc["types"],
            description=doc.get("description"),
            district=doc.get("district"),
            country=doc.get("country"),
            has_image=doc.get("image_base64") is not None,
            image_content_type=doc.get("image_content_type"),
            training_consent=bool(doc.get("training_consent", False)),
            status=doc["status"],
            created_at=doc["created_at"],
            collected_at=doc.get("collected_at"),
        )


class CollectionAssignmentResponse(BaseModel):
    truck_id: str
    plate_number: str
    route_id: str
    route_name: str | None
    route_status: PlannedRouteStatus
    scheduled_for: date


class ScheduledPickupResponse(BaseModel):
    """One of the caller's posts on an active (assigned/in_progress) route."""

    post_id: str
    types: list[GarbageType]
    status: GarbageStatus
    district: str | None
    route_id: str
    route_name: str | None
    route_status: PlannedRouteStatus
    scheduled_for: date
    plate_number: str
