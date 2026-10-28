"""User location service."""

from pymongo.asynchronous.database import AsyncDatabase

from app.models import user as user_model
from app.models.geo import geo_point
from app.schemas.users import UserLocationResponse


class LocationNotFoundError(Exception):
    pass


def _to_response(doc: dict) -> UserLocationResponse:
    return UserLocationResponse(
        user_id=doc["user_id"],
        location=doc["location"],
        updated_at=doc["updated_at"],
    )


async def save_location(db: AsyncDatabase, user_id: str, longitude: float, latitude: float) -> UserLocationResponse:
    doc = user_model.UserLocationDocument(user_id=user_id, location=geo_point(longitude, latitude))
    payload = doc.model_dump(by_alias=True, exclude={"id"})
    await db[user_model.COLLECTION].update_one({"user_id": user_id}, {"$set": payload}, upsert=True)
    stored = await db[user_model.COLLECTION].find_one({"user_id": user_id})
    assert stored is not None
    return _to_response(stored)


async def get_location(db: AsyncDatabase, user_id: str) -> UserLocationResponse:
    stored = await db[user_model.COLLECTION].find_one({"user_id": user_id})
    if stored is None:
        raise LocationNotFoundError(user_id)
    return _to_response(stored)
