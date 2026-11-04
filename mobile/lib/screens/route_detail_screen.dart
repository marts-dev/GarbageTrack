import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/dates.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/geo_map.dart';
import '../widgets/type_dots.dart';

/// Full route view: expandable summary header, the route layered on an
/// OpenStreetMap, then the stop list. Reached by tapping a route in the
/// logistics Routes tab.
class RouteDetailScreen extends StatefulWidget {
  const RouteDetailScreen({super.key, required this.route, this.tileProvider});

  final PlannedRoute route;
  final TileProvider? tileProvider;

  @override
  State<RouteDetailScreen> createState() => _RouteDetailScreenState();
}

class _RouteDetailScreenState extends State<RouteDetailScreen> {
  /// Depots + truck, shared by the header summary and the map. Hoisted so a
  /// header expand/collapse never refetches it.
  Future<_RouteMapData>? _mapFuture;

  bool _expanded = false;

  /// Collector directory for the expanded header's operator row. Loads on
  /// first expansion only, and only when the truck has an operator.
  Future<List<User>>? _collectorsFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mapFuture ??= _loadMapData(context.read<AuthProvider>());
  }

  Future<_RouteMapData> _loadMapData(AuthProvider auth) async {
    final route = widget.route;
    var depots = const <Facility>[];
    if (route.depotIds.isNotEmpty) {
      try {
        final facilities = await auth.logistics.listFacilities(limit: 200);
        final wanted = route.depotIds.toSet();
        depots = facilities.where((f) => wanted.contains(f.id)).toList();
      } catch (_) {
        // Depot names are decoration; the map and stops render regardless.
      }
    }
    Truck? truck;
    try {
      truck = await auth.trucks.getTruck(route.truckId);
    } catch (_) {
      // The truck row and live position are decoration; the route renders
      // regardless.
    }
    return _RouteMapData(depots: depots, truck: truck);
  }

  Future<List<User>> _collectors(AuthProvider auth) =>
      _collectorsFuture ??= auth.auth.listUsers(role: 'collector');

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final route = widget.route;
    return Scaffold(
      appBar: AppBar(title: Text(route.name ?? 'Route ${route.id}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FutureBuilder(
            future: _mapFuture,
            builder: (context, snapshot) {
              final data = snapshot.data;
              final operatorId = data?.truck?.operatorId;
              return _HeaderCard(
                route: route,
                truck: data?.truck,
                depots: data?.depots ?? const [],
                expanded: _expanded,
                onToggle: () => setState(() => _expanded = !_expanded),
                collectorFuture:
                    (_expanded && operatorId != null) ? _collectors(auth) : null,
                operatorId: operatorId,
                onRetryCollector: () => setState(() {
                  _collectorsFuture = auth.auth.listUsers(role: 'collector');
                }),
              );
            },
          ),
          const SizedBox(height: 12),
          FutureBuilder(
            future: _mapFuture,
            builder: (context, snapshot) {
              // Wait for depots and the truck so the map's initial camera
              // fit includes every pin; the camera deliberately never
              // refits afterwards.
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(height: 320, child: LoadingView());
              }
              final data = snapshot.data ?? const _RouteMapData(depots: []);
              final depots = data.depots;
              final scheme = Theme.of(context).colorScheme;
              return RouteMapView(
                height: 320,
                tileProvider: widget.tileProvider,
                origin: route.origin,
                live: data.truck?.currentLocation,
                stopMarkers: [
                  for (final stop in route.stops)
                    MapMarkerData(
                      point: stop.location,
                      color: stop.types.isEmpty
                          ? null
                          : garbageTypeColor(
                              stop.types.first, scheme.brightness),
                      label: 'Stop: ${stop.types.map(pretty).join(', ')}',
                    ),
                ],
                extraMarkers: [
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
                displayLine: route.displayLine,
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

/// Summary header: counts and names up front, full assignment details behind
/// a tap. The collector row resolves lazily via [collectorFuture], which is
/// null until the header expands with a known operator.
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.route,
    required this.truck,
    required this.depots,
    required this.expanded,
    required this.onToggle,
    required this.collectorFuture,
    required this.operatorId,
    required this.onRetryCollector,
  });

  final PlannedRoute route;
  final Truck? truck;
  final List<Facility> depots;
  final bool expanded;
  final VoidCallback onToggle;
  final Future<List<User>>? collectorFuture;
  final String? operatorId;
  final VoidCallback onRetryCollector;

  /// Depot names in route order, tagging the first pick as the route end.
  /// Falls back to the id count while names are still loading or unknown.
  String _depotSummary() {
    if (depots.isEmpty) {
      return route.depotIds.isEmpty
          ? 'None'
          : '${route.depotIds.length} depot(s)';
    }
    final byId = {for (final depot in depots) depot.id: depot.name};
    final names = [
      for (final id in route.depotIds)
        if (byId.containsKey(id)) byId[id]!,
    ];
    if (names.isEmpty) return '${route.depotIds.length} depot(s)';
    return [
      '${names.first} (End)',
      for (final name in names.skip(1)) name,
    ].join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final truck = this.truck;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(12),
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
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  StatusPill(
                    label: pretty(route.status),
                    status: route.status,
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: expanded ? 'Show less' : 'Show more',
                    child: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (truck != null || depots.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  [
                    if (truck != null) truck.plateNumber,
                    if (depots.isNotEmpty)
                      depots.map((depot) => depot.name).join(', '),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (expanded) ...[
                const Divider(height: 24),
                _CollectorRow(
                  truck: truck,
                  operatorId: operatorId,
                  collectorFuture: collectorFuture,
                  onRetry: onRetryCollector,
                ),
                InfoRow(
                  label: 'Truck',
                  value: truck == null
                      ? 'Unavailable'
                      : '${truck.plateNumber} · ${pretty(truck.availability)}',
                ),
                InfoRow(label: 'Depots', value: _depotSummary()),
                InfoRow(
                  label: 'Route',
                  value: route.geometrySource == 'road'
                      ? 'Road-following'
                      : 'Straight-line',
                ),
                if (route.scheduledFor != null)
                  InfoRow(
                    label: 'Scheduled',
                    value: formatDay(route.scheduledFor!),
                  ),
                if (route.collectionPoints.isNotEmpty)
                  InfoRow(
                    label: 'Collection points',
                    value: '${route.collectionPoints.length}',
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Operator row for the expanded header. No fetch happens until the header
/// expands with a known operator id; failures show a retry inline.
class _CollectorRow extends StatelessWidget {
  const _CollectorRow({
    required this.truck,
    required this.operatorId,
    required this.collectorFuture,
    required this.onRetry,
  });

  final Truck? truck;
  final String? operatorId;
  final Future<List<User>>? collectorFuture;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final operatorId = this.operatorId;
    if (truck == null) {
      return const InfoRow(label: 'Collector', value: 'Unavailable');
    }
    if (operatorId == null) {
      return const InfoRow(label: 'Collector', value: 'Unassigned');
    }
    return FutureBuilder(
      future: collectorFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const InfoRow(label: 'Collector', value: 'Loading…');
        }
        if (snapshot.hasError) {
          return Row(
            children: [
              const Expanded(
                child: InfoRow(
                    label: 'Collector', value: "Couldn't load operator"),
              ),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          );
        }
        User? match;
        for (final user in snapshot.data ?? const <User>[]) {
          if (user.id == operatorId) {
            match = user;
            break;
          }
        }
        return InfoRow(
          label: 'Collector',
          value: match?.displayName ?? 'Unknown operator',
        );
      },
    );
  }
}

/// Decorative map extras loaded after the route: depot pins and the truck.
/// Either may be missing; the route renders regardless.
class _RouteMapData {
  const _RouteMapData({required this.depots, this.truck});

  final List<Facility> depots;
  final Truck? truck;
}
