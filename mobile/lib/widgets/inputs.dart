import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../models/models.dart';

/// GPS button plus manual longitude/latitude fields. Reports a valid point
/// through [onChanged] whenever either source produces one.
class LocationInput extends StatefulWidget {
  const LocationInput({
    super.key,
    required this.onChanged,
    this.initial,
  });

  final ValueChanged<GeoPoint?> onChanged;
  final GeoPoint? initial;

  @override
  State<LocationInput> createState() => _LocationInputState();
}

class _LocationInputState extends State<LocationInput> {
  late final TextEditingController _lon;
  late final TextEditingController _lat;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _lon = TextEditingController(text: widget.initial?.longitude.toString() ?? '');
    _lat = TextEditingController(text: widget.initial?.latitude.toString() ?? '');
    _lon.addListener(_emit);
    _lat.addListener(_emit);
  }

  @override
  void dispose() {
    _lon.dispose();
    _lat.dispose();
    super.dispose();
  }

  void _emit() {
    final lon = double.tryParse(_lon.text.trim());
    final lat = double.tryParse(_lat.text.trim());
    if (lon == null || lat == null || lon < -180 || lon > 180 || lat < -90 || lat > 90) {
      widget.onChanged(null);
    } else {
      widget.onChanged(GeoPoint(longitude: lon, latitude: lat));
    }
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
      _lon.text = position.longitude.toString();
      _lat.text = position.latitude.toString();
    } catch (e) {
      if (mounted) _fail('GPS failed: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _fail(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _lat,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Latitude', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _lon,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration:
                    const InputDecoration(labelText: 'Longitude', border: OutlineInputBorder()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _locating ? null : _useGps,
          icon: _locating
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.my_location),
          label: const Text('Use my GPS position'),
        ),
      ],
    );
  }
}

/// Multi-select chips for garbage types.
class GarbageTypePicker extends StatelessWidget {
  const GarbageTypePicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        for (final type in garbageTypes)
          FilterChip(
            label: Text(pretty(type)),
            selected: selected.contains(type),
            onSelected: (on) {
              final next = Set<String>.of(selected);
              if (on) {
                next.add(type);
              } else {
                next.remove(type);
              }
              onChanged(next);
            },
          ),
      ],
    );
  }
}
