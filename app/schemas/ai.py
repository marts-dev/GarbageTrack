"""AI classification placeholder schemas."""

from pydantic import BaseModel, Field

from app.models.garbage import GarbageType
from app.schemas.common import ImagePayload


class ClassifyRequest(ImagePayload):
    description: str = Field(min_length=1, max_length=2000)


class ClassifyResponse(BaseModel):
    suggested_types: list[GarbageType]
    confidence: float = Field(ge=0.0, le=1.0)
    placeholder: bool
    message: str
