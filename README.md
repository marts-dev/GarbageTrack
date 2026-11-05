# GarbageTrack
Meta Hackathon 2026 Project

## Setup

Requires Python 3.11+ and a MongoDB instance (default `mongodb://localhost:27017`).

```bash
cp .env.example .env   # adjust MONGODB_URI / MONGODB_DB_NAME as needed
uv venv
uv pip install -e ".[dev]"
```

## Local MongoDB (testing)

A self-contained `mongod` (v8.2.6, TCP on `127.0.0.1:27017`) lives in
`tools/mongodb/` (binary, data dir, and logs; git-ignored):

```bash
./tools/mongodb/mongo.sh start    # start (fork) the instance
./tools/mongodb/mongo.sh status   # check it reported ready
./tools/mongodb/mongo.sh stop     # shut it down
```

Point the app at it with `MONGODB_URI=mongodb://127.0.0.1:27017` in `.env`
(this overrides any Atlas `mongodb+srv://` URI for local testing).

## Run

```bash
uv run uvicorn app.main:app --reload
```

Interactive docs: `http://localhost:8000/docs`

## Mobile + web app

Flutter front-end lives in [`mobile/`](mobile/) (Android and web, Material 3).
See [`mobile/README.md`](mobile/README.md) for run/build instructions — it
covers auth, resident, collector, logistics, and admin flows.

## Auth

OAuth2 password flow with JWT (HS256 access tokens, 30 min) plus rotating
refresh tokens (7 days). Passwords are bcrypt-hashed (12 rounds); the app
refuses to start with a `JWT_SECRET_KEY` shorter than 32 bytes.

```bash
# register (role defaults to resident; admin is never self-granted)
curl -X POST localhost:8000/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"me@example.com","password":"Password123"}'
# optional fields: "full_name", "role": resident | collector | logistics
# login (form fields, like the docs' Authorize button)
curl -X POST localhost:8000/api/v1/auth/login \
  -d 'username=me@example.com&password=Password123'
# then: -H "Authorization: Bearer <access_token>"
```

Set `ADMIN_EMAIL`/`ADMIN_PASSWORD` in `.env` to seed an ops admin on first
boot (only when no users exist). Admins manage the user role via
`PATCH /api/v1/auth/users/{id}/role` and activation via
`PATCH /api/v1/auth/users/{id}/active` (deactivation blocks login and
releases operated trucks; it never deletes the user);
`GET /api/v1/auth/users` is visible to
logistics and admin with an optional `?role=` filter (used to pick a collector
when assigning a truck operator); users edit their own display name with
`PATCH /api/v1/auth/me`.

Role map: residents use locations/garbage/AI and confirm their own posts;
`collector` unlocks truck route/collect/availability and confirming any post;
`logistics` unlocks truck scheduling and the logistics router; `admin` bypasses
all role checks except the six truck operate endpoints
(collect/start/finish/claim/release/location), which are collector-only.
Health probes stay public.

## API (v1)

Health probes:

- `GET /api/v1/health` — liveness, reports MongoDB reachability
- `GET /api/v1/health/db` — readiness, pings MongoDB

User locations (stored as GeoJSON Points with a `2dsphere` index for geospatial queries):

- `PUT /api/v1/users/{user_id}/location` — save `{longitude, latitude}`
- `GET /api/v1/users/{user_id}/location` — read saved location

Garbage posts:

- `POST /api/v1/garbage` — post garbage for collection; accepts multiple
  `types` (`plastic`, `organic`, `paper`, `glass`, `metal`, `electronic`,
  `hazardous`, `textile`, `general`) and an optional base64 `image_base64`
  (≤5 MB decoded) with `image_content_type`
- `GET /api/v1/garbage` — list posts; filter by `user_id`, `status`, or nearby
  (`longitude`, `latitude`, `max_meters`)
- `GET /api/v1/garbage/{post_id}` — read one post
- `PATCH /api/v1/garbage/{post_id}/confirm-collected` — confirm collection
  (404 unknown, 409 already collected)

Trucks:

