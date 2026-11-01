from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.api.deps import CurrentUser, Db, require_roles
from app.models.auth import Role
from app.models.garbage import GarbageType
from app.models.truck import TruckAvailability, TruckStatus
from app.schemas.auth import UserResponse
from app.schemas.trucks import (
    AvailabilityUpdate,
    CollectionRouteResponse,
    CollectVicinityRequest,
    CollectVicinityResponse,
    TruckResponse,
    TruckScheduleCreate,
    TruckUpdate,
)
from app.services import trucks as trucks_service
from app.services.trucks import (
    EmptyUpdateError,
    TruckHasRoutesError,
    TruckLocationUnknownError,
    TruckNotAssignedError,
    TruckNotFoundError,
    TruckOperatorConflictError,
    TruckOperatorInvalidError,
    TruckOperatorNotFoundError,
)

router = APIRouter(prefix="/trucks", tags=["trucks"])

Longitude = Annotated[float | None, Query(ge=-180, le=180)]
Latitude = Annotated[float | None, Query(ge=-90, le=90)]
Collector = Annotated[UserResponse, Depends(require_roles(Role.COLLECTOR, Role.LOGISTICS))]
Dispatcher = Annotated[UserResponse, Depends(require_roles(Role.LOGISTICS))]


@router.post("/schedules", response_model=TruckResponse, status_code=status.HTTP_201_CREATED)
async def create_schedule(payload: TruckScheduleCreate, user: Dispatcher, db: Db):
    _ = user
    return await trucks_service.create_schedule(db, payload)


@router.get("/enroute", response_model=list[TruckResponse])
async def list_enroute(
    user: CurrentUser,
    db: Db,
    longitude: Longitude = None,
    latitude: Latitude = None,
    max_meters: Annotated[float, Query(gt=0)] = 10000,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
):
    _ = user
    return await trucks_service.list_enroute(db, longitude, latitude, max_meters, limit)


@router.get("", response_model=list[TruckResponse])
async def list_trucks(
    user: Collector,
    db: Db,
    status: TruckStatus | None = None,
    availability: TruckAvailability | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
):
    _ = user
    return await trucks_service.list_trucks(db, status, availability, limit)


@router.get("/{truck_id}", response_model=TruckResponse)
async def read_truck(truck_id: str, user: Collector, db: Db):
    _ = user
    try:
        return await trucks_service.get_truck(db, truck_id)
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None


@router.patch("/{truck_id}", response_model=TruckResponse)
async def edit_truck(truck_id: str, payload: TruckUpdate, user: Dispatcher, db: Db):
    _ = user
    try:
        return await trucks_service.update_truck(db, truck_id, payload)
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None
    except TruckOperatorNotFoundError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="operator user not found"
        ) from None
    except TruckOperatorConflictError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from None
    except TruckOperatorInvalidError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)
        ) from None
    except EmptyUpdateError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from None


@router.delete("/{truck_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_truck(truck_id: str, user: Dispatcher, db: Db):
    _ = user
    try:
        await trucks_service.delete_truck(db, truck_id)
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None
    except TruckHasRoutesError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from None


@router.get("/{truck_id}/route", response_model=CollectionRouteResponse)
async def read_collection_route(
    truck_id: str,
    user: Collector,
    db: Db,
    longitude: Longitude = None,
    latitude: Latitude = None,
    max_meters: Annotated[float, Query(gt=0)] = 5000,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
    types: Annotated[list[GarbageType] | None, Query()] = None,
    district: str | None = None,
    country: str | None = None,
):
    _ = user
    try:
        return await trucks_service.get_collection_route(
            db, truck_id, longitude, latitude, max_meters, limit, types, district, country
        )
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None
    except TruckLocationUnknownError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from None


@router.post("/{truck_id}/collect-vicinity", response_model=CollectVicinityResponse)
async def collect_vicinity(truck_id: str, payload: CollectVicinityRequest, user: Collector, db: Db):
    try:
        return await trucks_service.collect_vicinity(db, truck_id, payload, user)
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None
    except TruckNotAssignedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from None
    except TruckLocationUnknownError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from None


@router.patch("/{truck_id}/availability", response_model=TruckResponse)
async def update_availability(truck_id: str, payload: AvailabilityUpdate, user: Collector, db: Db):
    try:
        return await trucks_service.set_availability(db, truck_id, payload.availability, user)
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None
    except TruckNotAssignedError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from None
