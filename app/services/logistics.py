"""Logistics service: overviews, facilities, and route assignment."""

from bson import ObjectId
from bson.errors import InvalidId
from pymongo.asynchronous.database import AsyncDatabase

from app.models import auth as auth_model
from app.models import facility as facility_model
from app.models import garbage as garbage_model
from app.models import route as route_model
from app.models import truck as truck_model
from app.models.common import utcnow
from app.models.facility import FacilityKind
from app.models.garbage import GarbageStatus, GarbageType
from app.models.geo import GeoLineString, GeoPoint, geo_point
from app.models.route import PlannedRouteStatus, PlannedStop
from app.models.truck import TruckAvailability
from app.schemas.garbage import GarbagePostResponse
from app.schemas.logistics import (
    FacilityCreate,
    FacilityResponse,
    FacilityUpdate,
    GarbageSummaryResponse,
    PlannedRouteCreate,
    PlannedRouteResponse,
    PlannedStopResponse,
    TruckLocationResponse,
)
from app.services import garbage as garbage_service
from app.services import regions as regions_service
from app.services import routing as routing_service
from app.services import trucks as trucks_service


class FacilityNotFoundError(Exception):
    pass


class PlannedRouteNotFoundError(Exception):
    pass


class EmptyUpdateError(Exception):
    pass


class NoCollectablePostsError(Exception):
    pass


class PostsNotFoundError(Exception):
    def __init__(self, missing: list[str]):
        super().__init__(f"posts not found: {missing}")
        self.missing = missing


class PostsAlreadyCollectedError(Exception):
    def __init__(self, collected: list[str]):
        super().__init__(f"posts already collected: {collected}")
        self.collected = collected


class PostsIncompatibleWithTruckError(Exception):
    def __init__(self, incompatible: list[str]):
        super().__init__(f"posts incompatible with truck: {incompatible}")
        self.incompatible = incompatible


class DepotsNotFoundError(Exception):
    def __init__(self, missing: list[str]):
        super().__init__(f"depots not found: {missing}")
        self.missing = missing


class TruckHasActiveRouteError(Exception):
    pass


class TruckNotEmptyError(Exception):
    pass


def _to_object_id(value: str, error: type[Exception]):
    try:
        return ObjectId(value)
    except InvalidId as exc:
        raise error(value) from exc


async def list_all_posts(
    db: AsyncDatabase,
    status: GarbageStatus | None = None,
    post_type: GarbageType | None = None,
    user_id: str | None = None,
    limit: int = 100,
    district: str | None = None,
    country: str | None = None,
) -> list[GarbagePostResponse]:
    posts = await garbage_service.list_posts(
        db, user_id=user_id, status=status, limit=limit, district=district, country=country
    )
    if post_type is not None:
        posts = [p for p in posts if post_type in p.types]
    return posts


async def garbage_summary(
    db: AsyncDatabase, country: str | None = None
) -> GarbageSummaryResponse:
    docs = [doc async for doc in db[garbage_model.COLLECTION].find({})]
    if country:
        docs = _posts_in_country(docs, country)
    by_status: dict[str, int] = {}
    by_type: dict[str, int] = {}
    for doc in docs:
        status = str(doc["status"])
        by_status[status] = by_status.get(status, 0) + 1
        for garbage_type in doc.get("types", []):
            name = str(garbage_type)
            by_type[name] = by_type.get(name, 0) + 1
    by_region = regions_service.aggregate_by_region(docs, country) if country else {}
    return GarbageSummaryResponse(
        total=len(docs), by_status=by_status, by_type=by_type, by_region=by_region
    )


def _posts_in_country(posts: list[dict], country: str) -> list[dict]:
    """Posts belonging to a country.

    Countries with shipped boundaries use geospatial containment so the
    pills match the choropleth exactly; the rest fall back to the country
    stamped on the post at creation (case-insensitive).
    """
    regions = regions_service.load_regions(country)
    if regions:
        return [doc for doc in posts if regions_service.doc_in_country(doc, regions)]
    wanted = country.strip().lower()
    return [
        doc
        for doc in posts
        if str(doc.get("country") or "").strip().lower() == wanted
    ]


