from fastapi import APIRouter

from app.api.v1.endpoints.ai import router as ai_router
from app.api.v1.endpoints.auth import router as auth_router
from app.api.v1.endpoints.depots import router as depots_router
from app.api.v1.endpoints.garbage import router as garbage_router
from app.api.v1.endpoints.health import router as health_router
from app.api.v1.endpoints.logistics import router as logistics_router
from app.api.v1.endpoints.trucks import router as trucks_router
from app.api.v1.endpoints.users import router as users_router

router = APIRouter()
router.include_router(auth_router)
router.include_router(health_router)
router.include_router(users_router)
router.include_router(garbage_router)
router.include_router(trucks_router)
router.include_router(ai_router)
router.include_router(logistics_router)
router.include_router(depots_router)
