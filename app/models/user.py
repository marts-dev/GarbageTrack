"""User location document."""

from datetime import datetime

from pydantic import Field

from app.models.common import MongoDocument, utcnow
from app.models.geo import GeoPoint

COLLECTION = "user_locations"


class UserLocationDocument(MongoDocument):
    user_id: str
    location: GeoPoint
    updated_at: datetime = Field(default_factory=utcnow)
