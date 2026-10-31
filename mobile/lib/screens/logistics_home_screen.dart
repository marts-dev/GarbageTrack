import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/geo_map.dart';
import 'facility_form_screen.dart';
import 'route_create_screen.dart';

class LogisticsHomeScreen extends StatelessWidget {
  const LogisticsHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Logistics'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Trucks'),
              Tab(text: 'Facilities'),
              Tab(text: 'Routes'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _OverviewTab(),
            _TrucksTab(),
            _FacilitiesTab(),
            _RoutesTab(),
          ],
        ),
      ),
    );
  }
}

class _OverviewTab extends StatefulWidget {
  const _OverviewTab();
  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  int _reload = 0;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return FutureBuilder(
      key: ValueKey(_reload),
      future: auth.logistics.garbageSummary(),
      builder: (context, snapshot) => AsyncView<GarbageSummary>(
        snapshot: snapshot,
        onRetry: () => setState(() => _reload++),
        builder: (context, summary) => RefreshIndicator(
          onRefresh: () async => setState(() => _reload++),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const CardIcon(icon: Icons.delete_outline),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${summary.total}',
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            Text(
                              'Total reports',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('By status', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final entry in summary.byStatus.entries)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: StatusPill(
                      label: pretty(entry.key),
                      status: entry.key,
                    ),
                    trailing: Text(
                      '${entry.value}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text('By type', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in summary.byType.entries)
                    Chip(label: Text('${pretty(entry.key)} · ${entry.value}')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrucksTab extends StatefulWidget {
  const _TrucksTab();
  @override
  State<_TrucksTab> createState() => _TrucksTabState();
}

class _TrucksTabState extends State<_TrucksTab> {
  int _reload = 0;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return FutureBuilder(
      key: ValueKey(_reload),
      future: auth.logistics.truckLocations(),
      builder: (context, snapshot) => AsyncView<List<Truck>>(
        snapshot: snapshot,
        onRetry: () => setState(() => _reload++),
        builder: (context, trucks) {
          if (trucks.isEmpty) {
            return RefreshableEmpty(
              onRefresh: () async => setState(() => _reload++),
              empty: const EmptyState(
                icon: Icons.local_shipping_outlined,
                title: 'No trucks yet.',
              ),
            );
          }
          final located = trucks.where((t) => t.currentLocation != null).toList();
          return RefreshIndicator(
            onRefresh: () async => setState(() => _reload++),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (located.isNotEmpty) ...[
                  GarbageMapView(
                    markers: [
                      for (final truck in located)
                        MapMarkerData(
                          point: truck.currentLocation!,
                          icon: Icons.local_shipping,
                          label: truck.plateNumber,
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
    );
  }
}

class _FacilitiesTab extends StatefulWidget {
  const _FacilitiesTab();
  @override
  State<_FacilitiesTab> createState() => _FacilitiesTabState();
}

IconData _facilityIcon(String kind) => switch (kind) {
      'recycling' => Icons.recycling,
      'waste_center' => Icons.factory_outlined,
      _ => Icons.delete_outline,
    };

class _FacilitiesTabState extends State<_FacilitiesTab> {
  int _reload = 0;

  Future<void> _delete(Facility facility) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete facility?'),
        content: Text('${facility.name} will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await context.read<AuthProvider>().logistics.deleteFacility(facility.id);
      if (mounted) {
        showOk(context, 'Facility deleted');
        setState(() => _reload++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Facility'),
        onPressed: () async {
          final created = await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const FacilityFormScreen()),
          );
          if (created == true && mounted) setState(() => _reload++);
        },
      ),
      body: FutureBuilder(
        key: ValueKey(_reload),
        future: auth.logistics.listFacilities(),
        builder: (context, snapshot) => AsyncView<List<Facility>>(
          snapshot: snapshot,
          onRetry: () => setState(() => _reload++),
          builder: (context, facilities) {
            if (facilities.isEmpty) {
              return RefreshableEmpty(
                onRefresh: () async => setState(() => _reload++),
                empty: const EmptyState(
                  icon: Icons.factory_outlined,
                  title: 'No facilities yet.',
                  subtitle: 'Use the Facility button to add one.',
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: () async => setState(() => _reload++),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                children: [
                  GarbageMapView(
                    markers: [
                      for (final facility in facilities)
                        MapMarkerData(
                          point: facility.location,
                          icon: _facilityIcon(facility.kind),
                          label: facility.name,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final facility in facilities)
                    Card(
                      child: ListTile(
                        leading: CardIcon(icon: _facilityIcon(facility.kind)),
                        title: Text(facility.name),
                        subtitle: Text(
                          '${pretty(facility.kind)} · ${facility.location.short}\nTakes: ${facility.acceptedTypes.map(pretty).join(', ')}',
                        ),
                        isThreeLine: true,
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) async {
                            if (action == 'edit') {
                              final saved = await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      FacilityFormScreen(existing: facility),
                                ),
                              );
                              if (saved == true && context.mounted) {
                                setState(() => _reload++);
                              }
                            } else {
                              await _delete(facility);
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _RoutesTab extends StatefulWidget {
  const _RoutesTab();
  @override
  State<_RoutesTab> createState() => _RoutesTabState();
}

class _RoutesTabState extends State<_RoutesTab> {
  int _reload = 0;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Route'),
        onPressed: () async {
          final created = await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const RouteCreateScreen()),
          );
          if (created == true && mounted) setState(() => _reload++);
        },
      ),
      body: FutureBuilder(
        key: ValueKey(_reload),
        future: auth.logistics.listRoutes(),
        builder: (context, snapshot) => AsyncView<List<PlannedRoute>>(
          snapshot: snapshot,
          onRetry: () => setState(() => _reload++),
          builder: (context, routes) {
            if (routes.isEmpty) {
              return RefreshableEmpty(
                onRefresh: () async => setState(() => _reload++),
                empty: const EmptyState(
                  icon: Icons.route_outlined,
                  title: 'No routes yet.',
                  subtitle: 'Use the Route button to assign one.',
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: () async => setState(() => _reload++),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                children: [
                  GarbageMapView(
                    markers: [
                      for (final route in routes) ...[
                        MapMarkerData(
                          point: route.origin,
                          icon: Icons.local_shipping,
                          label: 'Origin: ${route.name ?? route.id}',
                        ),
                        for (final stop in route.stops)
                          MapMarkerData(
                            point: stop.location,
                            label: 'Stop ${stop.postId}',
                          ),
                      ],
                    ],
                    polylines: [
                      for (final route in routes)
                        [route.origin, for (final stop in route.stops) stop.location],
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final route in routes)
                    Card(
                      child: ListTile(
                        leading: const CardIcon(icon: Icons.route_outlined),
                        title:
                            Text(route.name ?? 'Route ${route.id.substring(0, 6)}'),
                        subtitle: Text(
                          '${pretty(route.status)} · ${route.stops.length} stops · from ${route.origin.short}',
                        ),
                        trailing: StatusPill(
                          label: pretty(route.status),
                          status: route.status,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
