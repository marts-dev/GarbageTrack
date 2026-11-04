"""Truck request/response schemas."""

from datetime import datetime

from pydantic import BaseModel, Field

from app.models.garbage import GarbageStatus, GarbageType
from app.models.geo import GeoLineString, GeoPoint
from app.models.truck import TruckAvailability
from app.schemas.logistics import FacilityResponse, PlannedRouteResponse


class TruckLocation(BaseModel):
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)


class TruckScheduleCreate(BaseModel):
    plate_number: str = Field(min_length=1)
    garbage_types: list[GarbageType] = Field(min_length=1)
    current_location: TruckLocation | None = None
    eta_minutes: int | None = Field(default=None, ge=0)
    capacity: int | None = Field(default=None, ge=1)


class TruckResponse(BaseModel):
    id: str
    plate_number: str
    availability: TruckAvailability
    garbage_types: list[GarbageType]
    current_location: GeoPoint | None
    eta_minutes: int | None
    capacity: int | None
    load: int
    load_by_type: dict[str, int] = {}
    operator_id: str | None = None
    created_at: datetime


class TruckUpdate(BaseModel):
    plate_number: str | None = Field(default=None, min_length=1)
    capacity: int | None = Field(default=None, ge=1)
    garbage_types: list[GarbageType] | None = Field(default=None, min_length=1)
    operator_id: str | None = None
    current_location: TruckLocation | None = None


class RouteStop(BaseModel):
    post_id: str
    location: GeoPoint
    types: list[GarbageType]
    status: GarbageStatus
    distance_meters: float | None


class CollectionRouteResponse(BaseModel):
    truck_id: str
    origin: GeoPoint
    remaining_capacity: int | None
    stops: list[RouteStop]
    geometry: GeoLineString | None = None
    geometry_source: str = "straight"


class TruckPlannedRouteResponse(PlannedRouteResponse):
    """A truck's assigned plan for operations roles.

    Embeds the depot facilities so collectors — who cannot list facilities —
    still see where the route ends. Stops whose posts were collected since
    planning are already filtered out; [total_stops] is the pre-filter
    count so collectors see run progress (collected = total - remaining).
    """

    depots: list[FacilityResponse] = Field(default_factory=list)
    total_stops: int = 0


class CollectVicinityRequest(BaseModel):
    longitude: float | None = Field(default=None, ge=-180, le=180)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    radius_meters: float = Field(default=30, gt=0)
    types: list[GarbageType] | None = None


class CollectVicinityResponse(BaseModel):
    truck_id: str
    collected_count: int
    post_ids: list[str]
    load: int
    load_by_type: dict[str, int] = {}
    capacity: int | None
    availability: TruckAvailability
