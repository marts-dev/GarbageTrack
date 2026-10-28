"""Shared request/response schema helpers."""

import base64

from pydantic import BaseModel, Field, field_validator

MAX_IMAGE_BYTES = 5 * 1024 * 1024


def validate_image_base64(value: str | None) -> str | None:
    if value is None:
        return None
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise ValueError("image_base64 is not valid base64") from exc
    if len(decoded) > MAX_IMAGE_BYTES:
        raise ValueError(f"decoded image exceeds {MAX_IMAGE_BYTES} bytes")
    return value


class ImagePayload(BaseModel):
    image_base64: str | None = None
    image_content_type: str | None = Field(default=None, examples=["image/jpeg"])

    _check_image = field_validator("image_base64")(validate_image_base64)

    @field_validator("image_content_type")
    @classmethod
    def check_content_type(cls, value: str | None) -> str | None:
        if value is not None and not value.startswith("image/"):
            raise ValueError("image_content_type must start with 'image/'")
        return value
