from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from pymongo.asynchronous.database import AsyncDatabase

from app.api.deps import get_db
from app.schemas.users import LocationSaveRequest, UserLocationResponse
from app.services import users as users_service
from app.services.users import LocationNotFoundError

router = APIRouter(prefix="/users", tags=["users"])

Db = Annotated[AsyncDatabase, Depends(get_db)]


@router.put("/{user_id}/location", response_model=UserLocationResponse)
async def save_location(user_id: str, payload: LocationSaveRequest, db: Db):
    return await users_service.save_location(db, user_id, payload.longitude, payload.latitude)


@router.get("/{user_id}/location", response_model=UserLocationResponse)
async def read_location(user_id: str, db: Db):
    try:
        return await users_service.get_location(db, user_id)
    except LocationNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="location not found") from None