async def truck_locations(
    db: AsyncDatabase,
    availability: TruckAvailability | None = None,
) -> list[TruckLocationResponse]:
    query: dict = {}
    if availability is not None:
        query["availability"] = availability.value
    locations = []
    async for doc in db[truck_model.COLLECTION].find(query):
        locations.append(
            TruckLocationResponse(
                truck_id=str(doc["_id"]),
                plate_number=doc["plate_number"],
                availability=doc.get("availability", TruckAvailability.AVAILABLE.value),
                current_location=doc.get("current_location"),
                load=doc.get("load", 0),
                capacity=doc.get("capacity"),
                operator_id=doc.get("operator_id"),
            )
        )
    return locations


def _to_facility_response(doc: dict) -> FacilityResponse:
    return FacilityResponse(
        id=str(doc["_id"]),
        name=doc["name"],
        kind=doc["kind"],
        location=doc["location"],
        accepted_types=doc["accepted_types"],
        address=doc.get("address"),
        created_at=doc["created_at"],
        updated_at=doc["updated_at"],
    )


async def create_facility(db: AsyncDatabase, payload: FacilityCreate) -> FacilityResponse:
    doc = facility_model.FacilityDocument(
        name=payload.name,
        kind=payload.kind,
        location=geo_point(payload.location.longitude, payload.location.latitude),
        accepted_types=payload.accepted_types,
        address=payload.address,
    )
    stored = doc.model_dump(by_alias=True, exclude={"id"})
    result = await db[facility_model.COLLECTION].insert_one(stored)
    stored["_id"] = result.inserted_id
    return _to_facility_response(stored)


async def get_facility(db: AsyncDatabase, facility_id: str) -> FacilityResponse:
    object_id = _to_object_id(facility_id, FacilityNotFoundError)
    stored = await db[facility_model.COLLECTION].find_one({"_id": object_id})
    if stored is None:
        raise FacilityNotFoundError(facility_id)
    return _to_facility_response(stored)


async def list_facilities(
    db: AsyncDatabase,
    kind: FacilityKind | None = None,
    longitude: float | None = None,
    latitude: float | None = None,
    max_meters: float = 10000,
    limit: int = 50,
) -> list[FacilityResponse]:
    query: dict = {}
    if kind is not None:
        query["kind"] = kind.value
    if longitude is not None and latitude is not None:
        query["location"] = {
            "$near": {
                "$geometry": {"type": "Point", "coordinates": [longitude, latitude]},
                "$maxDistance": max_meters,
            }
        }
    cursor = db[facility_model.COLLECTION].find(query).limit(limit)
    return [_to_facility_response(doc) async for doc in cursor]


async def update_facility(
    db: AsyncDatabase, facility_id: str, payload: FacilityUpdate
) -> FacilityResponse:
    object_id = _to_object_id(facility_id, FacilityNotFoundError)
    changes = payload.model_dump(exclude_unset=True)
    if "location" in changes and changes["location"] is not None:
        loc = changes["location"]
        changes["location"] = geo_point(loc["longitude"], loc["latitude"]).model_dump()
    if not changes:
        raise EmptyUpdateError("no fields to update")
    changes["updated_at"] = utcnow()
    stored = await db[facility_model.COLLECTION].find_one_and_update(
        {"_id": object_id}, {"$set": changes}
    )
    if stored is None:
        raise FacilityNotFoundError(facility_id)
    stored.update(changes)
    return _to_facility_response(stored)


async def delete_facility(db: AsyncDatabase, facility_id: str) -> None:
    object_id = _to_object_id(facility_id, FacilityNotFoundError)
    result = await db[facility_model.COLLECTION].delete_one({"_id": object_id})
    if result.deleted_count == 0:
        raise FacilityNotFoundError(facility_id)
    # Release depot users bound here so they stop pointing at a dead depot.
    await db[auth_model.COLLECTION].update_many(
        {"depot_id": facility_id}, {"$unset": {"depot_id": ""}}
    )


def _to_route_response(doc: dict) -> PlannedRouteResponse:
    return PlannedRouteResponse(
        id=str(doc["_id"]),
        truck_id=str(doc["truck_id"]),
        name=doc.get("name"),
        origin=doc["origin"],
        stops=[
            PlannedStopResponse(
                post_id=str(stop["post_id"]),
                location=stop["location"],
                types=stop["types"],
                distance_meters=stop.get("distance_meters"),
            )
            for stop in doc["stops"]
        ],
        status=doc["status"],
        scheduled_for=route_model.scheduled_day(doc),
        created_at=doc["created_at"],
        depot_ids=[str(depot_id) for depot_id in doc.get("depot_ids", [])],
        collection_points=doc.get("collection_points", []),
        geometry=doc.get("geometry"),
        geometry_source=doc.get("geometry_source", "straight"),
    )


