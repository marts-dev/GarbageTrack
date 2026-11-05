import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/dates.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/type_dots.dart';
import '../widgets/geo_map.dart';
import '../widgets/region_map.dart';
import '../widgets/route_preview.dart';
import 'facility_form_screen.dart';
import 'route_create_screen.dart';
import 'route_detail_screen.dart';
import 'truck_detail_screen.dart';
import 'truck_form_screen.dart';

class LogisticsHomeScreen extends StatelessWidget {
  const LogisticsHomeScreen(
      {super.key, this.tileProvider, this.regionBoundariesLoader});

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  /// Loads region boundary GeoJSON for an asset path. Defaults to the
  /// bundled asset; injectable so widget tests can bypass the asset bundle.
  final Future<String> Function(String asset)? regionBoundariesLoader;

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
            _OverviewTab(
              tileProvider: tileProvider,
              regionBoundariesLoader: regionBoundariesLoader,
            ),
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
  const _OverviewTab({this.tileProvider, this.regionBoundariesLoader});
  final TileProvider? tileProvider;
  final Future<String> Function(String asset)? regionBoundariesLoader;
  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  int _reload = 0;

  /// Dashboard data: the summary plus best-effort extras for the
  /// needs-attention section. The extras fail open to empty, so a broken
  /// routes/trucks call hides those rows instead of the dashboard.
  Future<
      ({
        GarbageSummary summary,
        List<PlannedRoute> routes,
        List<Truck> trucks
      })> _load(AuthProvider auth) {
    final summary = auth.logistics.garbageSummary(country: auth.country);
    final routes = auth.logistics
        .listRoutes()
        .then((r) => r, onError: (_) => <PlannedRoute>[]);
    final trucks =
        auth.trucks.listTrucks().then((t) => t, onError: (_) => <Truck>[]);
    return Future.wait([summary, routes, trucks]).then((all) => (
          summary: all[0] as GarbageSummary,
          routes: all[1] as List<PlannedRoute>,
          trucks: all[2] as List<Truck>,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return FutureBuilder(
      key: ValueKey(_reload),
      future: _load(auth),
      builder: (context, snapshot) => AsyncView<
          ({
            GarbageSummary summary,
            List<PlannedRoute> routes,
            List<Truck> trucks
          })>(
        snapshot: snapshot,
        onRetry: () => setState(() => _reload++),
        builder: (context, data) => RefreshIndicator(
          onRefresh: () async => setState(() => _reload++),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _NeedsAttentionSection(
                summary: data.summary,
                routes: data.routes,
                trucks: data.trucks,
                onChanged: () => setState(() => _reload++),
                tileProvider: widget.tileProvider,
              ),
              Card(
                margin: EdgeInsets.zero,
                color: Theme.of(context).colorScheme.primaryContainer,
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
                              '${data.summary.total}',
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer,
                                  ),
                            ),
                            Text(
                              'Total reports',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer,
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
              _RegionSection(
                country: auth.country,
                summary: data.summary,
                tileProvider: widget.tileProvider,
                regionBoundariesLoader: widget.regionBoundariesLoader,
              ),
              Text('By status', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final entry in data.summary.byStatus.entries)
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
              TypeCountRows(data.summary.byType),
            ],
          ),
        ),
      ),
    );
  }
}

/// Actionable items for the logistics user: unscheduled reports, overdue
/// routes, trucks without operators, and full trucks. Each row deep-links
/// to the screen that resolves it. Empty sources (or failed extra
/// fetches) simply contribute no rows; with nothing to show, an all-clear
/// card confirms the dashboard was checked.
class _NeedsAttentionSection extends StatelessWidget {
  const _NeedsAttentionSection({
    required this.summary,
    required this.routes,
    required this.trucks,
    required this.onChanged,
    this.tileProvider,
  });

  final GarbageSummary summary;
  final List<PlannedRoute> routes;
  final List<Truck> trucks;

