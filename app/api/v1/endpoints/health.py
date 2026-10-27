from fastapi import APIRouter
from pymongo.errors import PyMongoError

from app.core import database

router = APIRouter(tags=["health"])


@router.get("/health")
async def health_check() -> dict:
    """Liveness probe. Reports MongoDB reachability without failing when it is down."""
    try:
        await database.get_client().admin.command("ping")
        db_status = "up"
    except (RuntimeError, PyMongoError):
        db_status = "down"
    return {"status": "ok", "database": db_status}


@router.get("/health/db")
async def db_health_check() -> dict:
    """Readiness probe backed by an actual MongoDB ping."""
    await database.get_database().command("ping")
    return {"status": "ok", "database": "up"}
