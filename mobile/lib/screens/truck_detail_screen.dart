import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/country_viewports.dart';
import '../utils/dates.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/type_dots.dart';
import '../widgets/geo_map.dart';
import '../widgets/inputs.dart';
import '../widgets/location_picker.dart';

class TruckDetailScreen extends StatelessWidget {
  const TruckDetailScreen(
      {super.key,
      required this.truckId,
      this.tileProvider,
      this.positionProvider});

  final String truckId;

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  /// Overrides GPS lookup (e.g. a fixed position in widget tests).
  final Future<Position> Function()? positionProvider;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Truck')),
      body: TruckDetailBody(
        truckId: truckId,
        tileProvider: tileProvider,
        positionProvider: positionProvider,
      ),
    );
  }
}

/// Truck detail content without the surrounding [Scaffold], so the collector
/// home screen can land directly on the assigned truck inside its own shell.
class TruckDetailBody extends StatefulWidget {
  const TruckDetailBody(
      {super.key,
      required this.truckId,
      this.tileProvider,
      this.positionProvider});

  final String truckId;

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  /// Overrides GPS lookup (e.g. a fixed position in widget tests).
  final Future<Position> Function()? positionProvider;

  @override
  State<TruckDetailBody> createState() => _TruckDetailBodyState();
}

class _TruckDetailBodyState extends State<TruckDetailBody> {
  int _routeReload = 0;
  bool _busy = false;

  /// Hoisted truck future: creating it in [build] would resubscribe the
  /// [FutureBuilder] on every [setState], flashing the loader and wiping
  /// tab state (including the loaded route). Only retry and truck switches
  /// replace it.
  late Future<Truck> _truckFuture;

  /// Latest truck known from a mutation response. Mutations refresh the
  /// header from their own response instead of replacing [_truckFuture],
  /// so tab state (loaded route, type filter, collect form) survives a
  /// share/status/collect action.
  Truck? _freshTruck;

  @override
  void initState() {
    super.initState();
    _truckFuture = _fetchTruck();
  }