  /// Refreshes the overview after an inline fix (e.g. assigning an
  /// operator from the unassigned row).
  final VoidCallback onChanged;
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = todayDay();
    final awaiting = summary.byStatus['posted'] ?? 0;
    final overdue = routes
        .where((r) =>
            (r.status == 'assigned' || r.status == 'in_progress') &&
            r.scheduledFor != null &&
            r.scheduledFor!.isBefore(today))
        .toList()
      ..sort((a, b) => a.scheduledFor!.compareTo(b.scheduledFor!));
    final unassigned = trucks.where((t) => t.operatorId == null).toList();
    final full = trucks
        .where((t) =>
            t.capacity != null && t.capacity! > 0 && t.load >= t.capacity!)
        .toList();
    final clear =
        awaiting == 0 && overdue.isEmpty && unassigned.isEmpty && full.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Needs attention', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (clear)
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: ListTile(
              leading: const CardIcon(icon: Icons.check_circle_outline),
              title: const Text('All clear'),
              subtitle: const Text('Nothing needs attention right now.'),
            ),
          )
        else ...[
          if (awaiting > 0)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const CardIcon(
                  icon: Icons.schedule_outlined,
                  status: 'scheduled',
                ),
                title: Text(
                  '$awaiting ${awaiting == 1 ? 'report' : 'reports'} awaiting routes',
                ),
                subtitle: const Text('Create a route to schedule them'),
                trailing: Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RouteCreateScreen()),
                ),
              ),
            ),
          for (final route in overdue)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const CardIcon(
                  icon: Icons.warning_amber_outlined,
                  status: 'overdue',
                ),
                title: Text(route.name ?? 'Route ${route.id}'),
                subtitle: Text(
                  '${_overdueLabel(today, route.scheduledFor!)} · '
                  '${route.stops.length} ${route.stops.length == 1 ? 'stop' : 'stops'}',
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RouteDetailScreen(
                      route: route,
                      tileProvider: tileProvider,
                    ),
                  ),
                ),
              ),
            ),
          for (final truck in unassigned)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const CardIcon(
                  icon: Icons.person_off_outlined,
                  status: 'available',
                ),
                title: Text(truck.plateNumber),
                subtitle: const Text('No operator assigned'),
                trailing: Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                ),
                // Logistics fixes this by assigning an operator, not by
                // opening the collector's operate screen.
                onTap: () async {
                  final saved = await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TruckFormScreen(existing: truck),
                    ),
                  );
                  if (saved == true) onChanged();
                },
              ),
            ),
          for (final truck in full)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const CardIcon(
                  icon: Icons.inventory_2_outlined,
                  status: 'full',
                ),
                title: Text(truck.plateNumber),
                subtitle: Text('Full · Load ${truck.load}/${truck.capacity}'),
                trailing: Icon(
                  Icons.chevron_right,
                  color: scheme.onSurfaceVariant,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TruckDetailScreen(
                      truckId: truck.id,
                      tileProvider: tileProvider,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  String _overdueLabel(DateTime today, DateTime scheduled) {
    final days = today.difference(scheduled).inDays;
    return '$days ${days == 1 ? 'day' : 'days'} overdue';
  }
}

/// Choropleth of report counts per region for countries with shipped
/// boundaries. Hidden otherwise (pills below still carry the totals).
/// Tapping a region opens its breakdown sheet.
class _RegionSection extends StatelessWidget {
  const _RegionSection({
    required this.country,
    required this.summary,
    this.tileProvider,
    this.regionBoundariesLoader,
  });

  final String? country;
  final GarbageSummary summary;
  final TileProvider? tileProvider;
  final Future<String> Function(String asset)? regionBoundariesLoader;

  void _showRegion(BuildContext context, String name) {
    final detail = summary.byRegion[name] ?? const RegionSummary(total: 0);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${detail.total} ${detail.total == 1 ? 'report' : 'reports'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (detail.total > 0) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in detail.byStatus.entries)
                    StatusPill(
                      label: '${pretty(entry.key)} · ${entry.value}',
                      status: entry.key,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TypeCountRows(detail.byType),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final asset = regionBoundariesFor(country);
    if (asset == null) return const SizedBox.shrink();
    return FutureBuilder(
      future:
          regionBoundariesLoader?.call(asset) ?? rootBundle.loadString(asset),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 120,
            child: LoadingView(label: 'Loading regions…'),
          );
        }
        // A missing/unreadable asset must never break the dashboard.
        if (!snapshot.hasData) return const SizedBox.shrink();
        final regions = parseRegionBoundaries(snapshot.data!);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('By region', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            RegionChoropleth(
              regions: regions,
              counts: {
                for (final entry in summary.byRegion.entries)
                  entry.key: entry.value.total,
              },
              onRegionTap: (name) => _showRegion(context, name),
              tileProvider: tileProvider,
            ),
            const SizedBox(height: 16),
          ],
        );
      },
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
            final located =
                trucks.where((t) => t.currentLocation != null).toList();
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
                        leading:
                            const CardIcon(icon: Icons.local_shipping_outlined),
                        title: Text(truck.plateNumber),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${pretty(truck.availability)}'
                              ' · ${truck.loadSummary}\n'
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
                              label:
                                  truck.isAssigned ? 'Assigned' : 'Unassigned',
                              status: truck.isAssigned ? 'done' : 'available',
                            ),
                            PopupMenuButton<String>(
                              onSelected: (action) async {
                                if (action == 'edit') {
                                  final saved =
                                      await Navigator.of(context).push(
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
                                PopupMenuItem(
                                    value: 'edit', child: Text('Edit')),
                                PopupMenuItem(
                                    value: 'delete', child: Text('Delete')),
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
                            PopupMenuItem(
                                value: 'delete', child: Text('Delete')),
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
                        title: Text(
                            route.name ?? 'Route ${route.id.substring(0, 6)}'),
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
