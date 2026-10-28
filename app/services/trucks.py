"""Collection truck service."""

from bson import ObjectId
from bson.errors import InvalidId
from pymongo.asynchronous.database import AsyncDatabase

from app.models import garbage as garbage_model
from app.models import truck as truck_model
from app.models.common import utcnow
from app.models.garbage import GarbageStatus
from app.models.geo import GeoPoint, geo_point
from app.models.truck import TruckAvailability, TruckStatus
from app.schemas.trucks import (
    CollectionRouteResponse,
    CollectVicinityRequest,
    CollectVicinityResponse,
    RouteStop,
    TruckResponse,
    TruckScheduleCreate,
)

EARTH_RADIUS_METERS = 6378100


class TruckNotFoundError(Exception):
    pass


class TruckLocationUnknownError(Exception):
    pass


def _to_response(doc: dict) -> TruckResponse:
    return TruckResponse(
        id=str(doc["_id"]),
        plate_number=doc["plate_number"],
        status=doc["status"],
        availability=doc.get("availability", TruckAvailability.AVAILABLE.value),
        garbage_types=doc["garbage_types"],
        current_location=doc.get("current_location"),
        eta_minutes=doc.get("eta_minutes"),
        capacity=doc.get("capacity"),
        load=doc.get("load", 0),
        created_at=doc["created_at"],
    )


async def _get_truck_doc(db: AsyncDatabase, truck_id: str) -> dict:
    try:
        object_id = ObjectId(truck_id)
    except InvalidId as exc:
        raise TruckNotFoundError(truck_id) from exc
    doc = await db[truck_model.COLLECTION].find_one({"_id": object_id})
    if doc is None:
        raise TruckNotFoundError(truck_id)
    return doc


def _resolve_origin(
    truck_doc: dict, longitude: float | None, latitude: float | None
) -> GeoPoint:
    if longitude is not None and latitude is not None:
        return geo_point(longitude, latitude)
    location = truck_doc.get("current_location")
    if location is None:
        raise TruckLocationUnknownError("truck has no known location; pass longitude/latitude")
    return GeoPoint.model_validate(location)


async def create_schedule(db: AsyncDatabase, payload: TruckScheduleCreate) -> TruckResponse:
    location = (
        geo_point(payload.current_location.longitude, payload.current_location.latitude)
        if payload.current_location is not None
        else None
    )
    doc = truck_model.TruckDocument(
        plate_number=payload.plate_number,
        status=payload.status,
        availability=payload.availability,
        garbage_types=payload.garbage_types,
        current_location=location,
        eta_minutes=payload.eta_minutes,
        capacity=payload.capacity,
    )
    stored = doc.model_dump(by_alias=True, exclude={"id"})
    result = await db[truck_model.COLLECTION].insert_one(stored)
    stored["_id"] = result.inserted_id
    return _to_response(stored)


async def get_truck(db: AsyncDatabase, truck_id: str) -> TruckResponse:
    return _to_response(await _get_truck_doc(db, truck_id))


async def list_enroute(
    db: AsyncDatabase,
    longitude: float | None = None,
    latitude: float | None = None,
    max_meters: float = 10000,
    limit: int = 50,
) -> list[TruckResponse]:
    query: dict = {"status": TruckStatus.ENROUTE.value}
    if longitude is not None and latitude is not None:
        query["current_location"] = {
            "$near": {
                "$geometry": {"type": "Point", "coordinates": [longitude, latitude]},
                "$maxDistance": max_meters,
            }
        }
    cursor = db[truck_model.COLLECTION].find(query).limit(limit)
    return [_to_response(doc) async for doc in cursor]


def _effective_types(truck_doc: dict, requested: list | None) -> list[str]:
    truck_types = [str(t) for t in truck_doc["garbage_types"]]
    if requested is None:
        return truck_types
    wanted = {str(t) for t in requested}
    return [t for t in truck_types if t in wanted]


