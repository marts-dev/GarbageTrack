"""Phase 2 training export: consented resident photos as a training bundle.

A post only qualifies when it is opted in, carries a photo, and reached
collected — collection plus resident confirmation is the label
verification, so the export never trains on unverified guesses.

Emits a zip with ``images/<post_id>.<ext>`` plus a ``manifest.json``
pinning the label space the indices refer to. One manifest entry per
(photo, type) pair; entries sharing an ``image_id`` stay on the same
train/val side. Consumed by ``scripts/train_classifier.py
--extra-manifest``.
"""

import base64
import binascii
import io
import json
import zipfile
from datetime import UTC, datetime

from app.models import garbage as garbage_model
from app.models.garbage import GarbageStatus, GarbageType

LABEL_SPACE = [t.value for t in GarbageType]


def _extension(content_type: str | None, raw: bytes) -> str:
    if content_type == "image/png" or raw[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if content_type == "image/jpeg" or raw[:2] == b"\xff\xd8":
        return "jpg"
    if content_type == "image/webp" or raw[:4] == b"RIFF":
        return "webp"
    return "bin"


async def build_training_export(db) -> tuple[bytes, int]:
    """Build the export zip; returns (zip bytes, sample count)."""
    cursor = db[garbage_model.COLLECTION].find(
        {
            "status": GarbageStatus.COLLECTED.value,
            "training_consent": True,
        }
    )
    samples: list[dict] = []
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as archive:
        async for doc in cursor:
            encoded = doc.get("image_base64")
            if not encoded:
                continue
            try:
                raw = base64.b64decode(encoded, validate=True)
            except (binascii.Error, ValueError):
                continue
            if not raw:
                continue
            post_id = str(doc["_id"])
            name = (
                f"images/{post_id}."
                f"{_extension(doc.get('image_content_type'), raw)}"
            )
            archive.writestr(name, raw)
            for label in [str(t) for t in doc.get("types", [])]:
                if label not in LABEL_SPACE:
                    continue
                samples.append(
                    {
                        "image_id": post_id,
                        "file": name,
                        "label": label,
                        "label_index": LABEL_SPACE.index(label),
                    }
                )
        manifest = {
            "exported_on": datetime.now(UTC).date().isoformat(),
            "label_space": LABEL_SPACE,
            "samples": samples,
        }
        archive.writestr("manifest.json", json.dumps(manifest, indent=2))
    return buf.getvalue(), len(samples)
