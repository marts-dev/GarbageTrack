"""Road routing: pure helpers, stubbed API geometry, fallback, seed validity."""

import json
import os
import sys
import tomllib
import urllib.error
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from bson import ObjectId

from app.models.geo import GeoLineString, GeoPoint
from app.models.route import PlannedRouteDocument, PlannedStop
from app.models.truck import TruckDocument
from app.services import routing as routing_service
from app.services.routing import RouteGeometry


@pytest.fixture
def dispatcher(client, make_user):
    return make_user("logistics")


@pytest.fixture
def collector(client, make_user):
    return make_user("collector")


def _make_truck(client, headers, **overrides):
    payload = {
        "plate_number": "RTG-1",
        "garbage_types": ["plastic"],
        "status": "enroute",
        "current_location": {"longitude": 3.37, "latitude": 6.45},
        "capacity": 10,
    }
    payload.update(overrides)
    response = client.post("/api/v1/trucks/schedules", json=payload, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


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


def _make_facility(client, headers, **overrides):
    payload = {
        "name": "Depot",
        "kind": "dump_site",
        "location": {"longitude": 3.38, "latitude": 6.46},
        "accepted_types": ["plastic"],
    }
    payload.update(overrides)
    response = client.post("/api/v1/logistics/facilities", json=payload, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


def test_haversine_and_straight_route():
    d = routing_service.haversine_meters(0.0, 0.0, 0.0, 1.0)
    assert 110000 < d < 112000
    geom = routing_service.straight_route([(0.0, 0.0), (1.0, 1.0)])
    assert geom.fallback is True
    assert geom.points == [(0.0, 0.0), (1.0, 1.0)]
    assert geom.distance_meters > 0
    single = routing_service.straight_route([(0.0, 0.0)])
    assert single.fallback is True
    assert single.distance_meters == 0.0


def test_bbox_and_area_key_deterministic():
    bbox = routing_service.bbox_for_points([(3.37, 6.45), (3.38, 6.46)])
    left, bottom, right, top = bbox
    assert left < right and bottom < top
    key = routing_service.area_key(left, bottom, right, top)
    assert key.endswith(".graphml")
    assert key.startswith("drive_")
    assert "-" not in key.replace(".graphml", "")
    assert key == routing_service.area_key(left, bottom, right, top)
    path = routing_service.cache_path_for_bbox(left, bottom, right, top)
    assert path.name == key
    assert "route-cache" in str(path)


def test_as_lonlat_list_handles_shapes():
    pts = routing_service.as_lonlat_list(
        [
            GeoPoint(coordinates=(1.0, 2.0)),
            {"type": "Point", "coordinates": [3.0, 4.0]},
            (5.0, 6.0),
            [7.0, 8.0],
        ]
    )
    assert pts == [(1.0, 2.0), (3.0, 4.0), (5.0, 6.0), (7.0, 8.0)]


def test_route_points_falls_back_offline():
    geom = routing_service.route_points([(3.37, 6.45), (3.371, 6.451)])
    assert geom.fallback is True
    assert geom.points == [(3.37, 6.45), (3.371, 6.451)]
    assert geom.distance_meters > 0


def test_route_points_short_input_never_raises():
    geom = routing_service.route_points([(3.37, 6.45)])
    assert geom.fallback is True
    assert geom.distance_meters == 0.0
    bad = routing_service.route_points([object()])
    assert bad.fallback is True


def test_no_osmnx_import_at_module_time():
    import pathlib

    assert "osmnx" not in sys.modules
    src = pathlib.Path(routing_service.__file__).read_text()
    for line in src.splitlines():
        stripped = line.strip()
        if "import osmnx" in stripped:
            assert line.startswith((" ", "\t")), "osmnx must be imported lazily inside functions"


def test_collector_route_carries_road_geometry_when_stubbed(
    client, dispatcher, collector, make_user
):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    _make_post(client, resident)
    road = RouteGeometry(
        points=[(3.37, 6.45), (3.375, 6.455), (3.371, 6.451)],
        distance_meters=1200.0,
        fallback=False,
    )
    with patch("app.services.routing.route_points", return_value=road):
        response = client.get(
            f"/api/v1/trucks/{truck['id']}/route", headers=collector["headers"]
        )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["geometry_source"] == "road"
    assert body["geometry"]["type"] == "LineString"
    assert body["geometry"]["coordinates"] == [
        [3.37, 6.45],
        [3.375, 6.455],
        [3.371, 6.451],
    ]


def test_collector_route_straight_fallback_when_road_unavailable(
    client, dispatcher, collector, make_user
):
    resident = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    _make_post(client, resident)
    with patch("app.services.routing._road_route", side_effect=RuntimeError("no graph")):
        response = client.get(
            f"/api/v1/trucks/{truck['id']}/route", headers=collector["headers"]
        )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["geometry_source"] == "straight"
    assert body["geometry"]["type"] == "LineString"
    assert body["geometry"]["coordinates"][0] == [3.37, 6.45]
    assert len(body["geometry"]["coordinates"]) >= 2


def test_collector_route_empty_has_no_geometry(client, dispatcher, collector):
    truck = _make_truck(client, dispatcher["headers"])
    response = client.get(f"/api/v1/trucks/{truck['id']}/route", headers=collector["headers"])
    assert response.status_code == 200
    assert response.json()["stops"] == []
    assert response.json()["geometry"] is None
    assert response.json()["geometry_source"] == "straight"


def test_planned_route_carries_road_geometry_and_depot_end(
    client, dispatcher, make_user
):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)
    road = RouteGeometry(
        points=[(3.37, 6.45), (3.371, 6.451), (3.38, 6.46)],
        distance_meters=2500.0,
        fallback=False,
    )
    with patch("app.services.routing.route_points", return_value=road):
        response = client.post(
            "/api/v1/logistics/routes",
            json={
                "truck_id": truck["id"],
                "post_ids": [post["id"]],
                "depot_ids": [depot["id"]],
            },
            headers=dispatcher["headers"],
        )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["geometry_source"] == "road"
    assert body["geometry"]["coordinates"][-1] == [3.38, 6.46]


def test_planned_route_uses_osrm_when_configured(client, dispatcher, make_user):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)
    fake_urlopen = _urlopen_with(
        _osrm_payload(coords=((3.37, 6.45), (3.371, 6.451), (3.38, 6.46)))
    )
    with (
        patch("urllib.request.urlopen", fake_urlopen),
        patch.object(routing_service.settings, "osrm_base_url", "http://osrm:5000"),
    ):
        response = client.post(
            "/api/v1/logistics/routes",
            json={
                "truck_id": truck["id"],
                "post_ids": [post["id"]],
                "depot_ids": [depot["id"]],
            },
            headers=dispatcher["headers"],
        )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["geometry_source"] == "road"
    assert body["geometry"]["coordinates"] == [[3.37, 6.45], [3.371, 6.451], [3.38, 6.46]]


