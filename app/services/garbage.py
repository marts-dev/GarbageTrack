"""Garbage post service."""

from bson import ObjectId
from bson.errors import InvalidId
from pymongo import ReturnDocument
from pymongo.asynchronous.database import AsyncDatabase

from app.models import garbage as garbage_model
from app.models import route as route_model
from app.models import truck as truck_model
from app.models.common import utcnow
from app.models.garbage import GarbageStatus
from app.models.geo import geo_point
from app.models.route import PlannedRouteStatus
from app.models.truck import TruckAvailability
from app.schemas.garbage import (
    CollectionAssignmentResponse,
    GarbagePostCreate,
    GarbagePostResponse,
)


class GarbagePostNotFoundError(Exception):
    pass


class GarbageAlreadyCollectedError(Exception):
    pass


class GarbageNothingToConfirmError(Exception):
    pass


class GarbageNotPendingError(Exception):
    pass


class NoCollectionAssignmentError(Exception):
    pass


def _to_response(doc: dict) -> GarbagePostResponse:
    return GarbagePostResponse(
        id=str(doc["_id"]),
        user_id=doc["user_id"],
        location=doc["location"],
        types=doc["types"],
        description=doc.get("description"),
        district=doc.get("district"),
        country=doc.get("country"),
        has_image=doc.get("image_base64") is not None,
        image_content_type=doc.get("image_content_type"),
        status=doc["status"],
        created_at=doc["created_at"],
        collected_at=doc.get("collected_at"),
    )


def _near_filter(longitude: float, latitude: float, max_meters: float) -> dict:
    return {
        "location": {
            "$near": {
                "$geometry": {"type": "Point", "coordinates": [longitude, latitude]},
                "$maxDistance": max_meters,
            }
        }
    }


async def create_post(
    db: AsyncDatabase, payload: GarbagePostCreate, country: str | None = None
) -> GarbagePostResponse:
    doc = garbage_model.GarbagePostDocument(
        user_id=payload.user_id,
        location=geo_point(payload.longitude, payload.latitude),
        types=payload.types,
        description=payload.description,
        district=payload.district,
        country=country,
        image_base64=payload.image_base64,
        image_content_type=payload.image_content_type,
    )
    stored = doc.model_dump(by_alias=True, exclude={"id"})
    result = await db[garbage_model.COLLECTION].insert_one(stored)
    stored["_id"] = result.inserted_id
    return _to_response(stored)


async def get_post(db: AsyncDatabase, post_id: str) -> GarbagePostResponse:
    try:
        object_id = ObjectId(post_id)
    except InvalidId as exc:
        raise GarbagePostNotFoundError(post_id) from exc
    stored = await db[garbage_model.COLLECTION].find_one({"_id": object_id})
    if stored is None:
        raise GarbagePostNotFoundError(post_id)
    return _to_response(stored)


async def list_posts(
    db: AsyncDatabase,
    user_id: str | None = None,
    status: GarbageStatus | None = None,
    longitude: float | None = None,
    latitude: float | None = None,
    max_meters: float = 5000,
    limit: int = 50,
    district: str | None = None,
    country: str | None = None,
) -> list[GarbagePostResponse]:
    query: dict = {}
    if user_id is not None:
        query["user_id"] = user_id
    if status is not None:
        query["status"] = status.value
    if district is not None:
        query["district"] = district
    if country is not None:
        query["country"] = country
    if longitude is not None and latitude is not None:
        query.update(_near_filter(longitude, latitude, max_meters))
    cursor = db[garbage_model.COLLECTION].find(query).limit(limit)
    return [_to_response(doc) async for doc in cursor]


async def confirm_collected(db: AsyncDatabase, post_id: str) -> GarbagePostResponse:
    """Confirm a pending pickup: only ``pending_confirmation`` → ``collected``.

    Raises [GarbageNothingToConfirmError] when the post is still
    posted/scheduled (the collector has not marked it yet) and
    [GarbageAlreadyCollectedError] when it is already collected.
    """
    try:
        object_id = ObjectId(post_id)
    except InvalidId as exc:
        raise GarbagePostNotFoundError(post_id) from exc
    stored = await db[garbage_model.COLLECTION].find_one_and_update(
        {"_id": object_id, "status": GarbageStatus.PENDING_CONFIRMATION.value},
        {"$set": {"status": GarbageStatus.COLLECTED.value, "collected_at": utcnow()}},
        return_document=ReturnDocument.AFTER,
    )
    if stored is not None:
        return _to_response(stored)
    existing = await db[garbage_model.COLLECTION].find_one({"_id": object_id})
    if existing is None:
        raise GarbagePostNotFoundError(post_id)
    if str(existing["status"]) == GarbageStatus.COLLECTED.value:
        raise GarbageAlreadyCollectedError(post_id)
    raise GarbageNothingToConfirmError(post_id)


