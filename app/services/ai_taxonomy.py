"""Category mappings for AI classification.

TACO_TO_APP merges TACO's 60 litter categories (names and supercategories
taken verbatim from the dataset's annotations.json) into the app's material
types. Unknown names fall back to GENERAL so a dataset update can never
break training or serving; the training report lists every fallback for
review.

Note: TACO contains no e-waste, so the image model cannot learn ELECTRONIC
from TACO alone — that gap is for resident photos (Phase 2) and the
description matcher below.
"""

from app.models.garbage import GarbageType

# Supercategories whose every category shares one material.
_SUPER_TO_APP: dict[str, GarbageType] = {
    "Aluminium foil": GarbageType.METAL,
    "Battery": GarbageType.HAZARDOUS,
    "Broken glass": GarbageType.GLASS,
    "Carton": GarbageType.PAPER,
    "Cigarette": GarbageType.GENERAL,
    "Food waste": GarbageType.ORGANIC,
    "Glass jar": GarbageType.GLASS,
    "Other plastic": GarbageType.PLASTIC,
    "Paper": GarbageType.PAPER,
    "Plastic bag & wrapper": GarbageType.PLASTIC,
    "Plastic container": GarbageType.PLASTIC,
    "Plastic glooves": GarbageType.PLASTIC,
    "Plastic utensils": GarbageType.PLASTIC,
    "Pop tab": GarbageType.METAL,
    "Rope & strings": GarbageType.TEXTILE,
    "Scrap metal": GarbageType.METAL,
    "Shoe": GarbageType.TEXTILE,
    "Squeezable tube": GarbageType.PLASTIC,
    "Styrofoam piece": GarbageType.PLASTIC,
    "Unlabeled litter": GarbageType.GENERAL,
}

# Mixed-material supercategories, mapped per category name.
_NAME_TO_APP: dict[str, GarbageType] = {
    # Blister pack: mixed aluminium/plastic.
    "Aluminium blister pack": GarbageType.GENERAL,
    "Carded blister pack": GarbageType.GENERAL,
    # Bottle / Lid / Straw split by material.
    "Other plastic bottle": GarbageType.PLASTIC,
    "Clear plastic bottle": GarbageType.PLASTIC,
    "Glass bottle": GarbageType.GLASS,
    "Plastic bottle cap": GarbageType.PLASTIC,
    "Metal bottle cap": GarbageType.METAL,
    "Plastic lid": GarbageType.PLASTIC,
    "Metal lid": GarbageType.METAL,
    "Plastic straw": GarbageType.PLASTIC,
    "Paper straw": GarbageType.PAPER,
    # Cans: pressurised aerosols are hazardous, the rest metal.
    "Food Can": GarbageType.METAL,
    "Aerosol": GarbageType.HAZARDOUS,
    "Drink can": GarbageType.METAL,
    # Cups split by material (foam is polystyrene).
    "Paper cup": GarbageType.PAPER,
    "Disposable plastic cup": GarbageType.PLASTIC,
    "Foam cup": GarbageType.PLASTIC,
    "Glass cup": GarbageType.GLASS,
    "Other plastic cup": GarbageType.PLASTIC,
    # Paper bags stay paper (coating included).
    "Paper bag": GarbageType.PAPER,
    "Plastified paper bag": GarbageType.PAPER,
}


def is_known_taco_category(name: str, supercategory: str) -> bool:
    """True when (name, supercategory) hits the merge table exactly, so
    the training report can list dataset categories that fell back to
    GENERAL instead of a curated mapping."""
    if name in _NAME_TO_APP or supercategory in _SUPER_TO_APP:
        return True
    lowered = name.strip().lower()
    return any(k.lower() == lowered for k in _NAME_TO_APP) or any(
        k.lower() == lowered for k in _SUPER_TO_APP
    )


def map_taco_category(name: str, supercategory: str) -> GarbageType:
    """Merge one TACO category into an app material type.

    Exact name first (mixed supercategories), then the uniform
    supercategory map, then a case-insensitive retry — else GENERAL.
    """
    if name in _NAME_TO_APP:
        return _NAME_TO_APP[name]
    if supercategory in _SUPER_TO_APP:
        return _SUPER_TO_APP[supercategory]
    lowered = name.strip().lower()
    for key, app_type in _NAME_TO_APP.items():
        if key.lower() == lowered:
            return app_type
    for key, app_type in _SUPER_TO_APP.items():
        if key.lower() == lowered:
            return app_type
    return GarbageType.GENERAL


# Description keywords per type, in match priority: whole-word hits on an
# earlier type win over later ones (so 'glass bottle' lands on glass, not
# plastic). GENERAL has no keywords — it is the explicit no-match result.
DESCRIPTION_KEYWORDS: tuple[tuple[GarbageType, tuple[str, ...]], ...] = (
    # Hazardous first: danger words are more specific than device words, so
    # 'phone battery' lands on the battery, not the phone.
    (
        GarbageType.HAZARDOUS,
        (
            "battery", "batteries", "paint", "chemical", "pesticide",
            "fluorescent", "aerosol", "spray can", "motor oil", "fuel",
            "thinner", "bleach", "acid", "medicine", "syringe", "needle",
            "bulb",
        ),
    ),
    (
        GarbageType.ELECTRONIC,
        (
            "phone", "laptop", "computer", "tablet", "charger", "cable",
            "earphone", "headphone", "speaker", "camera", "television",
            "monitor", "keyboard", "mouse", "printer", "appliance",
            "gadget", "device", "circuit", "remote",
        ),
    ),
    (
        GarbageType.GLASS,
        ("glass", "mirror", "window", "windshield"),
    ),
    (
        GarbageType.METAL,
        (
            "metal", "can", "tin", "aluminium", "aluminum", "foil",
            "steel", "iron", "scrap", "wire", "nail", "screw",
        ),
    ),
    (
        GarbageType.PAPER,
        (
            "paper", "newspaper", "magazine", "carton", "cardboard",
            "box", "book", "tissue", "napkin", "receipt", "envelope",
        ),
    ),
    (
        GarbageType.TEXTILE,
        (
            "cloth", "clothes", "clothing", "shirt", "pants", "dress",
            "textile", "fabric", "shoe", "slipper", "sandal", "sock",
            "towel", "curtain", "pillow",
        ),
    ),
    (
        GarbageType.ORGANIC,
        (
            "food", "leftover", "peel", "fruit", "vegetable", "leaf",
            "leaves", "garden", "grass", "compost", "bone", "fish",
            "meat", "rice", "bread", "egg",
        ),
    ),
    (
        GarbageType.PLASTIC,
        (
            "plastic", "bottle", "bag", "wrapper", "packaging", "sachet",
            "pouch", "container", "straw", "lid", "cap", "foam",
            "styro", "cellophane", "disposable", "utensil", "glove",
            "cup", "tube",
        ),
    ),
)

# Fixed confidence for a keyword hit: better than a guess, weaker than a
# visual match.
KEYWORD_CONFIDENCE = 0.6


def match_description(text: str) -> tuple[GarbageType, str] | None:
    """First (type, keyword) whose whole-word keyword appears in [text].

    Types are tried in DESCRIPTION_KEYWORDS priority order, longer phrases
    first, so 'glass bottle' matches glass ('glass') before plastic could
    claim 'bottle', and 'can' never fires inside 'american'.
    """
    words = text.lower().replace("-", " ").split()
    padded = f" {' '.join(words)} "
    for app_type, keywords in DESCRIPTION_KEYWORDS:
        for keyword in sorted(keywords, key=len, reverse=True):
            if f" {keyword} " in padded:
                return app_type, keyword
    return None
