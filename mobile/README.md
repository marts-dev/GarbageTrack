# GarbageTrack mobile + web app

Flutter (Material 3) front-end for the GarbageTrack API. Platforms: **Android** and **web**.

## Run

Start the API first (see the repo root README), then:

```bash
cd mobile
flutter pub get

# Web (API on localhost:8000; needs DEBUG=true in the API's .env so the
# browser accepts responses from Flutter's random dev-server port)
flutter run -d chrome

# Android emulator (10.0.2.2 routes to the host's localhost)
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000

# Physical device on the same Wi-Fi (use your machine's LAN IP)
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
```

The default `API_BASE_URL` is `http://localhost:8000`, which works for web
and desktop. The Android manifest allows plain-http API traffic for local
development only; serve the API over https and remove
`usesCleartextTraffic` for production.

## Build

```bash
flutter build web --release        # -> build/web
flutter build apk --debug          # needs Android SDK + Gradle on your machine
```

## Test

```bash
flutter analyze
flutter test                       # unit + widget tests, no backend needed
```

`tool/live_check.dart` drives every API call against a real backend (mongod +
uvicorn with a fresh database and seeded admin):

```bash
dart run tool/live_check.dart      # expects the API at 127.0.0.1:8000
```

## What's inside

- `lib/main.dart` — Material 3 theme, session provider, auth gate
- `lib/api/` — typed wrappers over every API area (auth, users, garbage,
  trucks, logistics, AI) with bearer tokens and one refresh retry
- `lib/state/` — session state plus token storage (secure storage with an
  in-memory fallback)
- `lib/screens/` — login/register, resident home (location, reports, enroute
  trucks, classifier), collector (truck routes, vicinity collect, status),
  logistics (overview, trucks, facilities CRUD, route assignment), admin users
- `lib/theme/` — centralized light/dark Material 3 theme (green seed)
- `lib/widgets/geo_map.dart` — reusable read-only OpenStreetMap view
  (`GarbageMapView`: markers, route polylines, OSM attribution)
- `lib/widgets/location_picker.dart` — tap-to-pick map picker with GPS button
  (`LocationMapPicker`), used by every location form
- `lib/utils/geo.dart` — GeoPoint (GeoJSON lon/lat) <-> LatLng conversions

Map tiles come from OpenStreetMap contributors; every map shows the required
attribution. Keep it visible to comply with the OSM tile usage policy.
