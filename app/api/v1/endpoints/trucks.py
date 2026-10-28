from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pymongo.asynchronous.database import AsyncDatabase

from app.api.deps import get_db
from app.models.garbage import GarbageType
from app.schemas.trucks import (
    AvailabilityUpdate,
    CollectionRouteResponse,
    CollectVicinityRequest,
    CollectVicinityResponse,
    TruckResponse,
    TruckScheduleCreate,
)
from app.services import trucks as trucks_service
from app.services.trucks import TruckLocationUnknownError, TruckNotFoundError

router = APIRouter(prefix="/trucks", tags=["trucks"])

Db = Annotated[AsyncDatabase, Depends(get_db)]
Longitude = Annotated[float | None, Query(ge=-180, le=180)]
Latitude = Annotated[float | None, Query(ge=-90, le=90)]


@router.post("/schedules", response_model=TruckResponse, status_code=status.HTTP_201_CREATED)
async def create_schedule(payload: TruckScheduleCreate, db: Db):
    return await trucks_service.create_schedule(db, payload)


@router.get("/enroute", response_model=list[TruckResponse])
async def list_enroute(
    db: Db,
    longitude: Longitude = None,
    latitude: Latitude = None,
    max_meters: Annotated[float, Query(gt=0)] = 10000,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
):
    return await trucks_service.list_enroute(db, longitude, latitude, max_meters, limit)


@router.get("/{truck_id}", response_model=TruckResponse)
async def read_truck(truck_id: str, db: Db):
    try:
        return await trucks_service.get_truck(db, truck_id)
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None


@router.get("/{truck_id}/route", response_model=CollectionRouteResponse)
async def read_collection_route(
    truck_id: str,
    db: Db,
    longitude: Longitude = None,
    latitude: Latitude = None,
    max_meters: Annotated[float, Query(gt=0)] = 5000,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
    types: Annotated[list[GarbageType] | None, Query()] = None,
):
    try:
        return await trucks_service.get_collection_route(
            db, truck_id, longitude, latitude, max_meters, limit, types
        )
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None
    except TruckLocationUnknownError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from None


@router.post("/{truck_id}/collect-vicinity", response_model=CollectVicinityResponse)
async def collect_vicinity(truck_id: str, payload: CollectVicinityRequest, db: Db):
    try:
        return await trucks_service.collect_vicinity(db, truck_id, payload)
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None
    except TruckLocationUnknownError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from None


@router.patch("/{truck_id}/availability", response_model=TruckResponse)
async def update_availability(truck_id: str, payload: AvailabilityUpdate, db: Db):
    try:
        return await trucks_service.set_availability(db, truck_id, payload.availability)
    except TruckNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="truck not found") from None
