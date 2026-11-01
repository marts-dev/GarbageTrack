import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/country_viewports.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/type_dots.dart';
import '../widgets/geo_map.dart';
import '../widgets/inputs.dart';
import '../widgets/location_picker.dart';

class TruckDetailScreen extends StatelessWidget {
  const TruckDetailScreen({super.key, required this.truckId, this.tileProvider});

  final String truckId;

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Truck')),
      body: TruckDetailBody(truckId: truckId, tileProvider: tileProvider),
    );
  }
}

/// Truck detail content without the surrounding [Scaffold], so the collector
/// home screen can land directly on the assigned truck inside its own shell.
class TruckDetailBody extends StatefulWidget {
  const TruckDetailBody({super.key, required this.truckId, this.tileProvider});

  final String truckId;

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  @override
  State<TruckDetailBody> createState() => _TruckDetailBodyState();
}

class _TruckDetailBodyState extends State<TruckDetailBody> {
  int _reload = 0;
  bool _busy = false;

  Future<void> _setAvailability(String value) async {
    setState(() => _busy = true);
    try {
      final truck = await context
          .read<AuthProvider>()
          .trucks
          .setAvailability(widget.truckId, value);
      if (mounted) {
        showOk(context, 'Status: ${pretty(truck.availability)} (load ${truck.load})');
        setState(() => _reload++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return FutureBuilder(
      key: ValueKey(_reload),
      future: auth.trucks.getTruck(widget.truckId),
      builder: (context, snapshot) => AsyncView<Truck>(
        snapshot: snapshot,
        onRetry: () => setState(() => _reload++),
        builder: (context, truck) => DefaultTabController(
          length: 3,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Card(
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
                                truck.plateNumber,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            StatusPill(
                              label: pretty(truck.availability),
                              status: truck.availability,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            StatusPill(
                              label: pretty(truck.status),
                              status: truck.status,
                            ),
                            if (truck.capacity != null)
                              Chip(
                                label: Text(
                                    'Load ${truck.load}/${truck.capacity}'),
                              ),
                          ],
                        ),
                        if (truck.currentLocation != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            truck.currentLocation!.short,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          'Takes:',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        TypeChips(truck.garbageTypes),
                        if (auth.user?.isCollector ?? false) ...[
                          const SizedBox(height: 12),
                          _AssignmentRow(
                            truck: truck,
                            myId: auth.user!.id,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'Route'),
                  Tab(text: 'Collect'),
                  Tab(text: 'Status'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _RouteTab(
                      truck: truck,
                      tileProvider: widget.tileProvider,
                    ),
                    _CollectTab(
                      truck: truck,
                      tileProvider: widget.tileProvider,
                      // Collectors act only on their assigned truck; the API
                      // bypasses the binding check for logistics/admins.
                      assignedGuarded: auth.user?.role == 'collector' &&
                          !truck.isOperatedBy(auth.user!.id),
                      onChanged: () => setState(() => _reload++),
                    ),
                    _StatusTab(
                      truck: truck,
                      busy: _busy,
                      assignedGuarded: auth.user?.role == 'collector' &&
                          !truck.isOperatedBy(auth.user!.id),
                      onSelect: _setAvailability,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Operator binding banner for collector users. Logistics/admins assign the
/// operator from the truck form; collectors only see who holds the truck.
class _AssignmentRow extends StatelessWidget {
  const _AssignmentRow({required this.truck, required this.myId});

  final Truck truck;
  final String myId;

  @override
  Widget build(BuildContext context) {
    final mine = truck.isOperatedBy(myId);
    final pill = mine
        ? const StatusPill(label: 'Assigned to you', status: 'done')
        : truck.isAssigned
            ? const StatusPill(label: 'Assigned', status: 'full')
            : const StatusPill(label: 'Unassigned', status: 'available');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        pill,
        const SizedBox(height: 4),
        Text(
          mine
              ? 'Collect and change status from your truck.'
              : truck.isAssigned
                  ? 'Only the assigned operator can collect or change status on this truck.'
                  : 'Logistics assigns an operator to this truck.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _RouteTab extends StatefulWidget {
  const _RouteTab({required this.truck, this.tileProvider});
  final Truck truck;
  final TileProvider? tileProvider;

  @override
  State<_RouteTab> createState() => _RouteTabState();
}

class _RouteTabState extends State<_RouteTab> {
  final _types = <String>{};
  int _reload = 0;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: GarbageTypePicker(
            selected: _types,
            onChanged: (next) => setState(() {
              _types
                ..clear()
                ..addAll(next);
              _reload++;
            }),
          ),
        ),
        Expanded(
          child: FutureBuilder(
            key: ValueKey((_reload, _types.join(','))),
            future: auth.trucks.getRoute(
              widget.truck.id,
              types: _types.isEmpty ? null : _types.toList(),
            ),
            builder: (context, snapshot) => AsyncView<CollectionRoute>(
              snapshot: snapshot,
              onRetry: () => setState(() => _reload++),
              builder: (context, route) {
                if (route.stops.isEmpty) {
                  return const EmptyState(
                    icon: Icons.route_outlined,
                    title: 'No stops on this route.',
                    subtitle: 'Try clearing the type filter.',
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: route.stops.length + 2,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${route.stops.length} stops'
                          '${route.remainingCapacity != null ? ' · ${route.remainingCapacity} capacity left' : ''}',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      );
                    }
                    if (i == 1) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GarbageMapView(
                          tileProvider: widget.tileProvider,
                          markers: [
                            MapMarkerData(
                              point: route.origin,
                              icon: Icons.local_shipping,
                              label: 'Origin',
                            ),
                            for (final stop in route.stops)
                              MapMarkerData(
                                point: stop.location,
                                label: stop.types.map(pretty).join(', '),
                              ),
                          ],
                          // Road geometry when the API provided it, else
                          // straight origin -> stops lines.
                          polylines: [route.displayLine],
                        ),
                      );
                    }
                    final stop = route.stops[i - 2];
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(child: Text('${i - 1}')),
                        title: Row(
                          children: [
                            Expanded(
                                child: Text(stop.types.map(pretty).join(', '))),
                            TypeDots(stop.types),
                          ],
                        ),
                        subtitle: Text(
                          '${stop.location.short}'
                          '${stop.distanceMeters != null ? ' · ${stop.distanceMeters!.round()} m' : ''}',
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _CollectTab extends StatefulWidget {
  const _CollectTab(
      {required this.truck,
      required this.assignedGuarded,
      required this.onChanged,
      this.tileProvider});
  final Truck truck;

  /// True when a collector is not this truck's operator, so collecting is
  /// disabled. The API also rejects those calls with 403.
  final bool assignedGuarded;
  final VoidCallback onChanged;
  final TileProvider? tileProvider;

  @override
  State<_CollectTab> createState() => _CollectTabState();
}

class _CollectTabState extends State<_CollectTab> {
  final _radius = TextEditingController(text: '500');
  GeoPoint? _point;
  bool _busy = false;
  CollectResult? _result;

  @override
  void dispose() {
    _radius.dispose();
    super.dispose();
  }

  Future<void> _collect() async {
    final radius = double.tryParse(_radius.text.trim());
    if (radius == null || radius <= 0) {
      showError(context, 'Enter a valid radius in meters');
      return;
    }
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final result =
          await context.read<AuthProvider>().trucks.collectVicinity(
                widget.truck.id,
                longitude: _point?.longitude,
                latitude: _point?.latitude,
                radiusMeters: radius,
              );
      if (mounted) {
        setState(() => _result = result);
        widget.onChanged();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final viewport =
        viewportFor(context.watch<AuthProvider>().country);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.assignedGuarded) ...[
          Card(
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Only the assigned operator can collect on this truck.'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          'Marks posted garbage near a point as collected. Leave the position empty to use the truck location.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Text('Position (optional)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        LocationMapPicker(
          onChanged: (point) => setState(() => _point = point),
          fallbackCenter: viewport.center,
          fallbackZoom: viewport.zoom,
          tileProvider: widget.tileProvider,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _radius,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Radius (meters)',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: (_busy || widget.assignedGuarded) ? null : _collect,
          child: _busy
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Collect vicinity'),
        ),
        if (result != null) ...[
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Result', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  InfoRow(label: 'Collected', value: '${result.collectedCount} posts'),
                  InfoRow(label: 'Load', value: '${result.load}'),
                  InfoRow(label: 'Status', value: pretty(result.availability)),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StatusTab extends StatelessWidget {
  const _StatusTab(
      {required this.truck,
      required this.busy,
      required this.assignedGuarded,
      required this.onSelect});

  final Truck truck;
  final bool busy;

  /// True when a collector is not this truck's operator, so status changes
  /// are disabled. The API also rejects those calls with 403.
  final bool assignedGuarded;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (assignedGuarded) ...[
          Card(
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Only the assigned operator can change status on this truck.'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Returning to Available resets the load to zero.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        RadioGroup<String>(
          groupValue: truck.availability,
          onChanged: (v) {
            if (!busy && !assignedGuarded && v != null) onSelect(v);
          },
          child: Column(
            children: [
              for (final value in truckAvailabilities)
                Card(
                  child: RadioListTile<String>(
                    title: Text(pretty(value)),
                    value: value,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
