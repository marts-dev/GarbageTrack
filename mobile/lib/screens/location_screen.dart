import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/country_viewports.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/geo_map.dart';
import '../widgets/location_picker.dart';

class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key, this.setupMode = false, this.onSaved});

  /// First-run mode: shown instead of the resident home until a collection
  /// point exists. Offers sign-out (so nobody is trapped) and reports the
  /// save through [onSaved] instead of a snackbar.
  final bool setupMode;
  final VoidCallback? onSaved;

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  GeoPoint? _point;
  bool _saving = false;
  int _reload = 0;

  Future<UserLocation?> _load(AuthProvider auth) async {
    try {
      return await auth.users.getLocation(auth.user!.id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    final point = _point;
    if (point == null) return;
    setState(() => _saving = true);
    try {
      final auth = context.read<AuthProvider>();
      await auth.users.saveLocation(
        userId: auth.user!.id,
        longitude: point.longitude,
        latitude: point.latitude,
      );
      if (mounted) {
        if (widget.setupMode) {
          widget.onSaved?.call();
        } else {
          showOk(context, 'Collection point saved');
          setState(() => _reload++);
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final setup = widget.setupMode;
    return Scaffold(
      appBar: AppBar(
        title: Text(setup ? 'Set collection point' : 'Collection point'),
        actions: [
          if (setup)
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout_outlined),
              onPressed: () => context.read<AuthProvider>().logout(),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            if (setup) ...[
              Text(
                'Where should collectors pick up your garbage?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Your reports will be collected from this spot. You can move it later.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
            ],
            FutureBuilder(
              key: ValueKey(_reload),
              future: _load(auth),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox(
                    height: 120,
                    child: LoadingView(label: 'Loading saved location…'),
                  );
                }
                final saved = snapshot.data;
                if (saved == null) {
                  // In setup mode the intro above already explains the task.
                  if (setup) return const SizedBox.shrink();
                  return const EmptyState(
                    icon: Icons.pin_drop_outlined,
                    title: 'No collection point yet.',
                    subtitle: 'Pick a position below and save it.',
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        leading: const CardIcon(icon: Icons.pin_drop_outlined),
                        title: Text('Collection point: ${saved.location.short}'),
                        subtitle: Text('Updated ${saved.updatedAt.toLocal()}'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    GarbageMapView(
                      markers: [MapMarkerData(point: saved.location)],
                      height: 200,
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Text(setup ? 'Pick your collection point' : 'New position',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            LocationMapPicker(
              onChanged: (point) => setState(() => _point = point),
              fallbackCenter: viewportFor(auth.country).center,
              fallbackZoom: viewportFor(auth.country).zoom,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _point == null || _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save collection point'),
            ),
          ],
        ),
      ),
    );
  }
}
