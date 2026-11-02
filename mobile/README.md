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
- `lib/screens/` — login/register, per-role landings (resident home with
  location, reports, enroute trucks, classifier; collector with assigned truck,
  routes, vicinity collect, status, GPS location share; logistics with
  overview, trucks CRUD (list, create/edit with operator assignment and a
  map location picker, delete), facilities CRUD, route assignment and
  deletion), admin tabbed overview
- `lib/theme/` — centralized light/dark Material 3 theme (green seed)
- `lib/widgets/geo_map.dart` — reusable OpenStreetMap view
  (`GarbageMapView`: markers, route polylines, filled polygons, OSM
  attribution; optional marker clustering, pin/map taps, and a country
  fallback viewport)
- `lib/widgets/location_picker.dart` — tap-to-pick map picker with GPS button
  (`LocationMapPicker`), used by every location form
- `lib/utils/geo.dart` — GeoPoint (GeoJSON lon/lat) <-> LatLng conversions
  plus a pure-Dart point-in-polygon test for area selection
- `lib/utils/country_viewports.dart` — default map viewport per country

## Geo scoping

- Registration asks for a free-text country; it is stored on the user and
  returned by `/auth/me`. Users without one (legacy accounts) fall back to
  the world map view.
- Only residents can report garbage: other roles never see the posting
  entries, and the API rejects them with 403.
- New reports accept an optional district/region. The route-create screen
  filters posted garbage by district (server filter plus a client-side
  fallback) and scopes candidates to the logistics user's country.
- Route creation picks one or more depot facilities (any kind; the first
  pick is the route end shown on the map), shows posted garbage on a
  marker-clustered OSM map (tap a pin to select it), and offers a
  tap-the-map mode to place collection points plus a draw-an-area mode that
  selects every enclosed post as the stop set.
- Collectors work one truck at a time: logistics assigns a truck operator
  before the collector can collect or change status on that truck.
- Route maps draw the API's road-following geometry when present and fall
  back to straight lines otherwise.

Map tiles come from OpenStreetMap contributors; every map shows the required
attribution. Keep it visible to comply with the OSM tile usage policy.
