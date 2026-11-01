"""Road-following route geometry with straight-line fallback.

Resolution order: self-hosted OSRM (when ``osrm_base_url`` is set), then
OSMnx (OPTIONAL ``routing`` extra, never imported at module import time),
then a straight polyline. Every failure — unreachable server, missing
extra, download error, cache error, or unroutable leg — falls back to a
straight polyline and never raises for routing unavailability.
"""

from __future__ import annotations

import json
import logging
import math
import urllib.request
from collections import OrderedDict
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

from app.core.config import settings
from app.models.geo import GeoPoint

EARTH_RADIUS_METERS = 6378100
_GRAPH_CACHE_SIZE = 4
_BBOX_PAD_DEGREES = 0.01

_graph_cache: OrderedDict[str, Any] = OrderedDict()


@dataclass
class RouteGeometry:
    points: list[tuple[float, float]]
    distance_meters: float
    fallback: bool


def haversine_meters(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
    dlon = math.radians(lon2 - lon1)
    dlat = math.radians(lat2 - lat1)
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2) ** 2
    )
    return 2 * EARTH_RADIUS_METERS * math.asin(math.sqrt(a))


def straight_distance(points: Sequence[tuple[float, float]]) -> float:
    return sum(
        haversine_meters(points[i][0], points[i][1], points[i + 1][0], points[i + 1][1])
        for i in range(len(points) - 1)
    )


def straight_route(points: Sequence[tuple[float, float]]) -> RouteGeometry:
    pts = list(points)
    distance = straight_distance(pts) if len(pts) >= 2 else 0.0
    return RouteGeometry(points=pts, distance_meters=distance, fallback=True)


def bbox_for_points(
    points: Sequence[tuple[float, float]], pad: float = _BBOX_PAD_DEGREES
) -> tuple[float, float, float, float]:
    lons = [p[0] for p in points]
    lats = [p[1] for p in points]
    left = max(-180.0, min(lons) - pad)
    right = min(180.0, max(lons) + pad)
    bottom = max(-90.0, min(lats) - pad)
    top = min(90.0, max(lats) + pad)
    if left >= right:
        right = min(180.0, left + pad)
    if bottom >= top:
        top = min(90.0, bottom + pad)
    return (left, bottom, right, top)


def area_key(left: float, bottom: float, right: float, top: float) -> str:
    base = f"drive_{left:.4f}_{bottom:.4f}_{right:.4f}_{top:.4f}"
    return base.replace("-", "m").replace(".", "p") + ".graphml"


def cache_path_for_bbox(
    left: float, bottom: float, right: float, top: float, cache_dir: str | None = None
) -> Path:
    base = Path(cache_dir or settings.routing_cache_dir)
    return base / area_key(left, bottom, right, top)


def as_lonlat_list(points: Sequence[Any]) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    for p in points:
        if isinstance(p, GeoPoint):
            out.append((p.longitude, p.latitude))
        elif isinstance(p, dict):
            coords = p.get("coordinates", [0, 0])
            out.append((float(coords[0]), float(coords[1])))
        elif isinstance(p, (list, tuple)) and len(p) == 2:
            out.append((float(p[0]), float(p[1])))
        else:
            lon = getattr(p, "longitude", None)
            lat = getattr(p, "latitude", None)
            if lon is not None and lat is not None:
                out.append((float(lon), float(lat)))
            else:
                raise ValueError(f"unsupported route point: {p!r}")
    return out


def _remember_graph(key: str, graph: Any) -> None:
    _graph_cache[key] = graph
    _graph_cache.move_to_end(key)
    while len(_graph_cache) > _GRAPH_CACHE_SIZE:
        _graph_cache.popitem(last=False)


def _load_or_download_graph(
    bbox: tuple[float, float, float, float],
    cache_path: Path,
    network_type: str,
    timeout_s: float,
) -> Any:
    """Load the cached street network or download it once. Raises on failure."""
    import osmnx as ox  # lazy: optional dependency

    key = cache_path.name
    if key in _graph_cache:
        _graph_cache.move_to_end(key)
        return _graph_cache[key]

    if cache_path.exists():
        try:
            graph = ox.io.load_graphml(filepath=str(cache_path))
            _remember_graph(key, graph)
            return graph
        except Exception:  # noqa: BLE001, S110
            pass

    old_timeout = ox.settings.requests_timeout
    old_use_cache = ox.settings.use_cache
    try:
        ox.settings.requests_timeout = timeout_s
        ox.settings.use_cache = False
        graph = ox.graph.graph_from_bbox(
            bbox, network_type=network_type, simplify=True, retain_all=False
        )
    finally:
        ox.settings.requests_timeout = old_timeout
        ox.settings.use_cache = old_use_cache
    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        ox.io.save_graphml(graph, filepath=str(cache_path))
    except Exception:  # noqa: BLE001, S110
        pass
    _remember_graph(key, graph)
    return graph


