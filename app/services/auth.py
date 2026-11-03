"""Auth service: users, credentials, and roles."""

from bson import ObjectId
from bson.errors import InvalidId
from pymongo.asynchronous.database import AsyncDatabase

from app.core import security
from app.core.config import settings
from app.models import auth as auth_model
from app.models import facility as facility_model
from app.models import truck as truck_model
from app.models.auth import Role, UserDocument
from app.schemas.auth import UserResponse


class UserExistsError(Exception):
    pass


class UserNotFoundError(Exception):
    pass


class InvalidCredentialsError(Exception):
    pass


class DepotBindingRoleError(Exception):
    pass


class DepotNotFoundError(Exception):
    pass


def _to_response(doc: dict) -> UserResponse:
    # Tolerate pre-migration documents that stored a roles list.
    role = doc.get("role") or (doc.get("roles") or [Role.RESIDENT.value])[0]
    return UserResponse(
        id=str(doc["_id"]),
        email=doc["email"],
        full_name=doc.get("full_name"),
        role=role,
        country=doc.get("country"),
        is_active=doc.get("is_active", True),
        depot_id=doc.get("depot_id"),
        created_at=doc["created_at"],
    )


async def create_user(
    db: AsyncDatabase,
    email: str,
    password: str,
    role: Role,
    full_name: str | None = None,
    country: str | None = None,
) -> UserResponse:
    normalized = email.strip().lower()
    existing = await db[auth_model.COLLECTION].find_one({"email": normalized})
    if existing is not None:
        raise UserExistsError(normalized)
    doc = UserDocument(
        email=normalized,
        hashed_password=security.hash_password(password),
        full_name=full_name,
        role=role,
        country=country.strip() if country is not None else None,
    )
    stored = doc.model_dump(by_alias=True, exclude={"id"})
    result = await db[auth_model.COLLECTION].insert_one(stored)
    stored["_id"] = result.inserted_id
    return _to_response(stored)


async def authenticate_user(db: AsyncDatabase, email: str, password: str) -> UserResponse:
    stored = await db[auth_model.COLLECTION].find_one({"email": email.strip().lower()})
    if stored is None or not security.verify_password(password, stored["hashed_password"]):
        raise InvalidCredentialsError()
    if not stored.get("is_active", True):
        raise InvalidCredentialsError()
    return _to_response(stored)


async def get_user_by_id(db: AsyncDatabase, user_id: str) -> UserResponse:
    try:
        object_id = ObjectId(user_id)
    except InvalidId as exc:
        raise UserNotFoundError(user_id) from exc
    stored = await db[auth_model.COLLECTION].find_one({"_id": object_id})
    if stored is None:
        raise UserNotFoundError(user_id)
    return _to_response(stored)


async def list_users(
    db: AsyncDatabase, limit: int = 100, role: Role | None = None
) -> list[UserResponse]:
    if role is None:
        cursor = db[auth_model.COLLECTION].find({}).limit(limit)
        return [_to_response(doc) async for doc in cursor]
    cursor = db[auth_model.COLLECTION].find({})
    users = [_to_response(doc) async for doc in cursor]
    return [user for user in users if user.role == role][:limit]


async def update_user_role(db: AsyncDatabase, user_id: str, role: Role) -> UserResponse:
    try:
        object_id = ObjectId(user_id)
    except InvalidId as exc:
        raise UserNotFoundError(user_id) from exc
    update: dict = {"$set": {"role": role.value}, "$unset": {"roles": ""}}
    if role != Role.DEPOT:
        # A facility binding is only meaningful for depot users.
        update["$unset"] = {"roles": "", "depot_id": ""}
    stored = await db[auth_model.COLLECTION].find_one_and_update({"_id": object_id}, update)
    if stored is None:
        raise UserNotFoundError(user_id)
    stored["role"] = role
    stored.pop("roles", None)
    if role != Role.DEPOT:
        stored.pop("depot_id", None)
    return _to_response(stored)


async def update_user_depot(
    db: AsyncDatabase, user_id: str, depot_id: str | None
) -> UserResponse:
    """Bind a depot user to a facility (None unbinds)."""
    try:
        object_id = ObjectId(user_id)
    except InvalidId as exc:
        raise UserNotFoundError(user_id) from exc
    stored = await db[auth_model.COLLECTION].find_one({"_id": object_id})
    if stored is None:
        raise UserNotFoundError(user_id)
    if str(stored.get("role")) != Role.DEPOT.value:
        raise DepotBindingRoleError(user_id)
    if depot_id is None:
        await db[auth_model.COLLECTION].update_one(
            {"_id": object_id}, {"$unset": {"depot_id": ""}}
        )
        stored.pop("depot_id", None)
        return _to_response(stored)
    try:
        depot_object_id = ObjectId(depot_id)
    except InvalidId as exc:
        raise DepotNotFoundError(depot_id) from exc
    depot = await db[facility_model.COLLECTION].find_one({"_id": depot_object_id})
    if depot is None:
        raise DepotNotFoundError(depot_id)
    await db[auth_model.COLLECTION].update_one(
        {"_id": object_id}, {"$set": {"depot_id": depot_id}}
    )
    stored["depot_id"] = depot_id
    return _to_response(stored)


async def update_user_active(db: AsyncDatabase, user_id: str, active: bool) -> UserResponse:
    """Soft-delete: deactivation blocks login; it never removes the user.

    Deactivating also releases trucks the user operates so they stop
    showing a stale assignment. Reactivating does not restore bindings.
    """
    try:
        object_id = ObjectId(user_id)
    except InvalidId as exc:
        raise UserNotFoundError(user_id) from exc
    stored = await db[auth_model.COLLECTION].find_one_and_update(
        {"_id": object_id}, {"$set": {"is_active": active}}
    )
    if stored is None:
        raise UserNotFoundError(user_id)
    if not active:
        await db[truck_model.COLLECTION].update_many(
            {"operator_id": user_id}, {"$set": {"operator_id": None}}
        )
    stored["is_active"] = active
    return _to_response(stored)


async def update_profile(
    db: AsyncDatabase, user_id: str, full_name: str, country: str | None = None
) -> UserResponse:
    try:
        object_id = ObjectId(user_id)
    except InvalidId as exc:
        raise UserNotFoundError(user_id) from exc
    changes: dict = {"full_name": full_name}
    if country is not None:
        changes["country"] = country
    stored = await db[auth_model.COLLECTION].find_one_and_update(
        {"_id": object_id}, {"$set": changes}
    )
    if stored is None:
        raise UserNotFoundError(user_id)
    stored.update(changes)
    return _to_response(stored)


async def ensure_default_admin(db: AsyncDatabase) -> None:
    """Create the ops admin from env on first boot when no users exist."""
    if not settings.admin_email or not settings.admin_password:
        return
    existing = await db[auth_model.COLLECTION].find_one({})
    if existing is not None:
        return
    await create_user(
        db,
        email=settings.admin_email,
        password=settings.admin_password,
        role=Role.ADMIN,
        full_name="Administrator",
    )
