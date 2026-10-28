from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api.v1.router import router as api_v1_router
from app.core.config import settings
from app.core.database import close_mongo_connection, connect_to_mongo, ensure_indexes


@asynccontextmanager
async def lifespan(app: FastAPI):
    client = await connect_to_mongo()
    await ensure_indexes(client[settings.mongodb_db_name])
    yield
    await close_mongo_connection()


app = FastAPI(title=settings.app_name, debug=settings.debug, lifespan=lifespan)
app.include_router(api_v1_router, prefix=settings.api_v1_prefix)
