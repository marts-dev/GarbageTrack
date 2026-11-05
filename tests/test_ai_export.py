"""Phase 2 flywheel: per-report training consent + admin export."""

import base64
import io
import json
import zipfile

from bson import ObjectId
from PIL import Image

from app.models.garbage import GarbageType


def _png_base64(color=(30, 120, 30)) -> str:
    buf = io.BytesIO()
    Image.new("RGB", (8, 8), color).save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def _make_post(client, user, **overrides):
    payload = {
        "user_id": user["id"],
        "longitude": 3.371,
        "latitude": 6.451,
        "types": ["plastic"],
    }
    payload.update(overrides)
    response = client.post("/api/v1/garbage", json=payload, headers=user["headers"])
    assert response.status_code == 201, response.text
    return response.json()


def _collect_post(fake_db, post_id):
    fake_db["garbage_posts"].docs[ObjectId(post_id)]["status"] = "collected"


def _export(client, headers):
    response = client.get("/api/v1/ai/training-export", headers=headers)
    assert response.status_code == 200, response.text
    assert response.headers["content-type"] == "application/zip"
    disposition = response.headers["content-disposition"]
    assert disposition.startswith("attachment; filename=garbagetrack-training-")
    return zipfile.ZipFile(io.BytesIO(response.content))


def test_create_post_consent_defaults_off(client, make_user, fake_db):
    me = make_user()
    post = _make_post(client, me)
    assert post["training_consent"] is False
    stored = fake_db["garbage_posts"].docs[ObjectId(post["id"])]
    assert stored["training_consent"] is False


def test_create_post_records_consent(client, make_user):
    me = make_user()
    post = _make_post(
        client,
        me,
        image_base64=_png_base64(),
        image_content_type="image/png",
        training_consent=True,
    )
    assert post["training_consent"] is True
    assert post["has_image"] is True


def test_export_excludes_anything_unverified(client, make_user, fake_db):
    me = make_user()
    admin = make_user("admin")
    photo = {"image_base64": _png_base64(), "image_content_type": "image/png"}

    # Consented + photo, but never collected.
    _make_post(client, me, **photo, training_consent=True)
    # Collected + photo, but never consented.
    no_consent = _make_post(client, me, **photo)
    _collect_post(fake_db, no_consent["id"])
    # Consented + collected, but no photo.
    no_photo = _make_post(client, me, training_consent=True)
    _collect_post(fake_db, no_photo["id"])

    archive = _export(client, admin["headers"])
    manifest = json.loads(archive.read("manifest.json"))
    assert manifest["samples"] == []
    assert manifest["label_space"] == [t.value for t in GarbageType]
    assert archive.namelist() == ["manifest.json"]


def test_export_includes_verified_samples(client, make_user, fake_db):
    me = make_user()
    admin = make_user("admin")
    raw = _png_base64()
    post = _make_post(
        client,
        me,
        types=["plastic", "paper"],
        image_base64=raw,
        image_content_type="image/png",
        training_consent=True,
    )
    _collect_post(fake_db, post["id"])

    archive = _export(client, admin["headers"])
    manifest = json.loads(archive.read("manifest.json"))
    space = [t.value for t in GarbageType]
    assert manifest["label_space"] == space
    # One sample per (photo, type) pair, sharing one image_id.
    assert manifest["samples"] == [
        {
            "image_id": post["id"],
            "file": f"images/{post['id']}.png",
            "label": "plastic",
            "label_index": space.index("plastic"),
        },
        {
            "image_id": post["id"],
            "file": f"images/{post['id']}.png",
            "label": "paper",
            "label_index": space.index("paper"),
        },
    ]
    assert archive.read(f"images/{post['id']}.png") == base64.b64decode(raw)


def test_export_forbidden_for_non_admin(client, make_user):
    me = make_user()
    staff = make_user("logistics")
    assert (
        client.get("/api/v1/ai/training-export", headers=me["headers"]).status_code
        == 403
    )
    assert (
        client.get("/api/v1/ai/training-export", headers=staff["headers"]).status_code
        == 403
    )
