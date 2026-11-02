from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.api.deps import Db, require_roles
from app.models.auth import Role
from app.models.facility import FacilityKind
from app.models.garbage import GarbageStatus, GarbageType
from app.models.route import PlannedRouteStatus
from app.models.truck import TruckAvailability, TruckStatus
from app.schemas.auth import UserResponse
from app.schemas.garbage import GarbagePostResponse
from app.schemas.logistics import (
    FacilityCreate,
    FacilityResponse,
    FacilityUpdate,
    GarbageSummaryResponse,
    PlannedRouteCreate,
    PlannedRouteResponse,
    TruckLocationResponse,
)
from app.services import logistics as logistics_service
from app.services.logistics import (
    DepotsNotFoundError,
    EmptyUpdateError,
    FacilityNotFoundError,
    NoCollectablePostsError,
    PlannedRouteNotFoundError,
    PostsAlreadyCollectedError,
    PostsNotFoundError,
)
from app.services.trucks import TruckLocationUnknownError, TruckNotFoundError

router = APIRouter(prefix="/logistics", tags=["logistics"])

Dispatcher = Annotated[UserResponse, Depends(require_roles(Role.LOGISTICS))]
Longitude = Annotated[float | None, Query(ge=-180, le=180)]
Latitude = Annotated[float | None, Query(ge=-90, le=90)]
Limit50 = Annotated[int, Query(ge=1, le=200)]


@router.get("/garbage", response_model=list[GarbagePostResponse])
async def list_all_posts(
    user: Dispatcher,
    db: Db,
    status: GarbageStatus | None = None,
    post_type: Annotated[GarbageType | None, Query(alias="type")] = None,
    user_id: str | None = None,
    limit: Limit50 = 100,
    district: str | None = None,
    country: str | None = None,
):
    _ = user
    return await logistics_service.list_all_posts(
        db, status, post_type, user_id, limit, district, country
    )


@router.get("/garbage/summary", response_model=GarbageSummaryResponse)
async def garbage_summary(
    user: Dispatcher,
    db: Db,
    country: Annotated[str | None, Query(max_length=100)] = None,
):
    _ = user
    return await logistics_service.garbage_summary(db, country)


@router.get("/trucks/locations", response_model=list[TruckLocationResponse])
async def list_truck_locations(
    user: Dispatcher,
    db: Db,
    status: TruckStatus | None = None,
    availability: TruckAvailability | None = None,
):
    _ = user
    return await logistics_service.truck_locations(db, status, availability)


@router.post("/facilities", response_model=FacilityResponse, status_code=status.HTTP_201_CREATED)
async def create_facility(payload: FacilityCreate, user: Dispatcher, db: Db):
    _ = user
    return await logistics_service.create_facility(db, payload)


@router.get("/facilities", response_model=list[FacilityResponse])
async def search_facilities(
    user: Dispatcher,
    db: Db,
    kind: FacilityKind | None = None,
    longitude: Longitude = None,
    latitude: Latitude = None,
    max_meters: Annotated[float, Query(gt=0)] = 10000,
    limit: Limit50 = 50,
):
    _ = user
    return await logistics_service.list_facilities(db, kind, longitude, latitude, max_meters, limit)


@router.get("/facilities/{facility_id}", response_model=FacilityResponse)
async def read_facility(facility_id: str, user: Dispatcher, db: Db):
    _ = user
    try:
        return await logistics_service.get_facility(db, facility_id)
    except FacilityNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="facility not found") from None


@router.patch("/facilities/{facility_id}", response_model=FacilityResponse)
async def edit_facility(facility_id: str, payload: FacilityUpdate, user: Dispatcher, db: Db):
    _ = user
    try:
        return await logistics_service.update_facility(db, facility_id, payload)
    except FacilityNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="facility not found") from None
    except EmptyUpdateError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from None


@router.delete("/facilities/{facility_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_facility(facility_id: str, user: Dispatcher, db: Db):
    _ = user
    try:
        await logistics_service.delete_facility(db, facility_id)
    except FacilityNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="facility not found") from None


@router.post("/routes", response_model=PlannedRouteResponse, status_code=status.HTTP_201_CREATED)
async def create_planned_route(payload: PlannedRouteCreate, user: Dispatcher, db: Db):
    _ = user
    try:
        return await logistics_service.create_planned_route(db, payload)
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None
    except PostsNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from None
    except DepotsNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from None
    except PostsAlreadyCollectedError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from None
    except NoCollectablePostsError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from None
    except TruckLocationUnknownError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from None


@router.get("/routes", response_model=list[PlannedRouteResponse])
async def search_planned_routes(
    user: Dispatcher,
    db: Db,
    truck_id: str | None = None,
    status: PlannedRouteStatus | None = None,
    limit: Limit50 = 50,
):
    _ = user
    try:
        return await logistics_service.list_planned_routes(db, truck_id, status, limit)
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None


@router.get("/routes/{route_id}", response_model=PlannedRouteResponse)
async def read_planned_route(route_id: str, user: Dispatcher, db: Db):
    _ = user
    try:
        return await logistics_service.get_planned_route(db, route_id)
    except PlannedRouteNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="route not found") from None


@router.delete("/routes/{route_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_planned_route(route_id: str, user: Dispatcher, db: Db):
    _ = user
    try:
        await logistics_service.delete_planned_route(db, route_id)
    except PlannedRouteNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="route not found") from None
