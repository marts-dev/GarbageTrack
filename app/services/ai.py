"""AI garbage classification (placeholder until the agent is wired up)."""

from app.models.garbage import GarbageType
from app.schemas.ai import ClassifyRequest, ClassifyResponse


async def classify_placeholder(payload: ClassifyRequest) -> ClassifyResponse:
    _ = payload
    return ClassifyResponse(
        suggested_types=[GarbageType.GENERAL],
        confidence=0.0,
        placeholder=True,
        message="AI classification is not wired up yet; defaulting to 'general'.",
    )
