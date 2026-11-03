import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/country_viewports.dart';
import '../widgets/async_view.dart';
import '../widgets/inputs.dart';
import '../widgets/location_picker.dart';

class FacilityFormScreen extends StatefulWidget {
  const FacilityFormScreen(
      {super.key, this.existing, this.selfRegister = false, this.tileProvider});

  final Facility? existing;

  /// Depot self-registration: creates through the depot endpoint so the
  /// caller is bound to the new depot in the same call. Create-only.
  final bool selfRegister;

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  @override
  State<FacilityFormScreen> createState() => _FacilityFormScreenState();
}

class _FacilityFormScreenState extends State<FacilityFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _address;
  late String _kind;
  final _types = <String>{};
  GeoPoint? _point;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _address = TextEditingController(text: existing?.address ?? '');
    _kind = existing?.kind ?? facilityKinds.first;
    if (existing != null) {
      _types.addAll(existing.acceptedTypes);
      _point = existing.location;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate() || _types.isEmpty || _point == null) {
      if (_types.isEmpty || _point == null) {
        showError(context, 'Pick at least one accepted type and a valid location');
      }
      return;
    }
    final point = _point!;
    setState(() => _busy = true);
    try {
      final auth = context.read<AuthProvider>();
      final existing = widget.existing;
      if (existing == null && widget.selfRegister) {
        await auth.depot.registerDepot(
          name: _name.text.trim(),
          kind: _kind,
          longitude: point.longitude,
          latitude: point.latitude,
          acceptedTypes: _types.toList(),
          address: _address.text.trim().isEmpty ? null : _address.text.trim(),
        );
      } else if (existing == null) {
        await auth.logistics.createFacility(
          name: _name.text.trim(),
          kind: _kind,
          longitude: point.longitude,
          latitude: point.latitude,
          acceptedTypes: _types.toList(),
          address: _address.text.trim().isEmpty ? null : _address.text.trim(),
        );
      } else {
        await auth.logistics.updateFacility(
          existing.id,
          name: _name.text.trim(),
          kind: _kind,
          longitude: point.longitude,
          latitude: point.latitude,
          acceptedTypes: _types.toList(),
          address: _address.text.trim(),
        );
      }
      if (mounted) {
        showOk(context, existing == null ? 'Facility registered' : 'Facility updated');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final viewport =
        viewportFor(context.watch<AuthProvider>().country);
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit facility' : 'New facility')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Details', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: (v) =>
                          v != null && v.trim().isNotEmpty ? null : 'Name is required',
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _kind,
                      decoration: const InputDecoration(labelText: 'Kind'),
                      items: [
                        for (final kind in facilityKinds)
                          DropdownMenuItem(value: kind, child: Text(pretty(kind))),
                      ],
                      onChanged: (v) => v == null ? null : setState(() => _kind = v),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _address,
                      decoration: const InputDecoration(
                        labelText: 'Address (optional)',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Accepted types',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    GarbageTypePicker(
                      selected: _types,
                      onChanged: (next) => setState(() => _types
                        ..clear()
                        ..addAll(next)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Location', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    LocationMapPicker(
                      initial: _point,
                      onChanged: (point) => setState(() => _point = point),
                      fallbackCenter: viewport.center,
                      fallbackZoom: viewport.zoom,
                      tileProvider: widget.tileProvider,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(editing ? 'Save changes' : 'Register facility'),
            ),
          ],
        ),
      ),
    );
  }
}
