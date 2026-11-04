"""AI garbage classification: image model plus description fallback.

Image path: a MobileNetV3-Small fine-tuned on TACO crops merged into the
app's material types (see scripts/train_classifier.py). Weights load
lazily from AI_WEIGHTS_PATH; torch is imported on first use so the base
install (without the `ai` extra) still imports this module.
"""

import base64
import io
import threading
from pathlib import Path

from app.core.config import settings
from app.models.garbage import GarbageType
from app.schemas.ai import ClassifyRequest, ClassifyResponse
from app.services import ai_taxonomy

IMAGE_SIZE = 224
_IMAGENET_MEAN = (0.485, 0.456, 0.406)
_IMAGENET_STD = (0.229, 0.224, 0.225)


class WeightsMissingError(Exception):
    pass


class ModelLoadError(Exception):
    pass


class ImageDecodeError(Exception):
    pass


def build_model(num_classes: int, pretrained_backbone: bool = False):
    """MobileNetV3-Small with a fresh head. Shared by serving and the
    training script so the architecture cannot drift between them."""
    import torch
    from torchvision import models

    weights = (
        models.MobileNet_V3_Small_Weights.IMAGENET1K_V1
        if pretrained_backbone
        else None
    )
    model = models.mobilenet_v3_small(weights=weights)
    in_features = model.classifier[-1].in_features
    model.classifier[-1] = torch.nn.Linear(in_features, num_classes)
    return model


def inference_transform():
    """Eval preprocessing. The training script reuses this for val/test."""
    from torchvision import transforms

    return transforms.Compose(
        [
            transforms.Resize(256),
            transforms.CenterCrop(IMAGE_SIZE),
            transforms.ToTensor(),
            transforms.Normalize(_IMAGENET_MEAN, _IMAGENET_STD),
        ]
    )


class ImageClassifier:
    """Lazily loaded checkpoint classifier. The checkpoint is the bundle
    written by the training script: state_dict plus the ordered class
    names it was trained on."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._model = None
        self._classes: list[str] | None = None

    def reset(self) -> None:
        with self._lock:
            self._model = None
            self._classes = None

    @property
    def classes(self) -> list[str]:
        self._ensure_loaded()
        assert self._classes is not None
        return self._classes

    def _ensure_loaded(self) -> None:
        if self._model is not None:
            return
        with self._lock:
            if self._model is not None:
                return
            self._model, self._classes = _load_bundle()

    def predict(self, image) -> tuple[int, float]:
        """Top-1 (class index, softmax confidence) for a PIL image."""
        self._ensure_loaded()
        import torch
        batch = inference_transform()(image).unsqueeze(0)
        with torch.no_grad():
            probs = self._model(batch).softmax(1)[0]
        confidence, index = probs.max(0)
        return int(index), float(confidence)


def _load_bundle():
    weights = settings.ai_weights_path
    if not weights:
        raise WeightsMissingError(
            "classifier weights are not configured (set AI_WEIGHTS_PATH)"
        )
    path = Path(weights)
    if not path.is_file():
        raise WeightsMissingError(f"classifier weights not found: {weights}")
    try:
        import torch
    except ImportError as exc:
        raise ModelLoadError(
            "torch/torchvision are required (pip install garbagetrack[ai])"
        ) from exc
    try:
        bundle = torch.load(path, map_location="cpu", weights_only=True)
        classes = list(bundle["classes"])
        state = bundle["state_dict"]
    except Exception as exc:
        raise ModelLoadError(f"cannot read classifier bundle: {exc}") from exc
    valid = {t.value for t in GarbageType}
    if not classes or any(c not in valid for c in classes):
        raise ModelLoadError("bundle classes are not app garbage types")
    model = build_model(len(classes))
    try:
        model.load_state_dict(state)
    except Exception as exc:
        raise ModelLoadError(f"weights do not fit the model: {exc}") from exc
    model.eval()
    return model, classes


_classifier = ImageClassifier()


def classify(payload: ClassifyRequest) -> ClassifyResponse:
    if payload.image_base64 is not None:
        return classify_image(payload.image_base64)
    return classify_description(payload.description or "")


def classify_image(image_base64: str) -> ClassifyResponse:
    try:
        raw = base64.b64decode(image_base64, validate=True)
    except Exception as exc:
        raise ImageDecodeError("image is not valid base64") from exc
    try:
        from PIL import Image

        image = Image.open(io.BytesIO(raw)).convert("RGB")
    except ImportError as exc:
        raise ModelLoadError(
            "pillow is required (pip install garbagetrack[ai])"
        ) from exc
    except Exception as exc:
        raise ImageDecodeError("bytes are not a readable image") from exc
    index, confidence = _classifier.predict(image)
    app_type = GarbageType(_classifier.classes[index])
    return ClassifyResponse(
        suggested_types=[app_type],
        confidence=confidence,
        placeholder=False,
        message=f"Visual match: {app_type.value}.",
    )


def classify_description(description: str) -> ClassifyResponse:
    match = ai_taxonomy.match_description(description)
    if match is None:
        return ClassifyResponse(
            suggested_types=[GarbageType.GENERAL],
            confidence=0.0,
            placeholder=False,
            message="Could not tell from the description; send a photo "
            "for a visual match.",
        )
    app_type, keyword = match
    return ClassifyResponse(
        suggested_types=[app_type],
        confidence=ai_taxonomy.KEYWORD_CONFIDENCE,
        placeholder=False,
        message=f"Matched '{keyword}' in the description.",
    )
