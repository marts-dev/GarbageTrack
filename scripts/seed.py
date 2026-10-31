"""Seed the database with demo data for UI walkthroughs.

Usage (from the repo root, uses .env unless overridden):
    uv run python scripts/seed.py            # seed empty database, abort if data exists
    uv run python scripts/seed.py --reset    # wipe app collections first, then seed

Login with any seeded user; every password is ``Password123``:
    resident@example.com / collector@example.com /
    logistics@example.com / admin@example.com
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
from app.models import facility as facility_model
from app.models import garbage as garbage_model
from app.models import route as route_model
from app.models import truck as truck_model
from app.models import user as user_model
from app.models.auth import Role
from app.models.common import utcnow
from app.models.facility import FacilityKind
from app.models.garbage import GarbageStatus, GarbageType
from app.models.geo import GeoPoint
from app.models.route import PlannedStop
from app.models.truck import TruckAvailability, TruckStatus

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
]


def pt(lon: float, lat: float) -> GeoPoint:
    return GeoPoint(coordinates=(lon, lat))


async def seed() -> dict:
    now = utcnow()
    client = AsyncMongoClient(settings.mongodb_uri)
    db = client[settings.mongodb_db_name]
    try:
        resident_id, collector_id, logistics_id, admin_id = (ObjectId() for _ in range(4))
        users = [
            auth_model.UserDocument(
                id=resident_id,
                email="resident@example.com",
                hashed_password=security.hash_password(PASSWORD),
                full_name="Adaeze Obi",
                role=Role.RESIDENT,
            ),
            auth_model.UserDocument(
                id=collector_id,
                email="collector@example.com",
                hashed_password=security.hash_password(PASSWORD),
                full_name="Emeka Danjuma",
                role=Role.COLLECTOR,
            ),
            auth_model.UserDocument(
                id=logistics_id,
                email="logistics@example.com",
                hashed_password=security.hash_password(PASSWORD),
                full_name="Fatima Bello",
                role=Role.LOGISTICS,
            ),
            auth_model.UserDocument(
                id=admin_id,
                email="admin@example.com",
                hashed_password=security.hash_password(PASSWORD),
                full_name="Site Admin",
                role=Role.ADMIN,
            ),
        ]
        await db[auth_model.COLLECTION].insert_many(
            [u.model_dump(by_alias=True) for u in users]
        )

        await db[user_model.COLLECTION].insert_one(
            user_model.UserLocationDocument(
                user_id=str(resident_id), location=pt(3.3700, 6.4505)
            ).model_dump(by_alias=True, exclude={"id"})
        )

        post_ids = [ObjectId() for _ in range(9)]
        specs = [
            # (lon, lat, types, description, status, days_ago, image?)
            (3.3710, 6.4510, [GarbageType.PLASTIC, GarbageType.METAL], "Bags by the gate",
             GarbageStatus.POSTED, 0, False),
            (3.3720, 6.4520, [GarbageType.ORGANIC], "Food waste bins overflowing",
             GarbageStatus.POSTED, 1, False),
            (3.3690, 6.4490, [GarbageType.PAPER], "Stack of cartons",
             GarbageStatus.POSTED, 1, False),
            (3.3750, 6.4550, [GarbageType.GLASS], "Broken bottles near junction",
             GarbageStatus.POSTED, 2, True),
            (3.3680, 6.4480, [GarbageType.ELECTRONIC], "Old CRT monitor",
             GarbageStatus.POSTED, 3, False),
            (3.3730, 6.4530, [GarbageType.PLASTIC], "Bottles at market entrance",
             GarbageStatus.SCHEDULED, 2, False),
            (3.3740, 6.4540, [GarbageType.TEXTILE], "Clothing pile",
             GarbageStatus.COLLECTED, 4, False),
            (3.3670, 6.4470, [GarbageType.HAZARDOUS], "Used batteries",
             GarbageStatus.COLLECTED, 5, False),
            (3.3760, 6.4560, [GarbageType.PLASTIC, GarbageType.PAPER], "Mixed dump behind plaza",
             GarbageStatus.SCHEDULED, 1, False),
        ]
        posts = []
        for pid, (lon, lat, types, desc, status, days, image) in zip(post_ids, specs):
            created = now - timedelta(days=days)
            posts.append(
                garbage_model.GarbagePostDocument(
                    id=pid,
                    user_id=str(resident_id),
                    location=pt(lon, lat),
                    types=types,
                    description=desc,
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
                plate_number="KTU-101AA",
                status=TruckStatus.ENROUTE,
                availability=TruckAvailability.WORKING,
                garbage_types=[GarbageType.PLASTIC, GarbageType.PAPER],
                current_location=pt(3.3700, 6.4500),
                eta_minutes=15,
                capacity=10,
                load=3,
            ),
            truck_model.TruckDocument(
                id=truck_ids[1],
                plate_number="KTU-202BB",
                status=TruckStatus.ENROUTE,
                availability=TruckAvailability.AVAILABLE,
                garbage_types=[GarbageType.ORGANIC],
                current_location=pt(3.3850, 6.4650),
                eta_minutes=40,
                capacity=8,
                load=0,
            ),
            truck_model.TruckDocument(
                id=truck_ids[2],
                plate_number="KTU-303CC",
                status=TruckStatus.SCHEDULED,
                availability=TruckAvailability.AVAILABLE,
                garbage_types=[GarbageType.GLASS, GarbageType.METAL],
                capacity=6,
            ),
        ]
        await db[truck_model.COLLECTION].insert_many(
            [t.model_dump(by_alias=True) for t in trucks]
        )

        facilities = [
            facility_model.FacilityDocument(
                name="Ojota Dump Site",
                kind=FacilityKind.DUMP_SITE,
                location=pt(3.3900, 6.4700),
                accepted_types=[GarbageType.GENERAL, GarbageType.ORGANIC, GarbageType.PLASTIC],
                address="1 Depot Rd, Ojota",
            ),
            facility_model.FacilityDocument(
                name="Ikeja Recycling Hub",
                kind=FacilityKind.RECYCLING,
                location=pt(3.3600, 6.4600),
                accepted_types=[
                    GarbageType.PLASTIC, GarbageType.PAPER, GarbageType.GLASS, GarbageType.METAL,
                ],
                address="5 Green Ave, Ikeja",
            ),
            facility_model.FacilityDocument(
                name="Epe Waste Center",
                kind=FacilityKind.WASTE_CENTER,
                location=pt(3.3800, 6.4400),
                accepted_types=[GarbageType.GENERAL, GarbageType.TEXTILE, GarbageType.ELECTRONIC],
                address="10 Central Rd",
            ),
        ]
        await db[facility_model.COLLECTION].insert_many(
            [f.model_dump(by_alias=True, exclude={"id"}) for f in facilities]
        )

        route_posts = [5, 8]  # indexes into specs above (both scheduled)
        await db[route_model.COLLECTION].insert_one(
            route_model.PlannedRouteDocument(
                truck_id=truck_ids[0],
                name="Morning run - Ojota",
                origin=pt(3.3700, 6.4500),
                stops=[
                    PlannedStop(
                        post_id=post_ids[i],
                        location=pt(specs[i][0], specs[i][1]),
                        types=specs[i][2],
                    )
                    for i in route_posts
                ],
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
    print(f"Log in with resident/collector/logistics/admin @example.com / {PASSWORD}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
