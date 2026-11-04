import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/models.dart';
import '../utils/geo.dart';
import 'geo_map.dart';

/// Tap-to-pick OpenStreetMap location picker with a GPS button.
///
/// Reports the picked point through [onChanged]. The map has a fixed
/// [height] so it can live inside scrolling forms. Read-only reference
/// layers ([polylines], [extraMarkers]) render underneath the picked pin
/// and never affect picking.
class LocationMapPicker extends StatefulWidget {
  const LocationMapPicker({
    super.key,
    required this.onChanged,
    this.initial,
    this.height = 300,
    this.tileProvider,
    this.fallbackCenter,
    this.fallbackZoom,
    this.polylines = const [],
    this.extraMarkers = const [],
    this.coverageCircle,
  });

  final ValueChanged<GeoPoint?> onChanged;

  /// Starting pick, followed live when the parent changes it (e.g. a GPS
  /// prefill landing after first build, or a clear back to null).
  final GeoPoint? initial;
  final double height;

  /// Map center/zoom before anything is picked, e.g. the user's country
  /// viewport. Defaults to the world view.
  final LatLng? fallbackCenter;
  final double? fallbackZoom;

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  /// Defaults to the standard network tile provider.
  final TileProvider? tileProvider;

  /// Read-only reference lines (e.g. the assigned route). Lines with fewer
  /// than 2 points are skipped.
  final List<List<GeoPoint>> polylines;

  /// Read-only reference pins (e.g. route stops) under the picked pin.
  final List<MapMarkerData> extraMarkers;

  /// Translucent coverage circle (e.g. the collect radius around the
  /// collect center). Null draws nothing.
  final ({GeoPoint center, double radiusMeters})? coverageCircle;

  @override
  State<LocationMapPicker> createState() => _LocationMapPickerState();
}

class _LocationMapPickerState extends State<LocationMapPicker> {
  late final MapController _controller;
  GeoPoint? _picked;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _controller = MapController();
    _picked = widget.initial;
  }

  @override
  void didUpdateWidget(covariant LocationMapPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow the parent's pick (GPS prefill, clear); taps already agree.
    if (widget.initial != oldWidget.initial && widget.initial != _picked) {
      _picked = widget.initial;
      final picked = _picked;
      if (picked != null) _controller.move(picked.latLng, 15);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _pick(LatLng ll) {
    final point = ll.geoPoint;
    setState(() => _picked = point);
    widget.onChanged(point);
  }

  Future<void> _useGps() async {
    setState(() => _locating = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) _fail('Location permission denied');
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      final gps = LatLng(position.latitude, position.longitude);
      _controller.move(gps, 15);
      if (mounted) _pick(gps);
    } catch (e) {
      if (mounted) _fail('GPS failed: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _fail(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final picked = _picked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: widget.height,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _controller,
                  options: MapOptions(
                    initialCenter: picked?.latLng ??
                        widget.fallbackCenter ??
                        const LatLng(0, 0),
                    initialZoom: picked == null ? widget.fallbackZoom ?? 2 : 14,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                    onTap: (_, ll) => _pick(ll),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.garbagetrack.garbagetrack',
                      tileProvider: widget.tileProvider,
                    ),
                    if (widget.polylines.any((line) => line.length >= 2))
                      PolylineLayer(
                        polylines: [
                          for (final line in widget.polylines)
                            if (line.length >= 2)
                              Polyline(
                                points: line.map((p) => p.latLng).toList(),
                                strokeWidth: 4,
                                color: scheme.primary,
                              ),
                        ],
                      ),
                    if (widget.coverageCircle case final circle?)
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: circle.center.latLng,
                            radius: circle.radiusMeters,
                            useRadiusInMeter: true,
                            color: scheme.primary.withValues(alpha: 0.15),
                            borderColor: scheme.primary.withValues(alpha: 0.5),
                            borderStrokeWidth: 2,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        for (final extra in widget.extraMarkers)
                          Marker(
                            point: extra.point.latLng,
                            width: 40,
                            height: 40,
                            child: Tooltip(
                              message: extra.label ?? extra.point.short,
                              child: extra.number != null
                                  ? NumberedMapPin(
                                      number: extra.number!,
                                      color: extra.color ?? scheme.primary,
                                    )
                                  : MapPin(
                                      icon: extra.icon,
                                      color: extra.color ?? scheme.primary,
                                    ),
                            ),
                          ),
                        if (picked != null)
                          Marker(
                            point: picked.latLng,
                            width: 40,
                            height: 40,
                            child: MapPin(
                              icon: Icons.location_on,
                              color: scheme.primary,
                            ),
                          ),
                      ],
                    ),
                    const RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution('OpenStreetMap contributors'),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  right: 12,
                  bottom: 28,
                  child: FloatingActionButton.small(
                    heroTag: 'location-picker-gps',
                    onPressed: _locating ? null : _useGps,
                    tooltip: 'Use my GPS position',
                    child: _locating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          picked == null
              ? 'Tap the map to pick a location, or use GPS.'
              : 'Picked: ${picked.short}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
