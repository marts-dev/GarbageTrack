"""Depot service: facility receiving and truck unloading."""

from bson import ObjectId
from bson.errors import InvalidId
from pymongo.asynchronous.database import AsyncDatabase

from app.models import auth as auth_model
from app.models import depot as depot_model
from app.models import facility as facility_model
from app.models import truck as truck_model
from app.models.truck import TruckAvailability
from app.schemas.depots import DepotReceiptResponse
from app.schemas.logistics import FacilityResponse
from app.schemas.trucks import TruckResponse
from app.services import trucks as trucks_service


class DepotNotAssignedError(Exception):
    pass


class DepotFacilityNotFoundError(Exception):
    pass


class UnacceptedTypesError(Exception):
    def __init__(self, rejected: list[str]):
        super().__init__(f"depot cannot accept: {rejected}")
        self.rejected = rejected


async def _caller_depot_id(db: AsyncDatabase, user_id: str) -> ObjectId:
    """Facility bound to the caller; depot staff work only their own depot."""
    try:
        user_object_id = ObjectId(user_id)
    except InvalidId as exc:
        raise DepotNotAssignedError(user_id) from exc
    stored = await db[auth_model.COLLECTION].find_one({"_id": user_object_id})
    depot_id = (stored or {}).get("depot_id")
    if not depot_id:
        raise DepotNotAssignedError(user_id)
    try:
        return ObjectId(depot_id)
    except InvalidId as exc:
        raise DepotNotAssignedError(user_id) from exc


async def get_my_depot(db: AsyncDatabase, user_id: str) -> FacilityResponse:
    depot_id = await _caller_depot_id(db, user_id)
    doc = await db[facility_model.COLLECTION].find_one({"_id": depot_id})
    if doc is None:
        raise DepotFacilityNotFoundError(str(depot_id))
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


async def inbound_trucks(db: AsyncDatabase, user_id: str) -> list[TruckResponse]:
    """Trucks carrying a load: the actionable receive list."""
    _ = await _caller_depot_id(db, user_id)
    cursor = db[truck_model.COLLECTION].find({})
    trucks = [trucks_service._to_response(doc) async for doc in cursor]
    return [truck for truck in trucks if truck.load > 0]


async def receive_truck(
    db: AsyncDatabase, user_id: str, truck_id: str
) -> DepotReceiptResponse:
    """Record a depot receipt and unload the truck.

    This is the only path that clears a truck's load: the depot's
    confirmation is the proof of unloading. Unloading is partial: the
    depot takes the load types it accepts and the rest stays on the
    truck for another depot, so a mixed load can never strand a truck.
    The truck only returns to available once fully empty.
    """
    depot_id = await _caller_depot_id(db, user_id)
    depot = await db[facility_model.COLLECTION].find_one({"_id": depot_id})
    if depot is None:
        raise DepotFacilityNotFoundError(str(depot_id))
    truck_doc = await trucks_service._get_truck_doc(db, truck_id)
    load_by_type = {
        str(k): int(v)
        for k, v in truck_doc.get("load_by_type", {}).items()
        if int(v) > 0
    }
    accepted = {str(t) for t in depot.get("accepted_types", [])}
    cleared_by_type = {t: n for t, n in load_by_type.items() if t in accepted}
    remaining_by_type = {t: n for t, n in load_by_type.items() if t not in accepted}
    if load_by_type and not cleared_by_type:
        raise UnacceptedTypesError(sorted(remaining_by_type))
    load_cleared = sum(cleared_by_type.values())
    remaining_load = sum(remaining_by_type.values())
    doc = depot_model.DepotReceiptDocument(
        depot_id=depot_id,
        truck_id=truck_doc["_id"],
        plate_number=str(truck_doc["plate_number"]),
        load_cleared=load_cleared,
        load_by_type=cleared_by_type,
        remaining_load=remaining_load,
        remaining_by_type=remaining_by_type,
        received_by=user_id,
    )
    stored = doc.model_dump(by_alias=True, exclude={"id"})
    result = await db[depot_model.COLLECTION].insert_one(stored)
    stored["_id"] = result.inserted_id
    new_fields: dict = {"load": remaining_load, "load_by_type": remaining_by_type}
    # A partially unloaded truck is still mid-unload: it reads working
    # until the last unit is cleared.
    new_fields["availability"] = (
        TruckAvailability.AVAILABLE.value
        if remaining_load == 0
        else TruckAvailability.WORKING.value
    )
    await db[truck_model.COLLECTION].update_one(
        {"_id": truck_doc["_id"]},
        {"$set": new_fields},
    )
    return _to_receipt_response(stored)


async def list_receipts(
    db: AsyncDatabase, user_id: str, limit: int = 50
) -> list[DepotReceiptResponse]:
    depot_id = await _caller_depot_id(db, user_id)
    cursor = db[depot_model.COLLECTION].find({"depot_id": depot_id}).limit(limit)
    receipts = [_to_receipt_response(doc) async for doc in cursor]
    receipts.sort(key=lambda r: r.received_at, reverse=True)
    return receipts


def _to_receipt_response(doc: dict) -> DepotReceiptResponse:
    return DepotReceiptResponse(
        id=str(doc["_id"]),
        depot_id=str(doc["depot_id"]),
        truck_id=str(doc["truck_id"]),
        plate_number=str(doc["plate_number"]),
        load_cleared=int(doc["load_cleared"]),
        load_by_type={str(k): int(v) for k, v in doc.get("load_by_type", {}).items()},
        remaining_load=int(doc.get("remaining_load", 0)),
        remaining_by_type={
            str(k): int(v) for k, v in doc.get("remaining_by_type", {}).items()
        },
        received_by=str(doc["received_by"]),
        received_at=doc["received_at"],
    )
