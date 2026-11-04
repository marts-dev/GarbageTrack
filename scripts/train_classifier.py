"""Train the garbage photo classifier: MobileNetV3-Small on TACO crops.

Merges TACO's 60 litter categories into the app's material types (see
app/services/ai_taxonomy.py), crops each annotation box with context
margin, and fine-tunes the classifier head (backbone frozen by default).
Saves the bundle the API loads via AI_WEIGHTS_PATH.

Dataset (CC BY 4.0, cite Proenca & Simoes 2020 + the DOI below):
    1. Download TACO.zip from https://doi.org/10.5281/zenodo.3587843 (~2.7 GB)
    2. Unzip so that annotations.json sits next to the image batches:
           data/taco/annotations.json
           data/taco/batch_1/*.jpg ...

Usage (needs the ai extra):
    uv run --extra ai python scripts/train_classifier.py --data-dir data/taco --out var/ai/classifier.pt
    uv run --extra ai python scripts/train_classifier.py --data-dir data/taco --out /tmp/smoke.pt --limit 200 --epochs 1

Expect ~10k crops; head-only training runs on CPU in well under an hour.
"""

import argparse
import json
import random
import sys
import time
from collections import Counter
from datetime import UTC, datetime
from functools import lru_cache
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.models.garbage import GarbageType
from app.services import ai as ai_service
from app.services import ai_taxonomy

TACO_ZENODO_URL = "https://doi.org/10.5281/zenodo.3587843"
TAXONOMY_VERSION = "taco-merged-v1"
CLASSES = [t.value for t in GarbageType]
BOX_MARGIN = 0.25
MIN_BOX_SIDE = 32


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--data-dir", required=True, help="TACO root with annotations.json")
    parser.add_argument("--annotations", default=None, help="annotations file (default: data-dir/annotations.json)")
    parser.add_argument("--out", required=True, help="where to write the .pt bundle")
    parser.add_argument("--epochs", type=int, default=10)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--val-fraction", type=float, default=0.15)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--limit", type=int, default=0, help="cap total crops (smoke tests)")
    parser.add_argument("--unfreeze", action="store_true", help="fine-tune the backbone too")
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "cuda", "mps"))
    parser.add_argument("--num-workers", type=int, default=0)
    parser.add_argument("--report", default=None, help="also write the JSON report here")
    return parser.parse_args(argv)


def pick_device(name):
    import torch

    if name != "auto":
        return torch.device(name)
    if torch.cuda.is_available():
        return torch.device("cuda")
    mps = getattr(torch.backends, "mps", None)
    if mps is not None and mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def load_samples(ann_path, images_dir, limit=0):
    """(samples, fallback_names, skipped_tiny) from a COCO annotations file.

    One sample per annotation: image path, square crop box with context
    margin, merged label index. Boxes are clamped into the image; tiny
    boxes are skipped; unmapped categories fall back to GENERAL and are
    reported by name.
    """
    with open(ann_path) as handle:
        coco = json.load(handle)
    cat_by_id = {c["id"]: (c["name"], c.get("supercategory") or "") for c in coco["categories"]}
    img_by_id = {img["id"]: img for img in coco["images"]}
    samples = []
    fallbacks = Counter()
    skipped_tiny = 0
    for ann in coco["annotations"]:
        name, super_name = cat_by_id[ann["category_id"]]
        label = ai_taxonomy.map_taco_category(name, super_name)
        if not ai_taxonomy.is_known_taco_category(name, super_name):
            fallbacks[name] += 1
        x, y, w, h = (float(v) for v in ann["bbox"])
        side = max(w, h) * (1.0 + BOX_MARGIN)
        if MIN_BOX_SIDE > min(w, h):
            skipped_tiny += 1
            continue
        img = img_by_id[ann["image_id"]]
        iw, ih = float(img["width"]), float(img["height"])
        cx, cy = x + w / 2.0, y + h / 2.0
        half = side / 2.0
        left = min(max(cx - half, 0.0), max(iw - side, 0.0))
        top = min(max(cy - half, 0.0), max(ih - side, 0.0))
        samples.append(
            {
                "image_id": ann["image_id"],
                "path": str(Path(images_dir) / img["file_name"]),
                "box": (left, top, min(left + side, iw), min(top + side, ih)),
                "label": CLASSES.index(label.value),
            }
        )
        if 0 < limit and len(samples) >= limit:
            break
    return samples, dict(fallbacks), skipped_tiny