  @override
  void didUpdateWidget(covariant TruckDetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.truckId != oldWidget.truckId) {
      _freshTruck = null;
      _truckFuture = _fetchTruck();
    }
  }

  Future<Truck> _fetchTruck() =>
      context.read<AuthProvider>().trucks.getTruck(widget.truckId);

  Future<void> _shareLocation() async {
    final api = context.read<AuthProvider>().trucks;
    setState(() => _busy = true);
    try {
      final locate = widget.positionProvider ?? requestCurrentPosition;
      final position = await locate();
      final truck = await api.updateLocation(
        widget.truckId,
        longitude: position.longitude,
        latitude: position.latitude,
      );
      if (mounted) {
        showOk(context,
            'Truck location updated (${truck.currentLocation!.short})');
        // Header only: the ping must not re-anchor the loaded route, so
        // the route tab is deliberately left untouched here.
        setState(() => _freshTruck = truck);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Closes the truck's active run. Availability is process-owned now, so
  /// this is the only way a truck returns to unscheduled from the UI.
  Future<void> _finishRoute() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finish run?'),
        content: const Text(
            'This closes the active run and frees the truck. Unfinished stops '
            'return to posted; collected posts are untouched.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Finish'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final truck =
          await context.read<AuthProvider>().trucks.finishRoute(widget.truckId);
      if (mounted) {
        showOk(
            context, 'Run finished. Truck is ${pretty(truck.availability)}.');
        // The run is gone, so the route tab refetches (empty state) while
        // the rest of the tab state is kept.
        setState(() {
          _freshTruck = truck;
          _routeReload++;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Refreshes the header after a vicinity collect and refetches the
  /// route so collected posts drop out of the stop list.
  Future<void> _refreshAfterCollect() async {
    try {
      final truck =
          await context.read<AuthProvider>().trucks.getTruck(widget.truckId);
      if (!mounted) return;
      setState(() {
        _freshTruck = truck;
        _routeReload++;
      });
    } catch (_) {
      // The collect itself already succeeded (its result card shows in
      // the tab); still refetch the route, which surfaces its own error
      // UI if the network is actually down.
      if (mounted) setState(() => _routeReload++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return FutureBuilder(
      future: _truckFuture,
      builder: (context, snapshot) => AsyncView<Truck>(
        snapshot: snapshot,
        onRetry: () => setState(() {
          _freshTruck = null;
          _truckFuture = _fetchTruck();
        }),
        builder: (context, loaded) {
          final truck = _freshTruck ?? loaded;
          return DefaultTabController(
          length: 2,
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
                        Chip(
                          label: Text(truck.loadSummary),
                        ),
                        if (truck.currentLocation != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            truck.currentLocation!.short,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                          // Header actions share one row so the header keeps its
                          // height and the tab body below keeps its space.
                          if ((auth.user?.isCollector == true &&
                                      truck.isOperatedBy(auth.user!.id)) ||
                                  (truck.availability == 'working' &&
                                      (auth.user?.isCollector != true ||
                                          truck.isOperatedBy(
                                              auth.user!.id)))) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (auth.user?.isCollector == true &&
                                    truck.isOperatedBy(auth.user!.id))
                                  FilledButton.tonalIcon(
                                    onPressed:
                                        _busy ? null : _shareLocation,
                                    icon: const Icon(
                                        Icons.my_location_outlined),
                                    label:
                                        const Text('Share my location'),
                                  ),
                                // A working truck has an active run.
                                // Collectors see this only on their own
                                // truck; the API also rejects other
                                // operators with 403.
                                if (truck.availability == 'working' &&
                                    (auth.user?.isCollector != true ||
                                        truck.isOperatedBy(auth.user!.id)))
                                  FilledButton.tonalIcon(
                                    onPressed: _busy ? null : _finishRoute,
                                    icon:
                                        const Icon(Icons.flag_outlined),
                                    label: const Text('Finish run'),
                                  ),
                              ],
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
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _RouteTab(
                      truck: truck,
                      tileProvider: widget.tileProvider,
                        extraReload: _routeReload,
                    ),
                    _CollectTab(
                      truck: truck,
                      tileProvider: widget.tileProvider,
                      positionProvider: widget.positionProvider,
                      // Collectors act only on their assigned truck; the API
                      // bypasses the binding check for logistics/admins.
                      assignedGuarded: auth.user?.role == 'collector' &&
                          !truck.isOperatedBy(auth.user!.id),
                        onChanged: _refreshAfterCollect,
                    ),
                  ],
                ),
              ),
            ],
          ),
          );
        },
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
              ? 'Collect and finish runs from your truck.'
              : truck.isAssigned
                  ? 'Only the assigned operator can collect or finish runs on this truck.'
                  : 'Logistics assigns an operator to this truck.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _RouteTab extends StatefulWidget {
  const _RouteTab(
      {required this.truck, this.tileProvider, required this.extraReload});
  final Truck truck;
  final TileProvider? tileProvider;

  /// Bumped by the parent when the route must refetch (collect,
  /// availability) so collected stops drop out. Location pings
  /// deliberately leave it alone so the loaded route is never disturbed.
  final int extraReload;

  @override
  State<_RouteTab> createState() => _RouteTabState();
}

class _RouteTabState extends State<_RouteTab> {
  /// Hoisted route future: creating it in [build] would resubscribe the
  /// [FutureBuilder] on every parent rebuild (e.g. a location ping
  /// refreshing the header). It is replaced only for a new truck, an
  /// explicit parent reload signal, or retry.
  late Future<PlannedRoute?> _routeFuture;

  @override
  void initState() {
    super.initState();
    _routeFuture = _loadRoute();
  }

  @override
  void didUpdateWidget(covariant _RouteTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.truck.id != oldWidget.truck.id ||
        widget.extraReload != oldWidget.extraReload) {
      _routeFuture = _loadRoute();
    }
  }

  /// The truck's assigned plan. Null (no plan yet) is a valid outcome, so
  /// the builder below handles states manually instead of [AsyncView],
  /// which treats null data as missing.
  Future<PlannedRoute?> _loadRoute() =>
      context.read<AuthProvider>().trucks.getPlannedRoute(widget.truck.id);

  RouteMapView _routeMap(BuildContext context, PlannedRoute route) {
    final scheme = Theme.of(context).colorScheme;
    return RouteMapView(
      tileProvider: widget.tileProvider,
      origin: route.origin,
      live: widget.truck.currentLocation,
      stopMarkers: [
        for (final stop in route.stops)
          MapMarkerData(
            point: stop.location,
            color: stop.types.isEmpty
                ? null
                : garbageTypeColor(stop.types.first, scheme.brightness),
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
        for (final depot in route.depots)
          MapMarkerData(
            point: depot.location,
            icon: Icons.home_work,
            color: scheme.secondary,
            label: 'Depot: ${depot.name}',
          ),
      ],
      displayLine: route.displayLine,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _routeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const LoadingView();
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          return ErrorView(
            message:
                error is ApiException ? error.message : error.toString(),
            onRetry: () => setState(() => _routeFuture = _loadRoute()),
          );
        }
        final route = snapshot.data;
        if (route == null) {
          return const EmptyState(
            icon: Icons.route_outlined,
            title: 'No route assigned.',
            subtitle: 'Ask logistics to assign one.',
          );
        }
        if (route.stops.isEmpty) {
          // The map still renders (origin + live truck position) so the
          // collector sees where the route starts; only the stop list is
          // replaced by the empty notice.
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _AssignedRouteHeader(route: route),
              const SizedBox(height: 8),
              _routeMap(context, route),
              const SizedBox(height: 8),
              const EmptyState(
                icon: Icons.route_outlined,
                title: 'No stops on this route.',
                subtitle: 'All assigned stops are collected.',
              ),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _AssignedRouteHeader(route: route),
            const SizedBox(height: 8),
            _routeMap(context, route),
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
            if (route.depots.isNotEmpty)
              Card(
                child: ListTile(
                  leading: const CardIcon(icon: Icons.home_work),
                  title: Text('Ends at ${route.depots.last.name}'),
                  subtitle: route.depots.length > 1
                      ? Text(route.depots
                          .skip(1)
                          .map((depot) => depot.name)
                          .join(', '))
                      : null,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Assigned-plan header: route name, status, and counts.
class _AssignedRouteHeader extends StatelessWidget {
  const _AssignedRouteHeader({required this.route});

  final PlannedRoute route;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                route.name ?? 'Assigned route',
                style: theme.textTheme.titleMedium,
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
          [
            '${route.stops.length} stops',
            '${route.depotIds.length} depot(s)',
            if (route.scheduledFor != null) formatDay(route.scheduledFor!),
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Whole radii without decimals ("30 m", not "30.0 m").
String _radiusText(double radius) =>
    radius == radius.roundToDouble() ? '${radius.toInt()}' : '$radius';

class _CollectTab extends StatefulWidget {
  const _CollectTab(
      {required this.truck,
      required this.assignedGuarded,
      required this.onChanged,
      this.tileProvider,
      this.positionProvider});
  final Truck truck;

  /// True when a collector is not this truck's operator, so collecting is
  /// disabled. The API also rejects those calls with 403.
  final bool assignedGuarded;
  final VoidCallback onChanged;
  final TileProvider? tileProvider;

  /// Overrides GPS lookup for the position prefill (e.g. a fixed position
  /// in widget tests).
  final Future<Position> Function()? positionProvider;

  @override
  State<_CollectTab> createState() => _CollectTabState();
}

class _CollectTabState extends State<_CollectTab> {
  final _radius = TextEditingController(text: '30');
  GeoPoint? _point;
  bool _busy = false;
  CollectResult? _result;

  /// Last preview and the radius it was computed for. Cleared whenever the
  /// position or radius changes so it never describes stale inputs.
  List<GarbagePost>? _preview;
  double? _previewRadius;
  bool _previewBusy = false;

  @override
  void initState() {
    super.initState();
    _radius.addListener(_clearPreview);
    _prefillGps();
  }

  void _clearPreview() {
    if (_preview != null) setState(() => _preview = null);
  }

  /// Starts the position at the collector's live fix, which is fresher than
  /// the truck's last ping. Never overwrites a manual pick; on denial or
  /// failure the field stays empty and the collect falls back to the truck
  /// location.
  Future<void> _prefillGps() async {
    try {
      final locate = widget.positionProvider ?? requestCurrentPosition;
      final position = await locate();
      if (!mounted || _point != null) return;
      setState(() => _point = GeoPoint(
          longitude: position.longitude, latitude: position.latitude));
    } catch (_) {
      // Empty position: the collect uses the truck location.
    }
  }

  @override
  void dispose() {
    _radius.dispose();
    super.dispose();
  }

  Future<void> _previewCandidates() async {
    final radius = double.tryParse(_radius.text.trim());
    if (radius == null || radius <= 0) {
      showError(context, 'Enter a valid radius in meters');
      return;
    }
    setState(() {
      _previewBusy = true;
      _preview = null;
    });
    try {
      final posts = await context.read<AuthProvider>().trucks.previewCollect(
            widget.truck.id,
            longitude: _point?.longitude,
            latitude: _point?.latitude,
            radiusMeters: radius,
          );
      if (mounted) {
        setState(() {
          _preview = posts;
          _previewRadius = radius;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _previewBusy = false);
    }
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
      final result = await context.read<AuthProvider>().trucks.collectVicinity(
                widget.truck.id,
                longitude: _point?.longitude,
                latitude: _point?.latitude,
                radiusMeters: radius,
              );
      if (mounted) {
        setState(() {
          _result = result;
          _preview = null;
        });
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
    final viewport = viewportFor(context.watch<AuthProvider>().country);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.assignedGuarded) ...[
          Card(
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child:
                  Text('Only the assigned operator can collect on this truck.'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          'Marks posted garbage near a point as collected. Starts at your current location; clear it to use the truck location instead.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text('Position',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (_point != null)
              TextButton(
                onPressed: () => setState(() => _point = null),
                child: const Text('Use truck location'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        LocationMapPicker(
          onChanged: (point) => setState(() {
            _point = point;
            _preview = null;
          }),
          initial: _point,
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
        OutlinedButton.icon(
          onPressed: (_busy || _previewBusy || widget.assignedGuarded)
              ? null
              : _previewCandidates,
          icon: _previewBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.search),
          label: const Text('Preview nearby'),
        ),
        if (_preview != null) ...[
          const SizedBox(height: 12),
          Text(
            _preview!.isEmpty
                ? 'No posts within ${_radiusText(_previewRadius!)} m of this position.'
                : '${_preview!.length} ${_preview!.length == 1 ? 'post' : 'posts'} within ${_radiusText(_previewRadius!)} m:',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (final post in _preview!) PostCard(post: post),
        ],
        const SizedBox(height: 12),
        FilledButton(
          onPressed: (_busy || widget.assignedGuarded) ? null : _collect,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
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
                  Text('Result',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  InfoRow(
                      label: 'Collected',
                      value: '${result.collectedCount} posts'),
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


