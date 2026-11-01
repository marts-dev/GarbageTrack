import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/type_dots.dart';
import '../widgets/geo_map.dart';
import '../widgets/route_preview.dart';
import 'facility_form_screen.dart';
import 'route_create_screen.dart';
import 'route_detail_screen.dart';
import 'truck_form_screen.dart';

class LogisticsHomeScreen extends StatelessWidget {
  const LogisticsHomeScreen({super.key, this.tileProvider});

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Logistics'),
          actions: [
            Builder(
              builder: (context) => IconButton(
                tooltip: 'Sign out',
                icon: const Icon(Icons.logout_outlined),
                onPressed: () => context.read<AuthProvider>().logout(),
              ),
            ),
          ],
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
        body: TabBarView(
          children: [
            const _OverviewTab(),
            _TrucksTab(tileProvider: tileProvider),
            _FacilitiesTab(tileProvider: tileProvider),
            _RoutesTab(tileProvider: tileProvider),
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
  const _TrucksTab({this.tileProvider});
  final TileProvider? tileProvider;
  @override
  State<_TrucksTab> createState() => _TrucksTabState();
}

class _TrucksTabState extends State<_TrucksTab> {
  int _reload = 0;

  Future<void> _delete(Truck truck) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete truck?'),
        content: Text('${truck.plateNumber} will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await context.read<AuthProvider>().trucks.deleteTruck(truck.id);
      if (mounted) {
        showOk(context, 'Truck deleted');
        setState(() => _reload++);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 404) {
        showError(context, 'Truck not found');
        setState(() => _reload++);
      } else {
        showError(context, e);
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
        label: const Text('Truck'),
        onPressed: () async {
          final created = await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TruckFormScreen()),
          );
          if (created == true && mounted) setState(() => _reload++);
        },
      ),
      body: FutureBuilder(
        key: ValueKey(_reload),
        future: auth.trucks.listTrucks(),
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
                  subtitle: 'Use the Truck button to add one.',
                ),
              );
            }
            final located = trucks.where((t) => t.currentLocation != null).toList();
            return RefreshIndicator(
              onRefresh: () async => setState(() => _reload++),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                children: [
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
                    ),
                    const SizedBox(height: 8),
                  ],
                  for (final truck in trucks)
                    Card(
                      child: ListTile(
                        leading: const CardIcon(icon: Icons.local_shipping_outlined),
                        title: Text(truck.plateNumber),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${pretty(truck.status)} · ${pretty(truck.availability)}'
                              '${truck.capacity != null ? ' · Load ${truck.load}/${truck.capacity}' : ''}\n'
                              '${truck.isAssigned ? 'Operator assigned' : 'No operator'} · Takes:',
                            ),
                            const SizedBox(height: 4),
                            TypeChips(truck.garbageTypes),
                          ],
                        ),
                        isThreeLine: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            StatusPill(
                              label: truck.isAssigned ? 'Assigned' : 'Unassigned',
                              status: truck.isAssigned ? 'done' : 'available',
                            ),
                            PopupMenuButton<String>(
                              onSelected: (action) async {
                                if (action == 'edit') {
                                  final saved = await Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          TruckFormScreen(existing: truck),
                                    ),
                                  );
                                  if (saved == true && context.mounted) {
                                    setState(() => _reload++);
                                  }
                                } else {
                                  await _delete(truck);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(value: 'edit', child: Text('Edit')),
                                PopupMenuItem(value: 'delete', child: Text('Delete')),
                              ],
                            ),
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

class _FacilitiesTab extends StatefulWidget {
  const _FacilitiesTab({this.tileProvider});
  final TileProvider? tileProvider;
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
                    tileProvider: widget.tileProvider,
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
  const _RoutesTab({this.tileProvider});
  final TileProvider? tileProvider;
  @override
  State<_RoutesTab> createState() => _RoutesTabState();
}

class _RoutesTabState extends State<_RoutesTab> {
  int _reload = 0;

  Future<void> _delete(PlannedRoute route) async {
    final label = route.name ?? 'Route ${route.id}';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete route?'),
        content: Text(
            '$label will be removed and its scheduled stops return to posted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await context.read<AuthProvider>().logistics.deleteRoute(route.id);
      if (mounted) {
        showOk(context, 'Route deleted');
        setState(() => _reload++);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 404) {
        showError(context, 'Route not found');
        setState(() => _reload++);
      } else {
        showError(context, e);
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
                  for (final route in routes)
                    Card(
                      child: ListTile(
                        leading: RouteGraphPreview(route, size: 56),
                        title:
                            Text(route.name ?? 'Route ${route.id.substring(0, 6)}'),
                        subtitle: Text(
                          '${pretty(route.status)} · ${route.stops.length} stops · from ${route.origin.short}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            StatusPill(
                              label: pretty(route.status),
                              status: route.status,
                            ),
                            IconButton(
                              tooltip: 'Delete route',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(route),
                            ),
                          ],
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RouteDetailScreen(
                              route: route,
                              tileProvider: widget.tileProvider,
                            ),
                          ),
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
