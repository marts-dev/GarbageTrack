import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/geo_map.dart';

class EnrouteScreen extends StatefulWidget {
  const EnrouteScreen({super.key, this.tileProvider});

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  @override
  State<EnrouteScreen> createState() => _EnrouteScreenState();
}

class _EnrouteScreenState extends State<EnrouteScreen> {
  int _reload = 0;

  /// Live trucks around the resident's saved collection point. Without a
  /// point (never saved, signed out, or offline) the call falls back to
  /// unfiltered so the screen still works, with a note saying why.
  Future<({List<Truck> trucks, GeoPoint? center})> _load(
      AuthProvider auth) async {
    GeoPoint? center;
    final user = auth.user;
    if (user != null) {
      try {
        center = (await auth.users.getLocation(user.id)).location;
      } catch (_) {
        center = null;
      }
    }
    final trucks = await auth.trucks.listEnroute(
      longitude: center?.longitude,
      latitude: center?.latitude,
    );
    return (trucks: trucks, center: center);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Trucks enroute')),
      body: FutureBuilder(
        key: ValueKey(_reload),
        future: _load(auth),
        builder: (context, snapshot) =>
            AsyncView<({List<Truck> trucks, GeoPoint? center})>(
          snapshot: snapshot,
          onRetry: () => setState(() => _reload++),
          builder: (context, data) {
            final trucks = data.trucks;
            if (trucks.isEmpty) {
              return RefreshableEmpty(
                onRefresh: () async => setState(() => _reload++),
                empty: const EmptyState(
                  icon: Icons.local_shipping_outlined,
                  title: 'No trucks enroute.',
                  subtitle: 'Pull down to check again.',
                ),
              );
            }
            final located =
                trucks.where((t) => t.currentLocation != null).toList();
            final center = data.center;
            return RefreshIndicator(
              onRefresh: () async => setState(() => _reload++),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (center == null)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(
                          Icons.info_outline,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                        title: const Text('Showing all live trucks'),
                        subtitle: const Text(
                          'Save a collection point to filter by distance.',
                        ),
                      ),
                    ),
                  if (located.isNotEmpty) ...[
                    GarbageMapView(
                      tileProvider: widget.tileProvider,
                      markers: [
                        for (final truck in located)
                          MapMarkerData(
                            point: truck.currentLocation!,
                            icon: Icons.local_shipping,
                            label: truck.plateNumber,
                          ),
                      ],
                      overlayMarkers: [
                        if (center != null)
                          MapMarkerData(
                            point: center,
                            icon: Icons.home_outlined,
                            color: Theme.of(context).colorScheme.secondary,
                            label: 'You',
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  for (final truck in trucks) TruckCard(truck: truck),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
