"""Async MongoDB connection management using PyMongo's AsyncMongoClient."""

from pymongo import AsyncMongoClient
from pymongo.asynchronous.database import AsyncDatabase

from app.core.config import settings

_client: AsyncMongoClient | None = None


async def connect_to_mongo() -> AsyncMongoClient:
    """Create the shared async MongoDB client and verify connectivity."""
    global _client
    _client = AsyncMongoClient(settings.mongodb_uri)
    await _client.admin.command("ping")
    return _client


async def close_mongo_connection() -> None:
    """Close the shared async MongoDB client, if one exists."""
    global _client
    if _client is not None:
        await _client.close()
        _client = None


def get_client() -> AsyncMongoClient:
    """Return the shared client. Raises if the app is not connected."""
    if _client is None:
        raise RuntimeError("MongoDB client is not connected. Did the lifespan run?")
    return _client


def get_database() -> AsyncDatabase:
    """Return the application database handle."""
    return get_client()[settings.mongodb_db_name]
