from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, status

from app.api.deps import CurrentUser, Db
from app.models.auth import Role
from app.models.garbage import GarbageStatus
from app.schemas.garbage import GarbagePostCreate, GarbagePostResponse
from app.services import garbage as garbage_service
from app.services.garbage import GarbageAlreadyCollectedError, GarbagePostNotFoundError

router = APIRouter(prefix="/garbage", tags=["garbage"])

Longitude = Annotated[float | None, Query(ge=-180, le=180)]
Latitude = Annotated[float | None, Query(ge=-90, le=90)]

OPERATIONAL_ROLES = {Role.COLLECTOR, Role.LOGISTICS, Role.ADMIN}


@router.post("", response_model=GarbagePostResponse, status_code=status.HTTP_201_CREATED)
async def create_post(payload: GarbagePostCreate, user: CurrentUser, db: Db):
    if user.role != Role.RESIDENT:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="only residents can post garbage"
        )
    if payload.user_id != user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="can only post as yourself"
        )
    return await garbage_service.create_post(db, payload, user.country)


@router.get("", response_model=list[GarbagePostResponse])
async def search_posts(
    user: CurrentUser,
    db: Db,
    user_id: str | None = None,
    status: GarbageStatus | None = None,
    longitude: Longitude = None,
    latitude: Latitude = None,
    max_meters: Annotated[float, Query(gt=0)] = 5000,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    district: str | None = None,
    country: str | None = None,
):
    _ = user
    return await garbage_service.list_posts(
        db, user_id, status, longitude, latitude, max_meters, limit, district, country
    )


@router.get("/{post_id}", response_model=GarbagePostResponse)
async def read_post(post_id: str, user: CurrentUser, db: Db):
    _ = user
    try:
        return await garbage_service.get_post(db, post_id)
    except GarbagePostNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="garbage post not found") from None


@router.patch("/{post_id}/confirm-collected", response_model=GarbagePostResponse)
async def confirm_collected(post_id: str, user: CurrentUser, db: Db):
    try:
        post = await garbage_service.get_post(db, post_id)
    except GarbagePostNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="garbage post not found") from None
    if post.user_id != user.id and user.role not in OPERATIONAL_ROLES:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="only the owner or operations can confirm"
        )
    try:
        return await garbage_service.confirm_collected(db, post_id)
    except GarbagePostNotFoundError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="garbage post not found") from None
    except GarbageAlreadyCollectedError:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="garbage already collected") from None
