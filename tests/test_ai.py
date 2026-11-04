import base64
import importlib.util
import io
import json
from pathlib import Path

import pytest
from PIL import Image

from app.core.config import settings
from app.models.garbage import GarbageType
from app.services import ai as ai_service
from app.services import ai_taxonomy


def _png_base64(color=(200, 30, 30)) -> str:
    buf = io.BytesIO()
    Image.new("RGB", (8, 8), color).save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


class _StubClassifier:
    def __init__(self, index: int = 0, confidence: float = 0.9):
        self.classes = [t.value for t in GarbageType]
        self._index = index
        self._confidence = confidence
        self.seen = []

    def predict(self, image):
        self.seen.append(image.size)
        return self._index, self._confidence


@pytest.fixture
def stub_classifier(monkeypatch):
    stub = _StubClassifier(
        index=list(GarbageType).index(GarbageType.PLASTIC), confidence=0.82
    )
    monkeypatch.setattr(ai_service, "_classifier", stub)
    return stub


def test_classify_description_matches_keywords(client, make_user):
    me = make_user()
    response = client.post(
        "/api/v1/ai/classify",
        json={"description": "old phone battery"},
        headers=me["headers"],
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["placeholder"] is False
    assert body["suggested_types"] == ["hazardous"]
    assert body["confidence"] == 0.6
    assert "battery" in body["message"]


def test_classify_description_without_match_falls_back(client, make_user):
    me = make_user()
    response = client.post(
        "/api/v1/ai/classify", json={"description": "mysterious blob"}, headers=me["headers"]
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["suggested_types"] == ["general"]
    assert body["confidence"] == 0.0
    assert body["placeholder"] is False


def test_classify_rejects_empty_description(client, make_user):
    me = make_user()
    response = client.post(
        "/api/v1/ai/classify", json={"description": ""}, headers=me["headers"]
    )
    assert response.status_code == 422


def test_classify_rejects_empty_body(client, make_user):
    me = make_user()
    response = client.post("/api/v1/ai/classify", json={}, headers=me["headers"])
    assert response.status_code == 422


def test_classify_requires_auth(client):
    assert client.post("/api/v1/ai/classify", json={"description": "x"}).status_code == 401


def test_classify_image_uses_model(client, make_user, stub_classifier):
    me = make_user()
    response = client.post(
        "/api/v1/ai/classify",
        json={"image_base64": _png_base64()},
        headers=me["headers"],
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["suggested_types"] == ["plastic"]
    assert body["confidence"] == 0.82
    assert body["placeholder"] is False
    assert stub_classifier.seen == [(8, 8)]


def test_classify_image_wins_over_description(client, make_user, stub_classifier):
    me = make_user()
    response = client.post(
        "/api/v1/ai/classify",
        json={"description": "old phone battery", "image_base64": _png_base64()},
        headers=me["headers"],
    )
    assert response.status_code == 200, response.text
    assert response.json()["suggested_types"] == ["plastic"]


def test_classify_rejects_unreadable_image(client, make_user, stub_classifier):
    me = make_user()
    response = client.post(
        "/api/v1/ai/classify",
        json={"image_base64": base64.b64encode(b"not-an-image").decode()},
        headers=me["headers"],
    )
    assert response.status_code == 422


def test_classify_missing_weights_is_503(client, make_user, monkeypatch):
    monkeypatch.setattr(settings, "ai_weights_path", None)
    ai_service._classifier.reset()
    me = make_user()
    response = client.post(
        "/api/v1/ai/classify",
        json={"image_base64": _png_base64()},
        headers=me["headers"],
    )
    assert response.status_code == 503
    assert "AI_WEIGHTS_PATH" in response.json()["detail"]


def test_taco_merge_covers_known_categories():
    assert ai_taxonomy.map_taco_category("Glass bottle", "Bottle") == GarbageType.GLASS
    assert ai_taxonomy.map_taco_category("Drink can", "Can") == GarbageType.METAL
    assert ai_taxonomy.map_taco_category("Aerosol", "Can") == GarbageType.HAZARDOUS
    assert ai_taxonomy.map_taco_category("Pizza box", "Carton") == GarbageType.PAPER
    assert ai_taxonomy.map_taco_category("Food waste", "Food waste") == GarbageType.ORGANIC
    assert ai_taxonomy.map_taco_category("Shoe", "Shoe") == GarbageType.TEXTILE
    assert ai_taxonomy.map_taco_category("Unlabeled litter", "Unlabeled litter") == (
        GarbageType.GENERAL
    )
    assert ai_taxonomy.map_taco_category("New thing", "New super") == GarbageType.GENERAL


def test_match_description_prefers_earlier_types():
    assert ai_taxonomy.match_description("glass bottle")[0] == GarbageType.GLASS
    assert ai_taxonomy.match_description("plastic bottle")[0] == GarbageType.PLASTIC
    # Whole words only: 'can' must not fire inside 'american'.
    assert ai_taxonomy.match_description("american flag") is None
    assert ai_taxonomy.match_description("tin can")[0] == GarbageType.METAL


def _train_module():
    path = Path(__file__).resolve().parents[1] / "scripts" / "train_classifier.py"
    spec = importlib.util.spec_from_file_location("train_classifier", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _coco_file(tmp_path):
    coco = {
        "images": [
            {"id": 1, "width": 100, "height": 100, "file_name": "a.jpg"},
            {"id": 2, "width": 100, "height": 100, "file_name": "b.jpg"},
        ],
        "annotations": [
            {"id": 1, "image_id": 1, "category_id": 6, "bbox": [10, 10, 40, 40]},
            {"id": 2, "image_id": 1, "category_id": 12, "bbox": [50, 50, 40, 40]},
            {"id": 3, "image_id": 2, "category_id": 99, "bbox": [10, 10, 40, 40]},
            {"id": 4, "image_id": 2, "category_id": 6, "bbox": [10, 10, 5, 5]},
        ],
        "categories": [
            {"id": 6, "name": "Glass bottle", "supercategory": "Bottle"},
            {"id": 12, "name": "Drink can", "supercategory": "Can"},
            {"id": 99, "name": "Mystery litter", "supercategory": "???"},
        ],
    }
    path = tmp_path / "annotations.json"
    path.write_text(json.dumps(coco))
    return path


def test_load_samples_merges_labels_and_reports_fallbacks(tmp_path):
    train = _train_module()
    samples, fallbacks, skipped_tiny = train.load_samples(
        _coco_file(tmp_path), tmp_path
    )
    assert [s["label"] for s in samples] == [3, 4, 8]
    assert samples[0]["box"] == (5.0, 5.0, 55.0, 55.0)
    assert fallbacks == {"Mystery litter": 1}
    assert skipped_tiny == 1


def test_split_by_image_keeps_crops_together(tmp_path):
    train = _train_module()
    samples, _, _ = train.load_samples(_coco_file(tmp_path), tmp_path)
    train_split, val_split = train.split_by_image(samples, 0.5, seed=7)
    train_ids = {s["image_id"] for s in train_split}
    val_ids = {s["image_id"] for s in val_split}
    assert train_ids.isdisjoint(val_ids)
    assert train_ids | val_ids == {1, 2}
    assert sorted([len(train_split), len(val_split)]) == [1, 2]