async def dispute_collected(db: AsyncDatabase, post_id: str) -> GarbagePostResponse:
    """Reopen a pending pickup: ``pending_confirmation`` → ``posted``.

    Clears ``collected_at`` and returns one unit to the collecting truck's
    load (floored at zero); raises [GarbageNotPendingError] when the post
    is not pending confirmation.
    """
    try:
        object_id = ObjectId(post_id)
    except InvalidId as exc:
        raise GarbagePostNotFoundError(post_id) from exc
    stored = await db[garbage_model.COLLECTION].find_one_and_update(
        {"_id": object_id, "status": GarbageStatus.PENDING_CONFIRMATION.value},
        {
            "$set": {"status": GarbageStatus.POSTED.value},
            "$unset": {"collected_at": ""},
        },
        return_document=ReturnDocument.AFTER,
    )
    if stored is not None:
        await _return_load_to_truck(
            db,
            stored.get("collected_by_truck_id"),
            [str(t) for t in stored.get("types", [])],
        )
        return _to_response(stored)
    existing = await db[garbage_model.COLLECTION].find_one({"_id": object_id})
    if existing is None:
        raise GarbagePostNotFoundError(post_id)
    raise GarbageNotPendingError(post_id)


async def _return_load_to_truck(
    db: AsyncDatabase, truck_id: object | None, types: list[str]
) -> None:
    """Return a disputed post's type entries to the truck (floored at zero).

    Legacy pending posts without an attribution stamp are skipped. A truck
    that drops back under capacity leaves the full state.
    """
    if truck_id is None:
        return
    truck_doc = await db[truck_model.COLLECTION].find_one({"_id": truck_id})
    if truck_doc is None:
        return
    load_by_type = {
        str(k): int(v) for k, v in truck_doc.get("load_by_type", {}).items()
    }
    for name in types:
        load_by_type[name] = max(0, load_by_type.get(name, 0) - 1)
    new_load = sum(load_by_type.values())
    update: dict = {"load": new_load, "load_by_type": load_by_type}
    capacity = truck_doc.get("capacity")
    if (
        truck_doc.get("availability") == TruckAvailability.FULL.value
        and capacity is not None
        and new_load < capacity
    ):
        update["availability"] = TruckAvailability.WORKING.value
    await db[truck_model.COLLECTION].update_one({"_id": truck_id}, {"$set": update})


async def get_collection_assignment(
    db: AsyncDatabase, post_id: str
) -> CollectionAssignmentResponse:
    """Attribute a post to its most recent relevant planned route + truck.

    Considers routes containing the post with status assigned/in_progress/done
    (done still attributes the pickup; cancelled is excluded). Raises
    [NoCollectionAssignmentError] when the post is on no relevant route.
    """
    try:
        object_id = ObjectId(post_id)
    except InvalidId as exc:
        raise GarbagePostNotFoundError(post_id) from exc
    existing = await db[garbage_model.COLLECTION].find_one({"_id": object_id})
    if existing is None:
        raise GarbagePostNotFoundError(post_id)
    candidates = []
    async for doc in db[route_model.COLLECTION].find(
        {
            "status": {
                "$in": [
                    PlannedRouteStatus.ASSIGNED.value,
                    PlannedRouteStatus.IN_PROGRESS.value,
                    PlannedRouteStatus.DONE.value,
                ]
            }
        }
    ):
        if any(stop.get("post_id") == object_id for stop in doc.get("stops", [])):
            candidates.append(doc)
    if not candidates:
        raise NoCollectionAssignmentError(post_id)
    route_doc = max(candidates, key=lambda d: d.get("created_at"))
    truck_doc = await db[truck_model.COLLECTION].find_one({"_id": route_doc["truck_id"]})
    if truck_doc is None:
        raise NoCollectionAssignmentError(post_id)
    return CollectionAssignmentResponse(
        truck_id=str(truck_doc["_id"]),
        plate_number=truck_doc["plate_number"],
        truck_status=truck_doc["status"],
        route_id=str(route_doc["_id"]),
        route_name=route_doc.get("name"),
        route_status=route_doc["status"],
    )
