"""Seed the database with demo data for UI walkthroughs.

Usage (from the repo root, uses .env unless overridden):
    uv run python scripts/seed.py            # seed empty database, abort if data exists
    uv run python scripts/seed.py --reset    # wipe app collections first, then seed

Login with any seeded user; every password is ``Password123``:
    resident@example.com / collector@example.com /
    logistics@example.com / depot@example.com / admin@example.com
"""

import argparse
import asyncio
import sys
from datetime import timedelta
from pathlib import Path

from bson import ObjectId

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pymongo import AsyncMongoClient

from app.core import security
from app.core.config import settings
from app.models import auth as auth_model
from app.models import depot as depot_model
from app.models import facility as facility_model
from app.models import garbage as garbage_model
from app.models import route as route_model
from app.models import truck as truck_model
from app.models import user as user_model
from app.models.auth import Role
from app.models.common import utcnow
from app.models.facility import FacilityKind
from app.models.garbage import GarbageStatus, GarbageType
from app.models.geo import GeoLineString, GeoPoint
from app.models.route import PlannedStop
from app.models.truck import TruckAvailability

PASSWORD = "Password123"
# 1x1 red PNG, so one post renders with an attached photo.
TINY_PNG = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)

COLLECTIONS = [
    auth_model.COLLECTION,
    user_model.COLLECTION,
    garbage_model.COLLECTION,
    truck_model.COLLECTION,
    facility_model.COLLECTION,
    route_model.COLLECTION,
    depot_model.COLLECTION,
]

# Demo neighborhood center. Move these two constants to relocate every
# seeded point (posts, trucks, facilities, route) while keeping the
# relative layout intact.
CENTER_LON = 121.0629
CENTER_LAT = 14.6989

# Anchor the original layout was drawn from (Commonwealth, Quezon City).
_ANCHOR_LON = 121.0300
_ANCHOR_LAT = 14.6500


def pt(lon: float, lat: float) -> GeoPoint:
    return GeoPoint(
        coordinates=(
            lon + (CENTER_LON - _ANCHOR_LON),
            lat + (CENTER_LAT - _ANCHOR_LAT),
        )
    )


