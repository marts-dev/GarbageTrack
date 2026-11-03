from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.api.deps import Db, require_roles
from app.models.auth import Role
from app.schemas.auth import UserResponse
from app.schemas.depots import DepotJoinRequest, DepotReceiptResponse, DepotReceiveRequest
from app.schemas.logistics import FacilityCreate, FacilityResponse
from app.schemas.trucks import TruckResponse
from app.services import auth as auth_service
from app.services import depots as depots_service
from app.services import logistics as logistics_service
from app.services.auth import DepotBindingRoleError, DepotNotFoundError
from app.services.depots import (
    DepotFacilityNotFoundError,
    DepotNotAssignedError,
    UnacceptedTypesError,
)
from app.services.logistics import FacilityNotFoundError
from app.services.trucks import TruckNotFoundError

router = APIRouter(prefix="/depots", tags=["depots"])

DepotStaff = Annotated[UserResponse, Depends(require_roles(Role.DEPOT))]


@router.post(
    "/mine/register", response_model=FacilityResponse, status_code=status.HTTP_201_CREATED
)
async def register_depot(payload: FacilityCreate, user: DepotStaff, db: Db):
    """Register a new depot and bind the caller to it in one call."""
    if user.role != Role.DEPOT:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="only depot users can register a depot",
        )
    try:
        facility = await logistics_service.create_facility(db, payload)
        await auth_service.update_user_depot(db, user.id, facility.id)
        return facility
    except DepotBindingRoleError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="only depot users can register a depot",
        ) from None


@router.post("/mine/join", response_model=FacilityResponse)
async def join_depot(payload: DepotJoinRequest, user: DepotStaff, db: Db):
    """Bind the caller to an existing depot (e.g. second staff member)."""
    if user.role != Role.DEPOT:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="only depot users can join a depot",
        )
    try:
        facility = await logistics_service.get_facility(db, payload.facility_id)
        await auth_service.update_user_depot(db, user.id, facility.id)
        return facility
    except FacilityNotFoundError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="facility not found"
        ) from None
    except (DepotBindingRoleError, DepotNotFoundError):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="only depot users can join a depot",
        ) from None


@router.get("/mine", response_model=FacilityResponse)
async def my_depot(user: DepotStaff, db: Db):
    try:
        return await depots_service.get_my_depot(db, user.id)
    except DepotNotAssignedError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="depot user has no facility assigned",
        ) from None
    except DepotFacilityNotFoundError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="facility not found"
        ) from None


@router.get("/mine/trucks", response_model=list[TruckResponse])
async def inbound_trucks(user: DepotStaff, db: Db):
    try:
        return await depots_service.inbound_trucks(db, user.id)
    except DepotNotAssignedError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="depot user has no facility assigned",
        ) from None


@router.post("/mine/receive", response_model=DepotReceiptResponse)
async def receive_truck(payload: DepotReceiveRequest, user: DepotStaff, db: Db):
    try:
        return await depots_service.receive_truck(db, user.id, payload.truck_id)
    except DepotNotAssignedError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="depot user has no facility assigned",
        ) from None
    except DepotFacilityNotFoundError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="facility not found"
        ) from None
    except TruckNotFoundError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="truck not found"
        ) from None
    except UnacceptedTypesError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)
        ) from None


@router.get("/mine/receipts", response_model=list[DepotReceiptResponse])
async def my_receipts(
    user: DepotStaff, db: Db, limit: Annotated[int, Query(ge=1, le=200)] = 50
):
    try:
        return await depots_service.list_receipts(db, user.id, limit)
    except DepotNotAssignedError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="depot user has no facility assigned",
        ) from None