def test_planned_route_straight_fallback_on_road_error(client, dispatcher, make_user):
    me = make_user()
    truck = _make_truck(client, dispatcher["headers"])
    depot = _make_facility(client, dispatcher["headers"])
    post = _make_post(client, me)
    with patch("app.services.routing._road_route", side_effect=RuntimeError("offline")):
        response = client.post(
            "/api/v1/logistics/routes",
            json={
                "truck_id": truck["id"],
                "post_ids": [post["id"]],
                "depot_ids": [depot["id"]],
            },
            headers=dispatcher["headers"],
        )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["geometry_source"] == "straight"
    assert body["geometry"]["type"] == "LineString"
    assert len(body["geometry"]["coordinates"]) >= 2


def test_seed_models_validate_with_new_fields():
    truck = TruckDocument(
        plate_number="SEED-1",
        garbage_types=["plastic"],
        operator_id=str(ObjectId()),
    )
    assert truck.operator_id is not None
    origin = GeoPoint(coordinates=(121.03, 14.65))
    stop = PlannedStop(
        post_id=ObjectId(), location=GeoPoint(coordinates=(121.031, 14.651)), types=["plastic"]
    )
    route = PlannedRouteDocument(
        truck_id=ObjectId(),
        origin=origin,
        stops=[stop],
        depot_ids=[ObjectId()],
        geometry=GeoLineString(coordinates=[(121.03, 14.65), (121.031, 14.651)]),
        geometry_source="straight",
    )
    assert route.geometry_source == "straight"
    dumped = route.model_dump(by_alias=True)
    assert dumped["geometry"]["type"] == "LineString"


def test_legacy_truck_and_route_defaults():
    truck = TruckDocument(plate_number="LEG-1", garbage_types=["plastic"])
    assert truck.operator_id is None
    route = PlannedRouteDocument(
        truck_id=ObjectId(),
        origin=GeoPoint(coordinates=(0.0, 0.0)),
        stops=[
            PlannedStop(
                post_id=ObjectId(),
                location=GeoPoint(coordinates=(0.0, 0.0)),
                types=["plastic"],
            )
        ],
        depot_ids=[ObjectId()],
    )
    assert route.geometry is None
    assert route.geometry_source == "straight"


