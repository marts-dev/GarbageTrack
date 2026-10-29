from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.router import router as api_v1_router
from app.core.config import settings
from app.core.database import close_mongo_connection, connect_to_mongo, ensure_indexes
from app.services.auth import ensure_default_admin


@asynccontextmanager
async def lifespan(app: FastAPI):
    client = await connect_to_mongo()
    db = client[settings.mongodb_db_name]
    await ensure_indexes(db)
    await ensure_default_admin(db)
    yield
    await close_mongo_connection()


app = FastAPI(title=settings.app_name, debug=settings.debug, lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(api_v1_router, prefix=settings.api_v1_prefix)
