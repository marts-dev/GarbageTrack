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

## Auth

OAuth2 password flow with JWT (HS256 access tokens, 30 min) plus rotating
refresh tokens (7 days). Passwords are bcrypt-hashed (12 rounds); the app
refuses to start with a `JWT_SECRET_KEY` shorter than 32 bytes.

```bash
# register (roles: resident, collector, logistics; admin is never self-granted)
curl -X POST localhost:8000/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"me@example.com","password":"Password123"}'
# login (form fields, like the docs' Authorize button)
curl -X POST localhost:8000/api/v1/auth/login \
  -d 'username=me@example.com&password=Password123'
# then: -H "Authorization: Bearer <access_token>"
```

Set `ADMIN_EMAIL`/`ADMIN_PASSWORD` in `.env` to seed an ops admin on first
boot (only when no users exist). Admins manage roles via
`GET/PATCH /api/v1/auth/users…`.

Role map: residents use locations/garbage/AI and confirm their own posts;
`collector` unlocks truck route/collect/availability and confirming any post;
`logistics` unlocks truck scheduling and the logistics router; `admin` bypasses
all role checks. Health probes stay public.

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
- `GET /api/v1/trucks/{truck_id}` — read one truck

Collector API:

- `GET /api/v1/trucks/{truck_id}/route` — nearest-first collection route
  (`$geoNear`) filtered by the truck's garbage types (narrowable via `types`)
  and limited to remaining capacity; stops include per-stop distances
- `POST /api/v1/trucks/{truck_id}/collect-vicinity` — mark posted/scheduled
  garbage within `radius_meters` (default 500) as collected; bumps the
  truck's load and auto-marks it `full` at capacity
- `PATCH /api/v1/trucks/{truck_id}/availability` — set `available`, `working`,
  or `full` (returning to `available` resets the load)

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

## Test

```bash
uv run pytest
uv run ruff check app tests
```

Endpoint tests run against an in-memory async fake (`tests/fakes.py`), so no
live MongoDB is needed. Geospatial ordering (`$near`) is passed through to
MongoDB and needs a real database to verify end to end.
