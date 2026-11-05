import io
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import StreamingResponse

from app.api.deps import CurrentUser, Db, require_roles
from app.models.auth import Role
from app.schemas.ai import ClassifyRequest, ClassifyResponse
from app.schemas.auth import UserResponse
from app.services import ai as ai_service
from app.services import ai_export

router = APIRouter(prefix="/ai", tags=["ai"])

Admin = Annotated[UserResponse, Depends(require_roles(Role.ADMIN))]


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


@router.get("/training-export")
async def training_export(user: Admin, db: Db):
    # Admin-only: bulk resident photos leave the building here.
    _ = user
    payload, _ = await ai_export.build_training_export(db)
    day = datetime.now(UTC).date().isoformat()
    return StreamingResponse(
        io.BytesIO(payload),
        media_type="application/zip",
        headers={
            "Content-Disposition": (
                f"attachment; filename=garbagetrack-training-{day}.zip"
            )
        },
    )
