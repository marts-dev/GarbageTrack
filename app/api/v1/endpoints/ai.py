from fastapi import APIRouter

from app.api.deps import CurrentUser
from app.schemas.ai import ClassifyRequest, ClassifyResponse
from app.services import ai as ai_service

router = APIRouter(prefix="/ai", tags=["ai"])


@router.post("/classify", response_model=ClassifyResponse)
async def classify(payload: ClassifyRequest, user: CurrentUser):
    _ = user
    return await ai_service.classify_placeholder(payload)
