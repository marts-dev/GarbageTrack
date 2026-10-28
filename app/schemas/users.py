"""User location request/response schemas."""

from datetime import datetime

from pydantic import BaseModel, Field

from app.models.geo import GeoPoint


class LocationSaveRequest(BaseModel):
    longitude: float = Field(ge=-180, le=180)
    latitude: float = Field(ge=-90, le=90)


class UserLocationResponse(BaseModel):
    user_id: str
    location: GeoPoint
    updated_at: datetime
