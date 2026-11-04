from fastapi import APIRouter, HTTPException, status

from app.api.deps import CurrentUser
from app.schemas.ai import ClassifyRequest, ClassifyResponse
from app.services import ai as ai_service

router = APIRouter(prefix="/ai", tags=["ai"])


@router.post("/classify", response_model=ClassifyResponse)
def classify(payload: ClassifyRequest, user: CurrentUser):
    # Sync endpoint: inference is CPU-bound with no awaits, so FastAPI runs
    # it in a worker thread instead of blocking the event loop.
    _ = user
    try:
        return ai_service.classify(payload)
    except ai_service.WeightsMissingError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)
        ) from None
    except ai_service.ModelLoadError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)
        ) from None
    except ai_service.ImageDecodeError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail=str(exc)
        ) from None