def _planned_geometry(
    origin: GeoPoint, stops: list[PlannedStop], end: GeoPoint | None
) -> tuple[GeoLineString | None, str]:
    points = [(origin.longitude, origin.latitude)]
    points += [(stop.location.longitude, stop.location.latitude) for stop in stops]
    if end is not None:
        points.append((end.longitude, end.latitude))
    if len(points) < 2:
        return None, "straight"
    geom = routing_service.route_points(points)
    source = "straight" if geom.fallback else "road"
    if len(geom.points) < 2:
        return None, source
    return GeoLineString(coordinates=geom.points), source


async def _resolve_depots(db: AsyncDatabase, depot_ids: list[str]) -> list[ObjectId]:
    """Validate every depot id against facilities (all kinds)."""
    object_ids: list[ObjectId] = []
    invalid: list[str] = []
    for raw in depot_ids:
        try:
            object_ids.append(ObjectId(raw))
        except InvalidId:
            invalid.append(raw)
    found: set[str] = set()
    if object_ids:
        found = {
            str(doc["_id"])
            async for doc in db[facility_model.COLLECTION].find({"_id": {"$in": object_ids}})
        }
    missing = [raw for raw in depot_ids if raw in invalid or raw not in found]
    if missing:
        raise DepotsNotFoundError(missing)
    return object_ids


async def _require_assignable(db: AsyncDatabase, truck_doc: dict) -> None:
    """A truck takes a route only when free of runs and unloaded."""
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
    if active:
        raise TruckHasActiveRouteError(str(truck_doc["_id"]))
    if int(truck_doc.get("load", 0)) > 0:
        raise TruckNotEmptyError(str(truck_doc["_id"]))


async def _mark_posts_scheduled(db: AsyncDatabase, post_ids: list[ObjectId]) -> None:
    if post_ids:
        await db[garbage_model.COLLECTION].update_many(
            {
                "_id": {"$in": post_ids},
                "status": {"$in": [GarbageStatus.POSTED.value, GarbageStatus.SCHEDULED.value]},
            },
            {"$set": {"status": GarbageStatus.SCHEDULED.value}},
        )


