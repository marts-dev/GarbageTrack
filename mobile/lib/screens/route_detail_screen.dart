import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/geo_map.dart';
import '../widgets/type_dots.dart';

/// Full route view: summary, the route layered on an OpenStreetMap, then the
/// stop list. Reached by tapping a route in the logistics Routes tab.
class RouteDetailScreen extends StatelessWidget {
  const RouteDetailScreen({super.key, required this.route, this.tileProvider});

  final PlannedRoute route;
  final TileProvider? tileProvider;

  Future<List<Facility>> _depots(AuthProvider auth) async {
    if (route.depotIds.isEmpty) return const [];
    try {
      final facilities = await auth.logistics.listFacilities(limit: 200);
      final wanted = route.depotIds.toSet();
      return facilities.where((f) => wanted.contains(f.id)).toList();
    } catch (_) {
      // Depot names are decoration; the map and stops render regardless.
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(route.name ?? 'Route ${route.id}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${route.stops.length} stops · ${route.depotIds.length} depot(s)',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      StatusPill(
                        label: pretty(route.status),
                        status: route.status,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    route.geometrySource == 'road'
                        ? 'Road-following route'
                        : 'Straight-line route',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (route.collectionPoints.isNotEmpty)
                    Text(
                      '${route.collectionPoints.length} collection point(s)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FutureBuilder(
            future: _depots(auth),
            builder: (context, snapshot) {
              // Wait for depots so the map's initial camera fit includes
              // every pin; the camera deliberately never refits afterwards.
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(height: 320, child: LoadingView());
              }
              final depots = snapshot.data ?? const <Facility>[];
              final scheme = Theme.of(context).colorScheme;
              return GarbageMapView(
                height: 320,
                tileProvider: tileProvider,
                markers: [
                  MapMarkerData(
                    point: route.origin,
                    icon: Icons.local_shipping,
                    color: scheme.primary,
                    label: 'Start: truck position',
                  ),
                  for (final stop in route.stops)
                    MapMarkerData(
                      point: stop.location,
                      color: stop.types.isEmpty
                          ? null
                          : garbageTypeColor(
                              stop.types.first, scheme.brightness),
                      label: 'Stop: ${stop.types.map(pretty).join(', ')}',
                    ),
                  for (final point in route.collectionPoints)
                    MapMarkerData(
                      point: point,
                      icon: Icons.flag,
                      color: scheme.tertiary,
                      label: 'Collection point',
                    ),
                  for (final depot in depots)
                    MapMarkerData(
                      point: depot.location,
                      icon: Icons.home_work,
                      color: scheme.secondary,
                      label: 'Depot: ${depot.name}',
                    ),
                ],
                polylines: [route.displayLine],
              );
            },
          ),
          const SizedBox(height: 12),
          Text('Stops (${route.stops.length})',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (var i = 0; i < route.stops.length; i++)
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                          route.stops[i].types.map(pretty).join(', ')),
                    ),
                    TypeDots(route.stops[i].types),
                  ],
                ),
                subtitle: Text(
                  '${route.stops[i].location.short}'
                  '${route.stops[i].distanceMeters != null ? ' · ${route.stops[i].distanceMeters!.round()} m' : ''}',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