def split_by_image(samples, val_fraction, seed):
    """Train/val split grouped by image id: two crops of one photo never
    land on opposite sides, which would leak validation signal."""
    by_image = {}
    for sample in samples:
        by_image.setdefault(sample["image_id"], []).append(sample)
    ids = sorted(by_image)
    rng = random.Random(seed)
    rng.shuffle(ids)
    cut = max(int(len(ids) * val_fraction), 1) if len(ids) > 1 else 0
    val_ids = set(ids[:cut])
    train = [s for s in samples if s["image_id"] not in val_ids]
    val = [s for s in samples if s["image_id"] in val_ids]
    return train, val


@lru_cache(maxsize=256)
def _open_image(path):
    from PIL import Image

    with Image.open(path) as handle:
        return handle.convert("RGB")


def train_transform():
    from torchvision import transforms

    return transforms.Compose(
        [
            transforms.RandomResizedCrop(ai_service.IMAGE_SIZE, scale=(0.5, 1.0)),
            transforms.RandomHorizontalFlip(),
            transforms.ColorJitter(0.2, 0.2, 0.2),
            transforms.ToTensor(),
            transforms.Normalize((0.485, 0.456, 0.406), (0.229, 0.224, 0.225)),
        ]
    )


class CropDataset:
    def __init__(self, samples, transform):
        self.samples = samples
        self.transform = transform

    def __len__(self):
        return len(self.samples)

    def __getitem__(self, index):
        sample = self.samples[index]
        image = _open_image(sample["path"]).crop(sample["box"])
        return self.transform(image), sample["label"]


def make_loaders(train, val, batch_size, num_workers, seed):
    import torch
    from torch.utils.data import DataLoader, WeightedRandomSampler

    counts = Counter(s["label"] for s in train)
    weights = [1.0 / counts[s["label"]] for s in train]
    sampler = WeightedRandomSampler(
        weights, num_samples=len(weights), replacement=True,
        generator=torch.Generator().manual_seed(seed),
    )
    train_loader = DataLoader(
        CropDataset(train, train_transform()),
        batch_size=batch_size,
        sampler=sampler,
        num_workers=num_workers,
    )
    val_loader = DataLoader(
        CropDataset(val, ai_service.inference_transform()),
        batch_size=batch_size,
        num_workers=num_workers,
    )
    return train_loader, val_loader


def run_epoch(model, loader, device, optimizer=None):
    import torch

    training = optimizer is not None
    model.train(training)
    loss_fn = torch.nn.CrossEntropyLoss()
    total_loss, correct, total = 0.0, 0, 0
    context = torch.enable_grad() if training else torch.no_grad()
    with context:
        for images, labels in loader:
            images, labels = images.to(device), labels.to(device)
            outputs = model(images)
            loss = loss_fn(outputs, labels)
            if training:
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()
            total_loss += float(loss) * len(images)
            correct += int((outputs.argmax(1) == labels).sum())
            total += len(images)
    return total_loss / max(total, 1), correct / max(total, 1)


def per_class_accuracy(model, loader, device, num_classes):
    import torch

    model.eval()
    correct = [0] * num_classes
    total = [0] * num_classes
    with torch.no_grad():
        for images, labels in loader:
            images = images.to(device)
            preds = model(images).argmax(1).cpu().tolist()
            for pred, label in zip(preds, labels.tolist()):
                total[label] += 1
                if pred == label:
                    correct[label] += 1
    return {
        CLASSES[i]: (correct[i] / total[i] if total[i] else None)
        for i in range(num_classes)
    }