async def get_collection_route(
    db: AsyncDatabase,
    truck_id: str,
    longitude: float | None = None,
    latitude: float | None = None,
    max_meters: float = 5000,
    limit: int = 20,
    types: list | None = None,
) -> CollectionRouteResponse:
    truck_doc = await _get_truck_doc(db, truck_id)
    origin = _resolve_origin(truck_doc, longitude, latitude)
    capacity = truck_doc.get("capacity")
    load = truck_doc.get("load", 0)
    remaining = capacity - load if capacity is not None else None
    effective_limit = min(limit, remaining) if remaining is not None else limit

    wanted_types = _effective_types(truck_doc, types)
    if effective_limit <= 0 or not wanted_types:
        return CollectionRouteResponse(
            truck_id=truck_id, origin=origin, remaining_capacity=remaining, stops=[]
        )

    pipeline = [
        {
            "$geoNear": {
                "near": {"type": "Point", "coordinates": [origin.longitude, origin.latitude]},
                "distanceField": "distance_meters",
                "maxDistance": max_meters,
                "spherical": True,
                "query": {
                    "status": {"$in": [GarbageStatus.POSTED.value, GarbageStatus.SCHEDULED.value]},
                    "types": {"$in": wanted_types},
                },
            }
        },
        {"$limit": effective_limit},
    ]
    cursor = await db[garbage_model.COLLECTION].aggregate(pipeline)
    stops = [
        RouteStop(
            post_id=str(doc["_id"]),
            location=doc["location"],
            types=doc["types"],
            status=doc["status"],
            distance_meters=doc.get("distance_meters"),
        )
        async for doc in cursor
    ]
    return CollectionRouteResponse(
        truck_id=truck_id, origin=origin, remaining_capacity=remaining, stops=stops
    )


async def collect_vicinity(
    db: AsyncDatabase, truck_id: str, payload: CollectVicinityRequest
) -> CollectVicinityResponse:
    truck_doc = await _get_truck_doc(db, truck_id)
    origin = _resolve_origin(truck_doc, payload.longitude, payload.latitude)
    wanted_types = _effective_types(truck_doc, payload.types)

    post_ids: list[str] = []
    if wanted_types:
        query = {
            "location": {
                "$geoWithin": {
                    "$centerSphere": [
                        [origin.longitude, origin.latitude],
                        payload.radius_meters / EARTH_RADIUS_METERS,
                    ]
                }
            },
            "status": {"$in": [GarbageStatus.POSTED.value, GarbageStatus.SCHEDULED.value]},
            "types": {"$in": wanted_types},
        }
        matches = db[garbage_model.COLLECTION].find(query)
        post_ids = [str(doc["_id"]) async for doc in matches]
        if post_ids:
            await db[garbage_model.COLLECTION].update_many(
                {
                    "_id": {"$in": [ObjectId(pid) for pid in post_ids]},
                    "status": {"$in": [GarbageStatus.POSTED.value, GarbageStatus.SCHEDULED.value]},
                },
                {
                    "$set": {
                        "status": GarbageStatus.COLLECTED.value,
                        "collected_at": utcnow(),
                    }
                },
            )

    capacity = truck_doc.get("capacity")
    load = truck_doc.get("load", 0) + len(post_ids)
    availability = truck_doc.get("availability", TruckAvailability.AVAILABLE.value)
    if capacity is not None and load >= capacity:
        availability = TruckAvailability.FULL.value
    await db[truck_model.COLLECTION].update_one(
        {"_id": truck_doc["_id"]}, {"$set": {"load": load, "availability": availability}}
    )
    return CollectVicinityResponse(
        truck_id=truck_id,
        collected_count=len(post_ids),
        post_ids=post_ids,
        load=load,
        capacity=capacity,
        availability=availability,
    )


async def set_availability(
    db: AsyncDatabase, truck_id: str, availability: TruckAvailability
) -> TruckResponse:
    truck_doc = await _get_truck_doc(db, truck_id)
    update: dict = {"availability": availability.value}
    if availability == TruckAvailability.AVAILABLE:
        update["load"] = 0
    await db[truck_model.COLLECTION].update_one({"_id": truck_doc["_id"]}, {"$set": update})
    truck_doc.update(update)
    return _to_response(truck_doc)
