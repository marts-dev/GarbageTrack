# GarbageTrack
Meta Hackathon 2026 Project

## Setup

Requires Python 3.11+ and a MongoDB instance (default `mongodb://localhost:27017`).

```bash
cp .env.example .env   # adjust MONGODB_URI / MONGODB_DB_NAME as needed
uv venv
uv pip install -e ".[dev]"
```

## Run

```bash
uv run uvicorn app.main:app --reload
```

Health probes:

- `GET /api/v1/health` — liveness, reports MongoDB reachability
- `GET /api/v1/health/db` — readiness, pings MongoDB

## Test

```bash
uv run pytest
```
