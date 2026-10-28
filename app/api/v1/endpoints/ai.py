from fastapi import APIRouter

from app.schemas.ai import ClassifyRequest, ClassifyResponse
from app.services import ai as ai_service

router = APIRouter(prefix="/ai", tags=["ai"])


@router.post("/classify", response_model=ClassifyResponse)
async def classify(payload: ClassifyRequest):
    return await ai_service.classify_placeholder(payload)
