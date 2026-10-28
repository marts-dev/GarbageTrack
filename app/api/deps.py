"""Shared API dependencies."""

from pymongo.asynchronous.database import AsyncDatabase

from app.core.database import get_database


def get_db() -> AsyncDatabase:
    return get_database()