def test_legacy_truck_doc_without_operator_reads(client, dispatcher, fake_db):
    from app.models import truck as truck_model

    truck = _make_truck(client, dispatcher["headers"])
    doc_id = ObjectId(truck["id"])
    stored = fake_db[truck_model.COLLECTION].docs[doc_id]
    stored.pop("operator_id", None)
    reread = client.get(f"/api/v1/trucks/{truck['id']}", headers=dispatcher["headers"])
    assert reread.status_code == 200
    assert reread.json()["operator_id"] is None


@pytest.mark.skipif(os.getenv("ROUTING_LIVE") != "1", reason="live OSMnx download opt-in")
def test_live_osmnx_download_opt_in():
    pytest.importorskip("osmnx")
    geom = routing_service.route_points([(3.37, 6.45), (3.371, 6.451)])
    assert len(geom.points) >= 2


def _osrm_payload(code="Ok", coords=((121.031, 14.651), (121.035, 14.655))):
    return {
        "code": code,
        "routes": [
            {
                "geometry": {"coordinates": [list(c) for c in coords], "type": "LineString"},
                "distance": 1234.5,
            }
        ],
    }


def _urlopen_with(payload):
    response = MagicMock()
    response.read.return_value = json.dumps(payload).encode("utf-8")
    opener = MagicMock()
    opener.__enter__.return_value = response
    opener.__exit__.return_value = False
    return MagicMock(return_value=opener)


def test_osrm_success_returns_road_geometry():
    payload = _osrm_payload(coords=((121.0, 14.0), (121.1, 14.1), (121.2, 14.2)))
    fake_urlopen = _urlopen_with(payload)
    with patch("urllib.request.urlopen", fake_urlopen):
        geom = routing_service.route_points(
            [(121.0, 14.0), (121.2, 14.2)], osrm_base_url="http://osrm:5000/"
        )
    assert geom.fallback is False
    assert geom.points == [(121.0, 14.0), (121.1, 14.1), (121.2, 14.2)]
    assert geom.distance_meters == 1234.5
    requested_url = fake_urlopen.call_args[0][0]
    assert requested_url.startswith("http://osrm:5000/route/v1/driving/121.0,14.0;121.2,14.2")
    assert "geometries=geojson" in requested_url


def test_osrm_error_code_falls_back_to_straight():
    fake_urlopen = _urlopen_with(_osrm_payload(code="NoRoute"))
    with patch("urllib.request.urlopen", fake_urlopen):
        geom = routing_service.route_points(
            [(121.0, 14.0), (121.2, 14.2)], osrm_base_url="http://osrm:5000"
        )
    assert geom.fallback is True
    assert geom.points == [(121.0, 14.0), (121.2, 14.2)]


def test_osrm_unreachable_falls_back_to_straight():
    fake_urlopen = MagicMock(side_effect=urllib.error.URLError("down"))
    with patch("urllib.request.urlopen", fake_urlopen):
        geom = routing_service.route_points(
            [(121.0, 14.0), (121.2, 14.2)], osrm_base_url="http://osrm:5000"
        )
    assert geom.fallback is True
    assert len(geom.points) == 2


def test_osrm_failure_is_logged(caplog):
    import logging

    fake_urlopen = MagicMock(side_effect=urllib.error.URLError("down"))
    with (
        patch("urllib.request.urlopen", fake_urlopen),
        caplog.at_level(logging.WARNING, logger="app.services.routing"),
    ):
        routing_service.route_points(
            [(121.0, 14.0), (121.2, 14.2)], osrm_base_url="http://osrm:5000"
        )
    assert "osrm routing failed" in caplog.text


def test_osrm_empty_geometry_falls_back_to_straight():
    fake_urlopen = _urlopen_with(_osrm_payload(coords=((121.0, 14.0),)))
    with patch("urllib.request.urlopen", fake_urlopen):
        geom = routing_service.route_points(
            [(121.0, 14.0), (121.2, 14.2)], osrm_base_url="http://osrm:5000"
        )
    assert geom.fallback is True
    assert len(geom.points) == 2


def test_routing_extra_declares_nearest_node_dependency():
    """osmnx nearest_nodes on unprojected graphs needs scikit-learn.

    Without it the road path always raises ImportError internally and every
    route silently degrades to straight lines, so the extra must pin it.
    """
    pyproject = tomllib.loads(Path("pyproject.toml").read_text())
    extra = pyproject["project"]["optional-dependencies"]["routing"]
    assert any(req.startswith("scikit-learn") for req in extra), extra
