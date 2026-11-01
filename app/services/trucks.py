"""Collection truck service."""

from bson import ObjectId
from bson.errors import InvalidId
from pymongo.asynchronous.database import AsyncDatabase

from app.models import garbage as garbage_model
from app.models import route as route_model
from app.models import truck as truck_model
from app.models.auth import Role
from app.models.common import utcnow
from app.models.garbage import GarbageStatus
from app.models.geo import GeoLineString, GeoPoint, geo_point
from app.models.truck import TruckAvailability, TruckStatus
from app.schemas.trucks import (
    CollectionRouteResponse,
    CollectVicinityRequest,
    CollectVicinityResponse,
    RouteStop,
    TruckResponse,
    TruckScheduleCreate,
    TruckUpdate,
)
from app.services import auth as auth_service
from app.services import routing as routing_service
from app.services.auth import UserNotFoundError

EARTH_RADIUS_METERS = 6378100


class TruckNotFoundError(Exception):
    pass


class TruckLocationUnknownError(Exception):
    pass


class TruckNotAssignedError(Exception):
    pass


class TruckOperatorConflictError(Exception):
    pass


class TruckOperatorNotFoundError(Exception):
    pass


class TruckOperatorInvalidError(Exception):
    pass


class TruckHasRoutesError(Exception):
    pass


class EmptyUpdateError(Exception):
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
        operator_id=doc.get("operator_id"),
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


def resolve_origin(
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


def _route_geometry_for_stops(
    origin: GeoPoint, stop_locations: list[GeoPoint]
) -> tuple[GeoLineString | None, str]:
    if not stop_locations:
        return None, "straight"
    points = [(origin.longitude, origin.latitude)] + [
        (loc.longitude, loc.latitude) for loc in stop_locations
    ]
    geom = routing_service.route_points(points)
    source = "straight" if geom.fallback else "road"
    if len(geom.points) < 2:
        return None, source
    return GeoLineString(coordinates=geom.points), source


def _require_operator_binding(truck_doc: dict, user: object | None) -> None:
    if user is None:
        return
    role = getattr(user, "role", None)
    if role != Role.COLLECTOR and str(role) != Role.COLLECTOR.value:
        return
    user_id = str(getattr(user, "id", ""))
    if truck_doc.get("operator_id") != user_id:
        raise TruckNotAssignedError("truck is not assigned to you")


async def list_trucks(
    db: AsyncDatabase,
    status: TruckStatus | None = None,
    availability: TruckAvailability | None = None,
    limit: int = 50,
) -> list[TruckResponse]:
    query: dict = {}
    if status is not None:
        query["status"] = status.value
    if availability is not None:
        query["availability"] = availability.value
    cursor = db[truck_model.COLLECTION].find(query).limit(limit)
    return [_to_response(doc) async for doc in cursor]


async def update_truck(
    db: AsyncDatabase, truck_id: str, payload: TruckUpdate
) -> TruckResponse:
    truck_doc = await _get_truck_doc(db, truck_id)
    changes = payload.model_dump(exclude_unset=True)
    if "operator_id" in changes and changes["operator_id"] is not None:
        operator_id = changes["operator_id"]
        try:
            ObjectId(operator_id)
        except InvalidId as exc:
            raise TruckOperatorInvalidError(f"invalid operator id: {operator_id}") from exc
        try:
            operator = await auth_service.get_user_by_id(db, operator_id)
        except UserNotFoundError as exc:
            raise TruckOperatorNotFoundError(operator_id) from exc
        if operator.role != Role.COLLECTOR:
            raise TruckOperatorInvalidError("operator must be a collector user")
        async for other in db[truck_model.COLLECTION].find({"operator_id": operator_id}):
            if str(other["_id"]) != str(truck_doc["_id"]):
                raise TruckOperatorConflictError("collector already assigned to another truck")
    if not changes:
        raise EmptyUpdateError("no fields to update")
    stored = await db[truck_model.COLLECTION].find_one_and_update(
        {"_id": truck_doc["_id"]}, {"$set": changes}
    )
    if stored is None:
        raise TruckNotFoundError(truck_id)
    stored.update(changes)
    return _to_response(stored)


async def delete_truck(db: AsyncDatabase, truck_id: str) -> None:
    truck_doc = await _get_truck_doc(db, truck_id)
    existing = await db[route_model.COLLECTION].find_one({"truck_id": truck_doc["_id"]})
    if existing is not None:
        raise TruckHasRoutesError("truck has assigned routes")
    result = await db[truck_model.COLLECTION].delete_one({"_id": truck_doc["_id"]})
    if result.deleted_count == 0:
        raise TruckNotFoundError(truck_id)


async def get_collection_route(
    db: AsyncDatabase,
    truck_id: str,
    longitude: float | None = None,
    latitude: float | None = None,
    max_meters: float = 5000,
    limit: int = 20,
    types: list | None = None,
    district: str | None = None,
    country: str | None = None,
) -> CollectionRouteResponse:
    truck_doc = await _get_truck_doc(db, truck_id)
    origin = resolve_origin(truck_doc, longitude, latitude)
    capacity = truck_doc.get("capacity")
    load = truck_doc.get("load", 0)
    remaining = capacity - load if capacity is not None else None
    effective_limit = min(limit, remaining) if remaining is not None else limit

    wanted_types = _effective_types(truck_doc, types)
    if effective_limit <= 0 or not wanted_types:
        return CollectionRouteResponse(
            truck_id=truck_id,
            origin=origin,
            remaining_capacity=remaining,
            stops=[],
            geometry=None,
            geometry_source="straight",
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
                    **({"district": district} if district is not None else {}),
                    **({"country": country} if country is not None else {}),
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
    geometry, geometry_source = _route_geometry_for_stops(
        origin, [stop.location for stop in stops]
    )
    return CollectionRouteResponse(
        truck_id=truck_id,
        origin=origin,
        remaining_capacity=remaining,
        stops=stops,
        geometry=geometry,
        geometry_source=geometry_source,
    )


async def collect_vicinity(
    db: AsyncDatabase,
    truck_id: str,
    payload: CollectVicinityRequest,
    user: object | None = None,
) -> CollectVicinityResponse:
    truck_doc = await _get_truck_doc(db, truck_id)
    _require_operator_binding(truck_doc, user)
    origin = resolve_origin(truck_doc, payload.longitude, payload.latitude)
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
    db: AsyncDatabase,
    truck_id: str,
    availability: TruckAvailability,
    user: object | None = None,
) -> TruckResponse:
    truck_doc = await _get_truck_doc(db, truck_id)
    _require_operator_binding(truck_doc, user)
    update: dict = {"availability": availability.value}
    if availability == TruckAvailability.AVAILABLE:
        update["load"] = 0
    await db[truck_model.COLLECTION].update_one({"_id": truck_doc["_id"]}, {"$set": update})
    truck_doc.update(update)
    return _to_response(truck_doc)
