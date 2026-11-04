"""Collection truck service."""

from bson import ObjectId
from bson.errors import InvalidId
from pymongo.asynchronous.database import AsyncDatabase

from app.models import facility as facility_model
from app.models import garbage as garbage_model
from app.models import route as route_model
from app.models import truck as truck_model
from app.models.auth import Role
from app.models.common import utcnow
from app.models.garbage import GarbageStatus
from app.models.geo import GeoLineString, GeoPoint, geo_point
from app.models.route import PlannedRouteStatus
from app.models.truck import TruckAvailability
from app.schemas.garbage import GarbagePostResponse
from app.schemas.logistics import FacilityResponse, PlannedStopResponse
from app.schemas.trucks import (
    CollectionRouteResponse,
    CollectVicinityRequest,
    CollectVicinityResponse,
    RouteStop,
    TruckLocation,
    TruckPlannedRouteResponse,
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


class NoPlannedRouteError(Exception):
    pass


class NoActiveRouteError(Exception):
    pass


class EmptyUpdateError(Exception):
    pass


def _to_response(doc: dict) -> TruckResponse:
    return TruckResponse(
        id=str(doc["_id"]),
        plate_number=doc["plate_number"],
        availability=doc.get("availability", TruckAvailability.AVAILABLE.value),
        garbage_types=doc["garbage_types"],
        current_location=doc.get("current_location"),
        eta_minutes=doc.get("eta_minutes"),
        capacity=doc.get("capacity"),
        load=doc.get("load", 0),
        load_by_type={str(k): int(v) for k, v in doc.get("load_by_type", {}).items()},
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
        availability=TruckAvailability.AVAILABLE,
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
    """Trucks on live runs: ones with an in-progress route.

    Run state lives on the route now; this joins it back to trucks so the
    live map keeps working without a truck status flag.
    """
    active_ids = {
        doc["truck_id"]
        async for doc in db[route_model.COLLECTION].find(
            {"status": PlannedRouteStatus.IN_PROGRESS.value}
        )
    }
    if not active_ids:
        return []
    query: dict = {"_id": {"$in": list(active_ids)}}
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
    availability: TruckAvailability | None = None,
    limit: int = 50,
) -> list[TruckResponse]:
    query: dict = {}
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
    if "current_location" in changes and changes["current_location"] is not None:
        loc = changes["current_location"]
        changes["current_location"] = geo_point(
            loc["longitude"], loc["latitude"]
        ).model_dump(mode="json")
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


async def get_truck_planned_route(db: AsyncDatabase, truck_id: str) -> TruckPlannedRouteResponse:
    """The truck's active assigned plan, most recent first.

    Raises [TruckNotFoundError] for an unknown truck and [NoPlannedRouteError]
    when the truck has no assigned/in-progress plan. Stops whose posts were
    collected or marked pending since planning are filtered out so the
    collector only follows remaining work; depots are embedded in route order.
    """
    truck_doc = await _get_truck_doc(db, truck_id)
    candidates = [
        doc
        async for doc in db[route_model.COLLECTION].find(
            {
                "truck_id": truck_doc["_id"],
                "status": {
                    "$in": [
                        PlannedRouteStatus.ASSIGNED.value,
                        PlannedRouteStatus.IN_PROGRESS.value,
                    ]
                },
            }
        )
    ]
    if not candidates:
        raise NoPlannedRouteError(truck_id)
    doc = max(candidates, key=lambda d: d.get("created_at"))
    stop_post_ids = [stop["post_id"] for stop in doc.get("stops", [])]
    finished: set = set()
    if stop_post_ids:
        finished = {
            collection_doc["_id"]
            async for collection_doc in db[garbage_model.COLLECTION].find(
                {
                    "_id": {"$in": stop_post_ids},
                    "status": {
                        "$in": [
                            GarbageStatus.COLLECTED.value,
                            GarbageStatus.PENDING_CONFIRMATION.value,
                        ]
                    },
                }
            )
        }
    stops = [
        PlannedStopResponse(
            post_id=str(stop["post_id"]),
            location=stop["location"],
            types=stop["types"],
            distance_meters=stop.get("distance_meters"),
        )
        for stop in doc.get("stops", [])
        if stop["post_id"] not in finished
    ]
    depot_ids = doc.get("depot_ids", [])
    depots_by_id = (
        {
            depot_doc["_id"]: depot_doc
            async for depot_doc in db[facility_model.COLLECTION].find(
                {"_id": {"$in": depot_ids}}
            )
        }
        if depot_ids
        else {}
    )
    return TruckPlannedRouteResponse(
        id=str(doc["_id"]),
        truck_id=str(doc["truck_id"]),
        name=doc.get("name"),
        origin=doc["origin"],
        stops=stops,
        total_stops=len(doc.get("stops", [])),
        status=doc["status"],
        scheduled_for=route_model.scheduled_day(doc),
        created_at=doc["created_at"],
        depot_ids=[str(depot_id) for depot_id in depot_ids],
        depots=[
            FacilityResponse(
                id=str(depot_ids[i]),
                name=depots_by_id[depot_ids[i]]["name"],
                kind=depots_by_id[depot_ids[i]]["kind"],
                location=depots_by_id[depot_ids[i]]["location"],
                accepted_types=depots_by_id[depot_ids[i]]["accepted_types"],
                address=depots_by_id[depot_ids[i]].get("address"),
                created_at=depots_by_id[depot_ids[i]]["created_at"],
                updated_at=depots_by_id[depot_ids[i]]["updated_at"],
            )
            for i in range(len(depot_ids))
            if depot_ids[i] in depots_by_id
        ],
        collection_points=doc.get("collection_points", []),
        geometry=doc.get("geometry"),
        geometry_source=doc.get("geometry_source", "straight"),
    )


def _vicinity_query(origin: GeoPoint, radius_meters: float, wanted_types: list[str]) -> dict:
    """Posts collectable around [origin]: posted/scheduled, matching types."""
    return {
        "location": {
            "$geoWithin": {
                "$centerSphere": [
                    [origin.longitude, origin.latitude],
                    radius_meters / EARTH_RADIUS_METERS,
                ]
            }
        },
        "status": {"$in": [GarbageStatus.POSTED.value, GarbageStatus.SCHEDULED.value]},
        "types": {"$in": wanted_types},
    }


def _to_post_response(doc: dict) -> GarbagePostResponse:
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


async def find_collect_candidates(
    db: AsyncDatabase,
    truck_id: str,
    longitude: float | None = None,
    latitude: float | None = None,
    radius_meters: float = 30,
    limit: int = 50,
    types: list | None = None,
    user: object | None = None,
) -> list[GarbagePostResponse]:
    """Preview of what [collect_vicinity] would collect: same origin, radius,
    types, and operator guard, without writing anything."""
    truck_doc = await _get_truck_doc(db, truck_id)
    _require_operator_binding(truck_doc, user)
    origin = resolve_origin(truck_doc, longitude, latitude)
    wanted_types = _effective_types(truck_doc, types)
    if not wanted_types:
        return []
    cursor = (
        db[garbage_model.COLLECTION].find(_vicinity_query(origin, radius_meters, wanted_types))
        .limit(limit)
    )
    return [_to_post_response(doc) async for doc in cursor]


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
    collected_types: dict[str, int] = {}
    if wanted_types:
        matches = db[garbage_model.COLLECTION].find(
            _vicinity_query(origin, payload.radius_meters, wanted_types)
        )
        async for doc in matches:
            post_ids.append(str(doc["_id"]))
            for garbage_type in doc.get("types", []):
                name = str(garbage_type)
                collected_types[name] = collected_types.get(name, 0) + 1
        if post_ids:
            await db[garbage_model.COLLECTION].update_many(
                {
                    "_id": {"$in": [ObjectId(pid) for pid in post_ids]},
                    "status": {"$in": [GarbageStatus.POSTED.value, GarbageStatus.SCHEDULED.value]},
                },
                {
                    "$set": {
                        "status": GarbageStatus.PENDING_CONFIRMATION.value,
                        "collected_at": utcnow(),
                        "collected_by_truck_id": truck_doc["_id"],
                    }
                },
            )

    # Each type entry consumes one capacity unit, so a two-type post counts
    # twice; the total stays the sum of the per-type buckets.
    load_by_type = {str(k): int(v) for k, v in truck_doc.get("load_by_type", {}).items()}
    for name, count in collected_types.items():
        load_by_type[name] = load_by_type.get(name, 0) + count
    load = sum(load_by_type.values())
    capacity = truck_doc.get("capacity")
    availability = truck_doc.get("availability", TruckAvailability.AVAILABLE.value)
    await db[truck_model.COLLECTION].update_one(
        {"_id": truck_doc["_id"]},
        {"$set": {"load": load, "load_by_type": load_by_type}},
    )
    if post_ids:
        # First pickup starts the run: the assigned route goes in progress.
        await db[route_model.COLLECTION].update_many(
            {
                "truck_id": truck_doc["_id"],
                "status": PlannedRouteStatus.ASSIGNED.value,
            },
            {"$set": {"status": PlannedRouteStatus.IN_PROGRESS.value}},
        )
    return CollectVicinityResponse(
        truck_id=truck_id,
        collected_count=len(post_ids),
        post_ids=post_ids,
        load=load,
        load_by_type=load_by_type,
        capacity=capacity,
        availability=availability,
    )


async def update_truck_location(
    db: AsyncDatabase,
    truck_id: str,
    payload: TruckLocation,
    user: object | None = None,
) -> TruckResponse:
    truck_doc = await _get_truck_doc(db, truck_id)
    _require_operator_binding(truck_doc, user)
    location = geo_point(payload.longitude, payload.latitude).model_dump(mode="json")
    await db[truck_model.COLLECTION].update_one(
        {"_id": truck_doc["_id"]}, {"$set": {"current_location": location}}
    )
    truck_doc.update({"current_location": location})
    return _to_response(truck_doc)


async def finish_active_route(
    db: AsyncDatabase, truck_id: str, user: object | None = None
) -> TruckResponse:
    """Close the truck's active run: route done, truck free for assignment.

    Unfinished scheduled stops revert to posted for the next run; collected
    and pending posts are untouched. Availability and load are left alone:
    receiving already manages them, and a still-loaded truck simply is not
    assignable until a depot takes the load.
    """
    truck_doc = await _get_truck_doc(db, truck_id)
    _require_operator_binding(truck_doc, user)
    active = [
        doc
        async for doc in db[route_model.COLLECTION].find(
            {
                "truck_id": truck_doc["_id"],
                "status": {
                    "$in": [
                        PlannedRouteStatus.ASSIGNED.value,
                        PlannedRouteStatus.IN_PROGRESS.value,
                    ]
                },
            }
        )
    ]
    if not active:
        raise NoActiveRouteError(truck_id)
    route_doc = max(active, key=lambda d: d.get("created_at"))
    await db[route_model.COLLECTION].update_one(
        {"_id": route_doc["_id"]},
        {"$set": {"status": PlannedRouteStatus.DONE.value}},
    )
    stop_ids = [
        stop["post_id"] for stop in route_doc.get("stops", []) if stop.get("post_id")
    ]
    if stop_ids:
        await db[garbage_model.COLLECTION].update_many(
            {"_id": {"$in": stop_ids}, "status": GarbageStatus.SCHEDULED.value},
            {"$set": {"status": GarbageStatus.POSTED.value}},
        )
    remaining = [
        doc
        async for doc in db[route_model.COLLECTION].find(
            {
                "truck_id": truck_doc["_id"],
                "status": {
                    "$in": [
                        PlannedRouteStatus.ASSIGNED.value,
                        PlannedRouteStatus.IN_PROGRESS.value,
                    ]
                },
            }
        )
    ]
    if not remaining:
        await db[truck_model.COLLECTION].update_one(
            {"_id": truck_doc["_id"]},
            {"$set": {"availability": TruckAvailability.AVAILABLE.value}},
        )
        truck_doc["availability"] = TruckAvailability.AVAILABLE.value
    return _to_response(truck_doc)