def main(argv=None) -> int:
    args = parse_args(argv)
    try:
        import torch
    except ImportError:
        print("torch is required: pip install garbagetrack[ai]", file=sys.stderr)
        return 2
    data_dir = Path(args.data_dir)
    ann_path = Path(args.annotations) if args.annotations else data_dir / "annotations.json"
    if not ann_path.is_file():
        print(
            f"annotations not found: {ann_path}\n"
            f"Download TACO.zip from {TACO_ZENODO_URL} (~2.7 GB), unzip it, and\n"
            "point --data-dir at the folder holding annotations.json.",
            file=sys.stderr,
        )
        return 2
    started = time.time()
    samples, fallbacks, skipped_tiny = load_samples(
        ann_path, data_dir, limit=args.limit
    )
    if not samples:
        print("no usable crops found", file=sys.stderr)
        return 2
    train, val = split_by_image(samples, args.val_fraction, args.seed)
    device = pick_device(args.device)
    print(
        f"crops: {len(samples)} (train {len(train)}, val {len(val)}, "
        f"tiny skipped {skipped_tiny}) on {device}"
    )
    counts = Counter(CLASSES[s["label"]] for s in samples)
    print("per-class crops:", dict(counts))
    if fallbacks:
        print("TACO names without a curated mapping (fell back to general):")
        for name in sorted(fallbacks):
            print(f"  {name}: {fallbacks[name]}")
    missing = [c for c in CLASSES if not counts.get(c)]
    if missing:
        print(f"no crops for: {', '.join(missing)} (the model cannot learn these)")

    model = ai_service.build_model(len(CLASSES), pretrained_backbone=True)
    if args.unfreeze:
        head_params = list(model.classifier.parameters())
        head_ids = {id(p) for p in head_params}
        base_params = [p for p in model.parameters() if id(p) not in head_ids]
        optimizer = torch.optim.AdamW(
            [{"params": base_params, "lr": args.lr / 10.0}, {"params": head_params, "lr": args.lr}]
        )
    else:
        for name, param in model.named_parameters():
            param.requires_grad = name.startswith("classifier")
        optimizer = torch.optim.AdamW(model.classifier.parameters(), lr=args.lr)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, args.epochs)
    train_loader, val_loader = make_loaders(train, val, args.batch_size, args.num_workers, args.seed)
    model.to(device)

    best_acc, best_state = -1.0, None
    for epoch in range(args.epochs):
        train_loss, train_acc = run_epoch(model, train_loader, device, optimizer)
        _, val_acc = run_epoch(model, val_loader, device)
        scheduler.step()
        print(
            f"epoch {epoch + 1}/{args.epochs} "
            f"train loss {train_loss:.4f} acc {train_acc:.3f} | val acc {val_acc:.3f}"
        )
        if val_acc > best_acc:
            best_acc = val_acc
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
    model.load_state_dict(best_state)
    class_acc = per_class_accuracy(model, val_loader, device, len(CLASSES))
    print(f"best val accuracy: {best_acc:.3f} ({time.time() - started:.0f}s)")
    print("per-class val accuracy:", {k: (None if v is None else round(v, 3)) for k, v in class_acc.items()})

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "state_dict": best_state,
            "classes": CLASSES,
            "taxonomy": TAXONOMY_VERSION,
            "val_accuracy": best_acc,
            "per_class_accuracy": class_acc,
            "class_counts": dict(counts),
            "taco_fallbacks": fallbacks,
            "image_size": ai_service.IMAGE_SIZE,
            "trained_at": datetime.now(UTC).isoformat(),
        },
        out,
    )
    print(f"saved {out}")
    if args.report:
        report = Path(args.report)
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text(
            json.dumps(
                {
                    "val_accuracy": best_acc,
                    "per_class_accuracy": class_acc,
                    "class_counts": dict(counts),
                    "taco_fallbacks": fallbacks,
                    "crops": len(samples),
                    "epochs": args.epochs,
                },
                indent=2,
            )
        )
        print(f"wrote {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
