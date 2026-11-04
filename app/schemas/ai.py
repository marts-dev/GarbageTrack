"""AI classification schemas."""

from pydantic import BaseModel, Field, model_validator

from app.models.garbage import GarbageType
from app.schemas.common import ImagePayload


class ClassifyRequest(ImagePayload):
    description: str | None = Field(default=None, max_length=2000)

    @model_validator(mode="after")
    def check_has_input(self) -> "ClassifyRequest":
        if not (self.description or "").strip() and self.image_base64 is None:
            raise ValueError("provide a description or an image")
        return self


class ClassifyResponse(BaseModel):
    suggested_types: list[GarbageType]
    confidence: float = Field(ge=0.0, le=1.0)
    placeholder: bool
    message: str
