"""Region boundaries for per-region garbage aggregation.

Each supported country ships one simplified ADM1 GeoJSON under app/data/.
Adding a country is: drop in `<code>_regions.geojson` next to the others
(features with `properties.name` and Polygon/MultiPolygon geometry) and
register it in [REGION_BOUNDARIES].
"""

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# Lowercase country name -> boundary file. Keys must match the normalized
# `country` users register with.
REGION_BOUNDARIES = {
    "philippines": "ph_regions.geojson",
}


@dataclass(frozen=True)
class RegionBoundary:
    name: str
    min_lon: float
    min_lat: float
    max_lon: float
    max_lat: float
    # Tuple of polygons; each polygon is a tuple of rings; each ring is a
    # tuple of (lon, lat) points.
    polygons: tuple


def _point_in_ring(lon: float, lat: float, ring: tuple) -> bool:
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def region_for_point(
    longitude: float, latitude: float, regions: list[RegionBoundary]
) -> str | None:
    """Name of the region containing the point, or None when outside all."""
    for region in regions:
        if not (
            region.min_lon <= longitude <= region.max_lon
            and region.min_lat <= latitude <= region.max_lat
        ):
            continue
        for polygon in region.polygons:
            if not _point_in_ring(longitude, latitude, polygon[0]):
                continue
            if any(_point_in_ring(longitude, latitude, hole) for hole in polygon[1:]):
                continue
            return region.name
    return None


@lru_cache(maxsize=8)
def load_regions(country: str) -> list[RegionBoundary]:
    """Boundaries for a country (case-insensitive); [] when unsupported."""
    filename = REGION_BOUNDARIES.get(country.strip().lower())
    if filename is None:
        return []
    with open(DATA_DIR / filename, encoding="utf-8") as handle:
        collection = json.load(handle)
    regions = []
    for feature in collection.get("features", []):
        geometry = feature["geometry"]
        coords = geometry["coordinates"]
        polys = [coords] if geometry["type"] == "Polygon" else coords
        polygons = tuple(
            tuple(tuple((float(x), float(y)) for x, y in ring) for ring in poly)
            for poly in polys
        )
        lons = [x for poly in polygons for ring in poly for x, _ in ring]
        lats = [y for poly in polygons for ring in poly for _, y in ring]
        regions.append(
            RegionBoundary(
                name=str(feature["properties"]["name"]),
                min_lon=min(lons),
                min_lat=min(lats),
                max_lon=max(lons),
                max_lat=max(lats),
                polygons=polygons,
            )
        )
    return regions


def doc_in_country(doc: dict, regions: list[RegionBoundary]) -> bool:
    """True when the post's location falls inside any of the regions."""
    location = doc.get("location") or {}
    coords = location.get("coordinates") or [None, None]
    if coords[0] is None or coords[1] is None:
        return False
    return (
        region_for_point(float(coords[0]), float(coords[1]), regions) is not None
    )


def aggregate_by_region(posts: list[dict], country: str) -> dict:
    """Per-region totals for posts falling inside the country's regions.

    Returns {region_name: {"total": n, "by_status": {}, "by_type": {}}}.
    Posts outside every region (e.g. other countries) are ignored.
    """
    regions = load_regions(country)
    if not regions:
        return {}
    summary: dict[str, dict] = {}
    for doc in posts:
        location = doc.get("location") or {}
        coords = location.get("coordinates") or [None, None]
        if coords[0] is None or coords[1] is None:
            continue
        name = region_for_point(float(coords[0]), float(coords[1]), regions)
        if name is None:
            continue
        bucket = summary.setdefault(name, {"total": 0, "by_status": {}, "by_type": {}})
        bucket["total"] += 1
        status = str(doc.get("status"))
        bucket["by_status"][status] = bucket["by_status"].get(status, 0) + 1
        for garbage_type in doc.get("types", []):
            type_name = str(garbage_type)
            bucket["by_type"][type_name] = bucket["by_type"].get(type_name, 0) + 1
    return summary