async def create_planned_route(db: AsyncDatabase, payload: PlannedRouteCreate) -> PlannedRouteResponse:
    truck_id = _to_object_id(payload.truck_id, trucks_service.TruckNotFoundError)
    truck_doc = await db[truck_model.COLLECTION].find_one({"_id": truck_id})
    if truck_doc is None:
        raise trucks_service.TruckNotFoundError(payload.truck_id)
    await _require_assignable(db, truck_doc)
    depot_object_ids = await _resolve_depots(db, payload.depot_ids)

    origin: GeoPoint
    stops: list[PlannedStop]
    post_object_ids: list[ObjectId]
    if payload.post_ids is not None:
        post_object_ids = []
        for raw in payload.post_ids:
            try:
                post_object_ids.append(ObjectId(raw))
            except InvalidId as exc:
                raise PostsNotFoundError([raw]) from exc
        found = [
            doc
            async for doc in db[garbage_model.COLLECTION].find({"_id": {"$in": post_object_ids}})
        ]
        found_ids = {str(doc["_id"]) for doc in found}
        missing = [raw for raw in payload.post_ids if raw not in found_ids]
        if missing:
            raise PostsNotFoundError(missing)
        collected = [
            str(doc["_id"]) for doc in found if str(doc["status"]) == GarbageStatus.COLLECTED.value
        ]
        if collected:
            raise PostsAlreadyCollectedError(collected)
        truck_types = {str(t) for t in truck_doc.get("garbage_types", [])}
        incompatible = [
            str(doc["_id"])
            for doc in found
            if not ({str(t) for t in doc.get("types", [])} & truck_types)
        ]
        if incompatible:
            raise PostsIncompatibleWithTruckError(incompatible)
        origin = trucks_service.resolve_origin(truck_doc, payload.longitude, payload.latitude)
        stops = [
            PlannedStop(post_id=doc["_id"], location=doc["location"], types=doc["types"])
            for doc in found
        ]
    else:
        # district/country narrow only the auto path; manual post_ids are used as given.
        route = await trucks_service.get_collection_route(
            db,
            payload.truck_id,
            payload.longitude,
            payload.latitude,
            payload.max_meters,
            payload.limit,
            payload.types,
            payload.district,
            payload.country,
        )
        if not route.stops:
            raise NoCollectablePostsError("no collectable posts for this truck")
        origin = route.origin
        stops = [
            PlannedStop(
                post_id=ObjectId(stop.post_id),
                location=stop.location,
                types=stop.types,
                distance_meters=stop.distance_meters,
            )
            for stop in route.stops
        ]
        post_object_ids = [ObjectId(stop.post_id) for stop in route.stops]

    await _mark_posts_scheduled(db, post_object_ids)
    collection_points = [
        geo_point(point.longitude, point.latitude) for point in (payload.collection_points or [])
    ]
    end: GeoPoint | None = None
    if depot_object_ids:
        # Depots run in visit order; the last pick is the route end.
        depot_doc = await db[facility_model.COLLECTION].find_one({"_id": depot_object_ids[-1]})
        if depot_doc is not None and depot_doc.get("location") is not None:
            end = GeoPoint.model_validate(depot_doc["location"])
    geometry, geometry_source = _planned_geometry(origin, stops, end)
    doc = route_model.PlannedRouteDocument(
        truck_id=truck_id,
        name=payload.name,
        origin=origin,
        stops=stops,
        depot_ids=depot_object_ids,
        collection_points=collection_points,
        scheduled_for=(payload.scheduled_for or utcnow().date()).isoformat(),
        geometry=geometry,
        geometry_source=geometry_source,
    )
    stored = doc.model_dump(by_alias=True, exclude={"id"})
    result = await db[route_model.COLLECTION].insert_one(stored)
    stored["_id"] = result.inserted_id
    await db[truck_model.COLLECTION].update_one(
        {"_id": truck_id},
        {"$set": {"availability": TruckAvailability.WORKING.value}},
    )
    return _to_route_response(stored)


async def list_planned_routes(
    db: AsyncDatabase,
    truck_id: str | None = None,
    status: PlannedRouteStatus | None = None,
    limit: int = 50,
) -> list[PlannedRouteResponse]:
    query: dict = {}
    if truck_id is not None:
        query["truck_id"] = _to_object_id(truck_id, trucks_service.TruckNotFoundError)
    if status is not None:
        query["status"] = status.value
    cursor = db[route_model.COLLECTION].find(query).limit(limit)
    return [_to_route_response(doc) async for doc in cursor]


async def get_planned_route(db: AsyncDatabase, route_id: str) -> PlannedRouteResponse:
    object_id = _to_object_id(route_id, PlannedRouteNotFoundError)
    stored = await db[route_model.COLLECTION].find_one({"_id": object_id})
    if stored is None:
        raise PlannedRouteNotFoundError(route_id)
    return _to_route_response(stored)


async def _release_truck_if_idle(db: AsyncDatabase, truck_id: object | None) -> None:
    """Return a truck to available when it holds no more active routes."""
    if truck_id is None:
        return
    remaining = [
        doc
        async for doc in db[route_model.COLLECTION].find(
            {
                "truck_id": truck_id,
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
            {"_id": truck_id},
            {"$set": {"availability": TruckAvailability.AVAILABLE.value}},
        )


async def delete_planned_route(db: AsyncDatabase, route_id: str) -> None:
    try:
        object_id = ObjectId(route_id)
    except (InvalidId, TypeError) as exc:
        raise PlannedRouteNotFoundError(route_id) from exc
    stored = await db[route_model.COLLECTION].find_one({"_id": object_id})
    if stored is None:
        raise PlannedRouteNotFoundError(route_id)
    await db[route_model.COLLECTION].delete_one({"_id": object_id})
    await _release_truck_if_idle(db, stored.get("truck_id"))
    stop_ids = [stop["post_id"] for stop in stored.get("stops", []) if stop.get("post_id")]
    if stop_ids:
        await db[garbage_model.COLLECTION].update_many(
            {"_id": {"$in": stop_ids}, "status": GarbageStatus.SCHEDULED.value},
            {"$set": {"status": GarbageStatus.POSTED.value}},
        )
