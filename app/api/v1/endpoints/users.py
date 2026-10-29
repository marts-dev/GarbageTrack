from fastapi import APIRouter, HTTPException, status

from app.api.deps import CurrentUser, Db, is_self_or_admin
from app.schemas.users import LocationSaveRequest, UserLocationResponse
from app.services import users as users_service
from app.services.users import LocationNotFoundError

router = APIRouter(prefix="/users", tags=["users"])


def _forbid_unless_self_or_admin(user: CurrentUser, user_id: str) -> None:
    if not is_self_or_admin(user, user_id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="forbidden")


@router.put("/{user_id}/location", response_model=UserLocationResponse)
async def save_location(user_id: str, payload: LocationSaveRequest, user: CurrentUser, db: Db):
    _forbid_unless_self_or_admin(user, user_id)
    return await users_service.save_location(db, user_id, payload.longitude, payload.latitude)


@router.get("/{user_id}/location", response_model=UserLocationResponse)
async def read_location(user_id: str, user: CurrentUser, db: Db):
    _forbid_unless_self_or_admin(user, user_id)
    try:
        return await users_service.get_location(db, user_id)
    except LocationNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="location not found") from None
