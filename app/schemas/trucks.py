"""Truck request/response schemas."""

from datetime import datetime

from pydantic import BaseModel, Field

from app.models.garbage import GarbageStatus, GarbageType
from app.models.geo import GeoLineString, GeoPoint
from app.models.truck import TruckAvailability, TruckStatus


class TruckLocation(BaseModel):
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)


class TruckScheduleCreate(BaseModel):
    plate_number: str = Field(min_length=1)
    garbage_types: list[GarbageType] = Field(min_length=1)
    status: TruckStatus = TruckStatus.SCHEDULED
    availability: TruckAvailability = TruckAvailability.AVAILABLE
    current_location: TruckLocation | None = None
    eta_minutes: int | None = Field(default=None, ge=0)
    capacity: int | None = Field(default=None, ge=1)


class TruckResponse(BaseModel):
    id: str
    plate_number: str
    status: TruckStatus
    availability: TruckAvailability
    garbage_types: list[GarbageType]
    current_location: GeoPoint | None
    eta_minutes: int | None
    capacity: int | None
    load: int
    operator_id: str | None = None
    created_at: datetime


class TruckUpdate(BaseModel):
    plate_number: str | None = Field(default=None, min_length=1)
    capacity: int | None = Field(default=None, ge=1)
    garbage_types: list[GarbageType] | None = Field(default=None, min_length=1)
    status: TruckStatus | None = None
    operator_id: str | None = None
    current_location: TruckLocation | None = None


class AvailabilityUpdate(BaseModel):
    availability: TruckAvailability


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


class CollectVicinityRequest(BaseModel):
    longitude: float | None = Field(default=None, ge=-180, le=180)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    radius_meters: float = Field(default=500, gt=0)
    types: list[GarbageType] | None = None


class CollectVicinityResponse(BaseModel):
    truck_id: str
    collected_count: int
    post_ids: list[str]
    load: int
    capacity: int | None
    availability: TruckAvailability
