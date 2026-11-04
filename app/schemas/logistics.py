"""Logistics request/response schemas."""

from datetime import date, datetime

from pydantic import BaseModel, Field

from app.models.facility import FacilityKind
from app.models.garbage import GarbageType
from app.models.geo import GeoLineString, GeoPoint
from app.models.route import PlannedRouteStatus
from app.models.truck import TruckAvailability


class FacilityLocation(BaseModel):
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)


class FacilityCreate(BaseModel):
    name: str = Field(min_length=1)
    kind: FacilityKind
    location: FacilityLocation
    accepted_types: list[GarbageType] = Field(min_length=1)
    address: str | None = None


class FacilityUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1)
    kind: FacilityKind | None = None
    location: FacilityLocation | None = None
    accepted_types: list[GarbageType] | None = Field(default=None, min_length=1)
    address: str | None = None


class FacilityResponse(BaseModel):
    id: str
    name: str
    kind: FacilityKind
    location: GeoPoint
    accepted_types: list[GarbageType]
    address: str | None
    created_at: datetime
    updated_at: datetime


class TruckLocationResponse(BaseModel):
    truck_id: str
    plate_number: str
    availability: TruckAvailability
    current_location: GeoPoint | None
    load: int
    capacity: int | None
    operator_id: str | None = None


class RegionSummaryResponse(BaseModel):
    total: int
    by_status: dict[str, int]
    by_type: dict[str, int]


class GarbageSummaryResponse(BaseModel):
    total: int
    by_status: dict[str, int]
    by_type: dict[str, int]
    by_region: dict[str, RegionSummaryResponse] = Field(default_factory=dict)


class PlannedRouteCreate(BaseModel):
    truck_id: str = Field(min_length=1)
    name: str | None = None
    post_ids: list[str] | None = Field(default=None, min_length=1)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    max_meters: float = Field(default=5000, gt=0)
    limit: int = Field(default=20, ge=1, le=100)
    types: list[GarbageType] | None = None
    depot_ids: list[str] = Field(min_length=1)
    collection_points: list[FacilityLocation] | None = Field(default=None, max_length=100)
    district: str | None = None
    country: str | None = None
    # Calendar day of the run; omitted means today so every route is visible.
    scheduled_for: date | None = None


class PlannedStopResponse(BaseModel):
    post_id: str
    location: GeoPoint
    types: list[GarbageType]
    distance_meters: float | None


class PlannedRouteResponse(BaseModel):
    id: str
    truck_id: str
    name: str | None
    origin: GeoPoint
    stops: list[PlannedStopResponse]
    status: PlannedRouteStatus
    scheduled_for: date
    created_at: datetime
    depot_ids: list[str] = Field(default_factory=list)
    collection_points: list[GeoPoint] = Field(default_factory=list)
    geometry: GeoLineString | None = None
    geometry_source: str = "straight"