def _nodes_geometry(graph: Any, paths: Sequence[Any]) -> tuple[list[tuple[float, float]], float]:
    coords: list[tuple[float, float]] = []
    distance = 0.0
    for path in paths:
        if not path:
            continue
        for i, node in enumerate(path):
            x = float(graph.nodes[node]["x"])
            y = float(graph.nodes[node]["y"])
            if coords and i == 0:
                pass
            else:
                coords.append((x, y))
            if i > 0:
                prev = path[i - 1]
                try:
                    edge_data = graph.get_edge_data(prev, node) or {}
                    lengths = [
                        float(d.get("length", 0.0))
                        for d in edge_data.values()
                        if isinstance(d, dict)
                    ]
                    if lengths:
                        distance += min(lengths)
                        continue
                except Exception:  # noqa: BLE001, S110
                    pass
                distance += haversine_meters(coords[-2][0], coords[-2][1], x, y)
    return coords, distance


def _road_route(
    lonlats: list[tuple[float, float]],
    network_type: str,
    timeout_s: float,
    cache_dir: str | None,
) -> RouteGeometry:
    import osmnx as ox  # lazy: optional dependency

    bbox = bbox_for_points(lonlats)
    cache_path = cache_path_for_bbox(*bbox, cache_dir=cache_dir)
    graph = _load_or_download_graph(bbox, cache_path, network_type, timeout_s)

    lons = [p[0] for p in lonlats]
    lats = [p[1] for p in lonlats]
    nodes = list(ox.distance.nearest_nodes(graph, X=lons, Y=lats))
    paths = ox.routing.shortest_path(graph, nodes[:-1], nodes[1:], weight="length", cpus=1)
    paths = list(paths)
    if not paths or any(p is None or len(p) == 0 for p in paths):
        raise RuntimeError("unroutable leg")

    try:
        coords: list[tuple[float, float]] = []
        distance = 0.0
        for path in paths:
            gdf = ox.routing.route_to_gdf(graph, path, weight="length")
            for _, row in gdf.iterrows():
                geom = row.geometry
                edge_coords = list(geom.coords)
                for j, (x, y) in enumerate(edge_coords):
                    if coords and j == 0:
                        continue
                    coords.append((float(x), float(y)))
            try:
                distance += float(gdf["length"].sum())
            except Exception:  # noqa: BLE001, S110
                pass
        if len(coords) >= 2:
            if distance <= 0:
                distance = straight_distance(coords)
            return RouteGeometry(points=coords, distance_meters=distance, fallback=False)
    except Exception:  # noqa: BLE001, S110
        pass

    coords, distance = _nodes_geometry(graph, paths)
    if len(coords) < 2:
        raise RuntimeError("empty road geometry")
    return RouteGeometry(points=coords, distance_meters=distance, fallback=False)


def _osrm_route(
    lonlats: list[tuple[float, float]], base_url: str, timeout_s: float
) -> RouteGeometry:
    """Query a self-hosted OSRM server. Raises on any failure."""
    coords = ";".join(f"{lon},{lat}" for lon, lat in lonlats)
    url = f"{base_url.rstrip('/')}/route/v1/driving/{coords}?overview=full&geometries=geojson"
    with urllib.request.urlopen(url, timeout=timeout_s) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if payload.get("code") != "Ok" or not payload.get("routes"):
        raise RuntimeError(f"osrm error: {payload.get('code')}")
    route = payload["routes"][0]
    coords = [(float(x), float(y)) for x, y in route["geometry"]["coordinates"]]
    if len(coords) < 2:
        raise RuntimeError("empty osrm geometry")
    return RouteGeometry(
        points=coords, distance_meters=float(route.get("distance", 0.0)), fallback=False
    )


def route_points(
    points: Sequence[Any],
    network_type: str = "drive",
    timeout_s: float | None = None,
    cache_dir: str | None = None,
    osrm_base_url: str | None = None,
) -> RouteGeometry:
    """Snap consecutive points to real roads; fall back to straight lines."""
    try:
        lonlats = as_lonlat_list(points)
    except Exception:  # noqa: BLE001
        return RouteGeometry(points=[], distance_meters=0.0, fallback=True)
    if len(lonlats) < 2:
        return straight_route(lonlats)
    effective_timeout = timeout_s if timeout_s is not None else settings.routing_timeout_s
    effective_osrm = osrm_base_url if osrm_base_url is not None else settings.osrm_base_url
    if effective_osrm:
        try:
            return _osrm_route(lonlats, effective_osrm, effective_timeout)
        except Exception as exc:  # noqa: BLE001
            logger.warning("osrm routing failed (%s); trying next backend", exc)
    try:
        return _road_route(lonlats, network_type, effective_timeout, cache_dir)
    except ImportError as exc:
        try:
            import osmnx  # noqa: F401
        except ImportError:
            logger.debug("routing extra not installed; using straight lines")
        else:
            logger.warning("osmnx routing failed (%s); using straight lines", exc)
        return straight_route(lonlats)
    except Exception as exc:  # noqa: BLE001
        logger.warning("osmnx routing failed (%s); using straight lines", exc)
        return straight_route(lonlats)
