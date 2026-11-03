"""Depot receipt documents: proof a truck unloaded at a facility."""

from datetime import datetime

from pydantic import Field

from app.models.common import MongoDocument, PyObjectId, utcnow

COLLECTION = "depot_receipts"


class DepotReceiptDocument(MongoDocument):
    depot_id: PyObjectId
    truck_id: PyObjectId
    plate_number: str
    load_cleared: int = Field(ge=0)
    received_by: str
    received_at: datetime = Field(default_factory=utcnow)
