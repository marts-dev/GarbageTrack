"""GeoJSON models for GPS locations."""

from typing import Literal

from pydantic import BaseModel, Field


class GeoPoint(BaseModel):
    """GeoJSON Point. Coordinates are [longitude, latitude]."""

    type: Literal["Point"] = "Point"
    coordinates: tuple[float, float] = Field(min_length=2, max_length=2)

    @property
    def longitude(self) -> float:
        return self.coordinates[0]

    @property
    def latitude(self) -> float:
        return self.coordinates[1]


class GeoLineString(BaseModel):
    """GeoJSON LineString. Coordinates are [[lon, lat], ...]."""

    type: Literal["LineString"] = "LineString"
    coordinates: list[tuple[float, float]] = Field(min_length=2)


def geo_point(longitude: float, latitude: float) -> GeoPoint:
    if not -180 <= longitude <= 180:
        raise ValueError("longitude must be between -180 and 180")
    if not -90 <= latitude <= 90:
        raise ValueError("latitude must be between -90 and 90")
    return GeoPoint(coordinates=(longitude, latitude))
