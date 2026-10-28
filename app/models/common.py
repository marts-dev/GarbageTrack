"""Shared building blocks for MongoDB document models."""

from datetime import UTC, datetime

from bson import ObjectId
from pydantic import BaseModel, ConfigDict, Field, GetCoreSchemaHandler
from pydantic_core import core_schema


def utcnow() -> datetime:
    return datetime.now(UTC)


class PyObjectId(ObjectId):
    """ObjectId usable as a Pydantic field type; serializes to str."""

    @classmethod
    def __get_pydantic_core_schema__(cls, source: object, handler: GetCoreSchemaHandler) -> core_schema.CoreSchema:
        return core_schema.no_info_plain_validator_function(
            cls.validate,
            serialization=core_schema.to_string_ser_schema(),
        )

    @classmethod
    def validate(cls, value: object) -> ObjectId:
        if isinstance(value, ObjectId):
            return value
        return ObjectId(str(value))


class MongoDocument(BaseModel):
    """Base model for stored documents; maps ``id`` <-> ``_id``."""

    model_config = ConfigDict(populate_by_name=True)

    id: PyObjectId | None = Field(default=None, alias="_id")