- `POST /api/v1/trucks/schedules` — schedule a truck (plate number, garbage
  types, status, current location, ETA, capacity)
- `GET /api/v1/trucks/enroute` — view enroute trucks and the garbage types
  each collects; optional nearby filter (`longitude`, `latitude`, `max_meters`)
- `GET /api/v1/trucks` — list trucks (collector/logistics; filter by `status`,
  `availability`, `limit`)
- `GET /api/v1/trucks/{truck_id}` — read one truck
- `PATCH /api/v1/trucks/{truck_id}` — edit plate, capacity, garbage types,
  status, `current_location`, or `operator_id` (logistics/admin;
  `operator_id: null` unassigns; one collector bound to at most one truck)
- `DELETE /api/v1/trucks/{truck_id}` — remove a truck (logistics/admin;
  refused with 409 while it has an assigned planned route)

Collector API:

- `GET /api/v1/trucks/{truck_id}/route` — nearest-first collection route
  (`$geoNear`) filtered by the truck's garbage types (narrowable via `types`)
  and limited to remaining capacity; stops include per-stop distances
- `GET /api/v1/trucks/{truck_id}/planned-route` — the truck's assigned
  planned route for the collector to follow (404 when none assigned);
  stops already collected are filtered out and depots are embedded
- `GET /api/v1/trucks/{truck_id}/collect-candidates` — preview what a
  collect would grab (same origin/radius/types guard, no writes)
- `POST /api/v1/trucks/{truck_id}/collect-vicinity` — mark posted/scheduled
  garbage within `radius_meters` (default 30) as collected; bumps the
  truck's load and auto-marks it `full` at capacity (collector-only, 403
  unless the truck is assigned to you)
- `PATCH /api/v1/trucks/{truck_id}/availability` — set `available`, `working`,
  or `full` (returning to `available` resets the load; same 403 rule)
- `POST /api/v1/trucks/{truck_id}/location` — share the truck's GPS
  `{longitude, latitude, accuracy_m}` (same 403 rule)

AI (placeholder):

- `POST /api/v1/ai/classify` — suggest a garbage classification; currently
  returns a stub marked `"placeholder": true`

Logistics:

- `GET /api/v1/logistics/garbage` — view all posted garbage (filter by
  `status`, `type`, `user_id`)
- `GET /api/v1/logistics/garbage/summary` — totals by status and type
- `GET /api/v1/logistics/trucks/locations` — view truck locations (filter by
  `status`, `availability`)
- `POST /api/v1/logistics/facilities` — register a `dump_site`, `recycling`,
  or `waste_center` facility
- `GET /api/v1/logistics/facilities` — list facilities (filter by `kind` or
  nearby); `GET` one, `PATCH` to edit, `DELETE` to remove
- `POST /api/v1/logistics/routes` — create a collection route for a truck:
  pass explicit `post_ids`, or omit them to auto-generate from the truck's
  route (type/capacity/proximity); assigned posts flip to `scheduled`
- `GET /api/v1/logistics/routes` — list assigned routes (by `truck_id`/`status`)

## Road routing (optional)

Route responses carry a `geometry` polyline plus `geometry_source`
(`"road"` or `"straight"`). Resolution order: self-hosted OSRM (when
`OSRM_BASE_URL` is set) → OSMnx → straight lines. Any failure at any
step falls back to the next instead of erroring.

```bash
# Option A: local OSRM (no extra Python deps; needs Docker + map extract)
# OSRM_BASE_URL=http://localhost:5000 in .env

# Option B: OSMnx (needs the routing extra + Overpass network access once
# per area; the street network is cached under var/route-cache/)
uv pip install -e ".[routing]"   # osmnx + scikit-learn
```

Without either backend the API returns straight lines with
`geometry_source: "straight"`.

## Test

```bash
uv run pytest
uv run ruff check app tests
```

Endpoint tests run against an in-memory async fake (`tests/fakes.py`), so no
live MongoDB is needed. Geospatial ordering (`$near`) is passed through to
MongoDB and needs a real database to verify end to end.
