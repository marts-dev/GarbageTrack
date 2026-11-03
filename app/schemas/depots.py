"""Depot receiving request/response schemas."""

from datetime import datetime

from pydantic import BaseModel, Field


class DepotReceiveRequest(BaseModel):
    truck_id: str = Field(min_length=1)


class DepotJoinRequest(BaseModel):
    facility_id: str = Field(min_length=1)


class DepotReceiptResponse(BaseModel):
    id: str
    depot_id: str
    truck_id: str
    plate_number: str
    load_cleared: int
    received_by: str
    received_at: datetime