async def seed() -> dict:
    now = utcnow()
    client = AsyncMongoClient(settings.mongodb_uri)
    db = client[settings.mongodb_db_name]
    try:
        resident_id, collector_id, logistics_id, admin_id = (ObjectId() for _ in range(4))
        depot_user_id = ObjectId()
        depot_facility_id = ObjectId()
        users = [
            auth_model.UserDocument(
                id=resident_id,
                email="resident@example.com",
                hashed_password=security.hash_password(PASSWORD),
                full_name="Maria Santos",
                role=Role.RESIDENT,
                country="Philippines",
            ),
            auth_model.UserDocument(
                id=collector_id,
                email="collector@example.com",
                hashed_password=security.hash_password(PASSWORD),
                full_name="Jose Ramos",
                role=Role.COLLECTOR,
                country="Philippines",
            ),
            auth_model.UserDocument(
                id=logistics_id,
                email="logistics@example.com",
                hashed_password=security.hash_password(PASSWORD),
                full_name="Ana Reyes",
                role=Role.LOGISTICS,
                country="Philippines",
            ),
            auth_model.UserDocument(
                id=depot_user_id,
                email="depot@example.com",
                hashed_password=security.hash_password(PASSWORD),
                full_name="Lito Cruz",
                role=Role.DEPOT,
                country="Philippines",
                depot_id=str(depot_facility_id),
            ),
            auth_model.UserDocument(
                id=admin_id,
                email="admin@example.com",
                hashed_password=security.hash_password(PASSWORD),
                full_name="Site Admin",
                role=Role.ADMIN,
                country="Philippines",
            ),
        ]
        await db[auth_model.COLLECTION].insert_many(
            [u.model_dump(by_alias=True) for u in users]
        )

        await db[user_model.COLLECTION].insert_one(
            user_model.UserLocationDocument(
                user_id=str(resident_id), location=pt(121.0300, 14.6505)
            ).model_dump(by_alias=True, exclude={"id"})
        )

        post_ids = [ObjectId() for _ in range(9)]
        specs = [
            # (lon, lat, types, description, status, days_ago, image?, district)
            # Anchor-relative layout; pt() shifts everything to CENTER_*.
            (121.0310, 14.6510, [GarbageType.PLASTIC, GarbageType.METAL], "Bags by the gate",
             GarbageStatus.POSTED, 0, False, "Commonwealth"),
            (121.0320, 14.6520, [GarbageType.ORGANIC], "Food waste bins overflowing",
             GarbageStatus.POSTED, 1, False, "Commonwealth"),
            (121.0290, 14.6490, [GarbageType.PAPER], "Stack of cartons",
             GarbageStatus.POSTED, 1, False, "Batasan Hills"),
            (121.0350, 14.6550, [GarbageType.GLASS], "Broken bottles near junction",
             GarbageStatus.POSTED, 2, True, "Batasan Hills"),
            (121.0280, 14.6480, [GarbageType.ELECTRONIC], "Old CRT monitor",
             GarbageStatus.POSTED, 3, False, None),
            (121.0330, 14.6530, [GarbageType.PLASTIC], "Bottles at market entrance",
             GarbageStatus.SCHEDULED, 2, False, "Commonwealth"),
            (121.0340, 14.6540, [GarbageType.TEXTILE], "Clothing pile",
             GarbageStatus.COLLECTED, 4, False, "Batasan Hills"),
            (121.0270, 14.6470, [GarbageType.BATTERY], "Used batteries",
             GarbageStatus.POSTED, 0, False, "Commonwealth"),
            (121.0360, 14.6560, [GarbageType.PLASTIC, GarbageType.PAPER], "Mixed dump behind plaza",
             GarbageStatus.SCHEDULED, 1, False, "Batasan Hills"),
        ]
        posts = []
        for pid, (lon, lat, types, desc, status, days, image, district) in zip(post_ids, specs):
            created = now - timedelta(days=days)
            posts.append(
                garbage_model.GarbagePostDocument(
                    id=pid,
                    user_id=str(resident_id),
                    location=pt(lon, lat),
                    types=types,
                    description=desc,
                    district=district,
                    country="Philippines",
                    image_base64=TINY_PNG if image else None,
                    image_content_type="image/png" if image else None,
                    status=status,
                    created_at=created,
                    collected_at=created + timedelta(hours=5)
                    if status == GarbageStatus.COLLECTED
                    else None,
                ).model_dump(by_alias=True)
            )
        await db[garbage_model.COLLECTION].insert_many(posts)

        truck_ids = [ObjectId() for _ in range(3)]
        trucks = [
            truck_model.TruckDocument(
                id=truck_ids[0],
                plate_number="NAA 1234",
                availability=TruckAvailability.WORKING,
                garbage_types=[GarbageType.PLASTIC, GarbageType.PAPER],
                current_location=pt(121.0300, 14.6500),
                eta_minutes=15,
                capacity=10,
                load=3,
                load_by_type={"plastic": 2, "paper": 1},
                operator_id=str(collector_id),
            ),
            truck_model.TruckDocument(
                id=truck_ids[1],
                plate_number="NBB 5678",
                availability=TruckAvailability.AVAILABLE,
                garbage_types=[GarbageType.ORGANIC],
                current_location=pt(121.0450, 14.6650),
                eta_minutes=40,
                capacity=8,
                load=0,
            ),
            truck_model.TruckDocument(
                id=truck_ids[2],
                plate_number="NCC 9012",
                availability=TruckAvailability.AVAILABLE,
                garbage_types=[GarbageType.GLASS, GarbageType.METAL, GarbageType.BATTERY],
                capacity=6,
            ),
        ]
        await db[truck_model.COLLECTION].insert_many(
            [t.model_dump(by_alias=True) for t in trucks]
        )

        facilities = [
            facility_model.FacilityDocument(
                name="Payatas Transfer Station",
                kind=FacilityKind.DUMP_SITE,
                location=pt(121.0500, 14.6700),
                accepted_types=[GarbageType.GENERAL, GarbageType.ORGANIC, GarbageType.PLASTIC],
                address="1 Litex Rd, Payatas",
            ),
            facility_model.FacilityDocument(
                name="Cubao Recycling Hub",
                kind=FacilityKind.RECYCLING,
                location=pt(121.0200, 14.6600),
                accepted_types=[
                    GarbageType.PLASTIC, GarbageType.PAPER, GarbageType.GLASS, GarbageType.METAL,
                ],
                address="5 Green Ave, Cubao",
            ),
            facility_model.FacilityDocument(
                name="Marikina Waste Center",
                kind=FacilityKind.WASTE_CENTER,
                location=pt(121.0400, 14.6400),
                accepted_types=[GarbageType.GENERAL, GarbageType.TEXTILE, GarbageType.ELECTRONIC, GarbageType.BATTERY],
                address="10 Central Rd, Marikina",
            ),
        ]
        # First facility is the seeded depot user's depot.
        facility_ids = [depot_facility_id] + [ObjectId() for _ in range(len(facilities) - 1)]
        for facility, fid in zip(facilities, facility_ids):
            facility.id = fid
        await db[facility_model.COLLECTION].insert_many(
            [f.model_dump(by_alias=True) for f in facilities]
        )

        route_posts = [5, 8]  # indexes into specs above (both scheduled)
        route_origin = pt(121.0300, 14.6500)
        route_stops = [
            PlannedStop(
                post_id=post_ids[i],
                location=pt(specs[i][0], specs[i][1]),
                types=specs[i][2],
            )
            for i in route_posts
        ]
        depot_end = pt(121.0500, 14.6700)
        await db[route_model.COLLECTION].insert_one(
            route_model.PlannedRouteDocument(
                truck_id=truck_ids[0],
                name="Morning run - Commonwealth",
                origin=route_origin,
                stops=route_stops,
                # Two days out so the resident calendar shows an upcoming run.
                scheduled_for=(now + timedelta(days=2)).date().isoformat(),
                # Visit order: Cubao mid-route, Payatas last as the terminus.
                depot_ids=[facility_ids[1], facility_ids[0]],
                collection_points=[pt(121.0325, 14.6525), pt(121.0355, 14.6555)],
                geometry=GeoLineString(
                    coordinates=[
                        (route_origin.longitude, route_origin.latitude),
                        *[
                            (stop.location.longitude, stop.location.latitude)
                            for stop in route_stops
                        ],
                        (depot_end.longitude, depot_end.latitude),
                    ]
                ),
                geometry_source="straight",
            ).model_dump(by_alias=True, exclude={"id"})
        )
        counts = {name: await db[name].count_documents({}) for name in COLLECTIONS}
        return counts
    finally:
        await client.close()


async def has_data() -> bool:
    client = AsyncMongoClient(settings.mongodb_uri)
    try:
        db = client[settings.mongodb_db_name]
        for name in COLLECTIONS:
            if await db[name].count_documents({}, limit=1):
                return True
        return False
    finally:
        await client.close()


async def wipe() -> None:
    client = AsyncMongoClient(settings.mongodb_uri)
    try:
        db = client[settings.mongodb_db_name]
        for name in COLLECTIONS:
            await db[name].delete_many({})
    finally:
        await client.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Seed demo data.")
    parser.add_argument("--reset", action="store_true", help="wipe app collections first")
    args = parser.parse_args()

    print(f"Target: {settings.mongodb_db_name} @ {settings.mongodb_uri.split('@')[-1]}")
    if args.reset:
        print("Wiping app collections...")
        asyncio.run(wipe())
    elif asyncio.run(has_data()):
        print("Database already has data; re-run with --reset to wipe and reseed.")
        return 1
    counts = asyncio.run(seed())
    print("Seeded:", ", ".join(f"{k}={v}" for k, v in counts.items()))
    print(f"Log in with resident/collector/logistics/depot/admin @example.com / {PASSWORD}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
