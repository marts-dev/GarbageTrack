import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/country_viewports.dart';
import '../utils/dates.dart';
import '../utils/geo.dart';
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

  /// Hoisted like [_truckFuture]: the header's Start/Finish button and
  /// the route tab share this one plan fetch, and recreating it in [build]
  /// would refetch on every [setState]. Replaced on truck switches,
  /// retries, starts, finishes, and collects — never on location pings,
  /// so the loaded route is never disturbed.
  late Future<PlannedRoute?> _planFuture;

  @override
  void initState() {
    super.initState();
    _truckFuture = _fetchTruck();
    _planFuture = _fetchPlan();
  }

  @override
  void didUpdateWidget(covariant TruckDetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.truckId != oldWidget.truckId) {
      _freshTruck = null;
      _truckFuture = _fetchTruck();
      _planFuture = _fetchPlan();
    }
  }

  Future<Truck> _fetchTruck() =>
      context.read<AuthProvider>().trucks.getTruck(widget.truckId);

  Future<PlannedRoute?> _fetchPlan() =>
      context.read<AuthProvider>().trucks.getPlannedRoute(widget.truckId);

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

  /// Starts the truck's run: assigned routes go in progress so residents
  /// see the truck coming before the first pickup.
  Future<void> _startRoute() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start run?'),
        content: const Text(
            'This marks the run in progress. Residents will see the truck enroute.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Start'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final truck =
          await context.read<AuthProvider>().trucks.startRoute(widget.truckId);
      if (mounted) {
        showOk(context, 'Run started.');
        setState(() {
          _freshTruck = truck;
          _planFuture = _fetchPlan();
        });
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
          _planFuture = _fetchPlan();
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
        _planFuture = _fetchPlan();
      });
    } catch (_) {
      // The collect itself already succeeded (its result card shows in
      // the tab); still refetch the route, which surfaces its own error
      // UI if the network is actually down.
      if (mounted) {
        setState(() => _planFuture = _fetchPlan());
      }
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
          _planFuture = _fetchPlan();
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
                                      truck.isOperatedBy(auth.user!.id)))) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (auth.user?.isCollector == true &&
                                    truck.isOperatedBy(auth.user!.id))
                                  FilledButton.tonalIcon(
                                    onPressed: _busy ? null : _shareLocation,
                                    icon:
                                        const Icon(Icons.my_location_outlined),
                                    label: const Text('Share my location'),
                                  ),
                                // One run button per state: assigned runs
                                // start, anything else finishes. Collectors
                                // see this only on their own truck; the API
                                // also rejects other operators with 403.
                                // While the status loads (or when the run
                                // is unknown) the slot keeps Finish, the
                                // long-standing action.
                                if (truck.availability == 'working' &&
                                    (auth.user?.isCollector != true ||
                                        truck.isOperatedBy(auth.user!.id)))
                                  FutureBuilder(
                                    future: _planFuture,
                                    builder: (context, snapshot) {
                                      final assigned =
                                          snapshot.data?.status == 'assigned';
                                      return FilledButton.tonalIcon(
                                        onPressed: _busy
                                            ? null
                                            : (assigned
                                                ? _startRoute
                                                : _finishRoute),
                                        icon: Icon(assigned
                                            ? Icons.play_arrow_outlined
                                            : Icons.flag_outlined),
                                        label: Text(assigned
                                            ? 'Start run'
                                            : 'Finish run'),
                                      );
                                    },
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
                        routeFuture: _planFuture,
                        onRetry: () =>
                            setState(() => _planFuture = _fetchPlan()),
                        tileProvider: widget.tileProvider,
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
  const _RouteTab({
    required this.truck,
    required this.routeFuture,
    required this.onRetry,
    this.tileProvider,
  });
  final Truck truck;

  /// The parent's hoisted plan future, shared with the header's
  /// Start/Finish button so one request feeds both. The parent replaces it
  /// on truck switches, reloads, and retries; location pings deliberately
  /// leave it alone so the loaded route is never disturbed.
  final Future<PlannedRoute?> routeFuture;

  /// Asks the parent for a fresh plan future (error retry).
  final VoidCallback onRetry;
  final TileProvider? tileProvider;

  @override
  State<_RouteTab> createState() => _RouteTabState();
}

class _RouteTabState extends State<_RouteTab> {
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
      future: widget.routeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const LoadingView();
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          return ErrorView(
            message: error is ApiException ? error.message : error.toString(),
            onRetry: widget.onRetry,
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
                        child:
                            Text(route.stops[i].types.map(pretty).join(', ')),
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

  /// Last preview, the radius it was computed for, and the center it was
  /// computed around. Cleared whenever the position or radius changes so it
  /// never describes stale inputs; the center pins candidate distances to
  /// the previewed point even if GPS arrives late.
  List<GarbagePost>? _preview;
  double? _previewRadius;
  GeoPoint? _previewCenter;
  bool _previewBusy = false;

  /// The active run for the progress header. Reloaded after every collect
  /// so remaining stops and counts stay live.
  late Future<PlannedRoute?> _planFuture;

  @override
  void initState() {
    super.initState();
    _radius.addListener(_clearPreview);
    _planFuture = _loadPlan();
    _prefillGps();
  }

  Future<PlannedRoute?> _loadPlan() =>
      context.read<AuthProvider>().trucks.getPlannedRoute(widget.truck.id);

  void _reloadPlan() {
    if (!mounted) return;
    setState(() => _planFuture = _loadPlan());
  }

  void _clearPreview() {
    // Always rebuilds: the coverage circle tracks the radius text live.
    setState(() => _preview = null);
  }

  /// Radius for display layers. Pure (no error toast): invalid text simply
  /// hides the coverage circle until it parses again.
  double? _displayRadius() {
    final radius = double.tryParse(_radius.text.trim());
    return radius != null && radius > 0 ? radius : null;
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
      setState(() => _point =
          GeoPoint(longitude: position.longitude, latitude: position.latitude));
    } catch (_) {
      // Empty position: the collect uses the truck location.
    }
  }

  @override
  void dispose() {
    _radius.dispose();
    super.dispose();
  }

  double? _parseRadius() {
    final radius = double.tryParse(_radius.text.trim());
    if (radius == null || radius <= 0) {
      showError(context, 'Enter a valid radius in meters');
      return null;
    }
    return radius;
  }

  Future<void> _previewCandidates() async {
    final radius = _parseRadius();
    if (radius == null) return;
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
          _previewCenter = _point ?? widget.truck.currentLocation;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _previewBusy = false);
    }
  }

  Future<void> _collect() => _runCollect(
        longitude: _point?.longitude,
        latitude: _point?.latitude,
      );

  /// Collects around one candidate post with the current radius: the
  /// standard vicinity collect, centered on the post instead of the
  /// collector. Nearby posts inside the radius come along, exactly as if
  /// the collector had stood there and collected.
  Future<void> _collectAt(GarbagePost post) => _runCollect(
        longitude: post.location.longitude,
        latitude: post.location.latitude,
      );

  Future<void> _runCollect({double? longitude, double? latitude}) async {
    final radius = _parseRadius();
    if (radius == null) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final result = await context.read<AuthProvider>().trucks.collectVicinity(
            widget.truck.id,
            longitude: longitude,
            latitude: latitude,
            radiusMeters: radius,
          );
      if (mounted) {
        setState(() {
          _result = result;
          _preview = null;
          _planFuture = _loadPlan();
        });
        widget.onChanged();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Read-only reference layers for the position map: the assigned route
  /// line, numbered remaining stops in run order, collection points,
  /// depots, and preview candidates not already on the route. Candidates
  /// stay plain pins so scheduled (numbered) vs unscheduled (plain) reads
  /// at a glance; the tapped collect center keeps the picked pin on top.
  /// Without a position the collect falls back to the truck location, so
  /// that fallback shows as the truck pin instead.
  ({List<List<GeoPoint>> lines, List<MapMarkerData> markers}) _mapOverlays(
      PlannedRoute? route) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = scheme.brightness;
    final markers = <MapMarkerData>[];
    final lines = <List<GeoPoint>>[];
    final stopIds = <String>{};
    if (route != null) {
      lines.add(route.displayLine);
      markers.add(MapMarkerData(
        point: route.origin,
        icon: Icons.trip_origin,
        color: scheme.primary,
        label: 'Origin',
      ));
      for (var i = 0; i < route.stops.length; i++) {
        final stop = route.stops[i];
        stopIds.add(stop.postId);
        markers.add(MapMarkerData(
          point: stop.location,
          number: i + 1,
          color: stop.types.isEmpty
              ? scheme.primary
              : garbageTypeColor(stop.types.first, brightness),
          label: 'Stop ${i + 1}: ${stop.types.map(pretty).join(', ')}',
        ));
      }
      for (final point in route.collectionPoints) {
        markers.add(MapMarkerData(
          point: point,
          icon: Icons.flag,
          color: scheme.tertiary,
          label: 'Collection point',
        ));
      }
      for (final depot in route.depots) {
        markers.add(MapMarkerData(
          point: depot.location,
          icon: Icons.home_work,
          color: scheme.secondary,
          label: 'Depot: ${depot.name}',
        ));
      }
    }
    if (_point == null) {
      final truckAt = widget.truck.currentLocation;
      if (truckAt != null) {
        markers.add(MapMarkerData(
          point: truckAt,
          icon: Icons.local_shipping,
          color: Colors.blue,
          label: 'Truck location',
        ));
      }
    }
    for (final post in _preview ?? const <GarbagePost>[]) {
      if (stopIds.contains(post.id)) continue;
      final district = post.district?.trim();
      markers.add(MapMarkerData(
        point: post.location,
        icon: Icons.location_on,
        color: post.types.isEmpty
            ? scheme.primary
            : garbageTypeColor(post.types.first, brightness),
        label: [
          post.types.map(pretty).join(', '),
          if (district != null && district.isNotEmpty) district,
        ].join(' · '),
      ));
    }
    return (lines: lines, markers: markers);
  }

  /// Preview posts nearest-first with live distances to the preview
  /// center. Entries without a known center keep API order and show no
  /// distance.
  List<({GarbagePost post, double? meters})> _sortedPreview() {
    final center = _previewCenter;
    final entries = [
      for (final post in _preview!)
        (
          post: post,
          meters: center == null ? null : metersBetween(center, post.location),
        ),
    ];
    entries.sort((a, b) {
      if (a.meters == null || b.meters == null) return 0;
      return a.meters!.compareTo(b.meters!);
    });
    return entries;
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
        _RunProgress(
          planFuture: _planFuture,
          position: _point ?? widget.truck.currentLocation,
          onRetry: _reloadPlan,
        ),
        const SizedBox(height: 12),
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
        // Shares the progress header's plan future: while it loads the
        // map is still tappable, just without the route layers.
        FutureBuilder(
          future: _planFuture,
          builder: (context, snapshot) {
            final overlays = _mapOverlays(snapshot.data);
            final center = _point ?? widget.truck.currentLocation;
            final radius = _displayRadius();
            return LocationMapPicker(
              onChanged: (point) => setState(() {
                _point = point;
                _preview = null;
              }),
              initial: _point,
              fallbackCenter: viewport.center,
              fallbackZoom: viewport.zoom,
              tileProvider: widget.tileProvider,
              polylines: overlays.lines,
              extraMarkers: overlays.markers,
              coverageCircle: center == null || radius == null
                  ? null
                  : (center: center, radiusMeters: radius),
            );
          },
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
          for (final entry in _sortedPreview())
            _CandidateTile(
              post: entry.post,
              meters: entry.meters,
              enabled: !_busy && !widget.assignedGuarded,
              onCollect: () => _collectAt(entry.post),
            ),
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

/// Run progress header for the collect tab: collected-vs-total count with
/// a progress bar, plus the nearest remaining stop with a live distance to
/// the collector's position. Distances recompute client-side (stop
/// distances from planning time go stale as the truck moves); without a
/// known position the next stop shows with no distance.
class _RunProgress extends StatelessWidget {
  const _RunProgress({
    required this.planFuture,
    required this.position,
    required this.onRetry,
  });

  final Future<PlannedRoute?> planFuture;
  final GeoPoint? position;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder(
      future: planFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        if (snapshot.hasError) {
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(
                Icons.error_outline,
                color: theme.colorScheme.error,
              ),
              title: const Text("Couldn't load the run"),
              trailing: TextButton(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ),
          );
        }
        final route = snapshot.data;
        if (route == null) {
          return Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No active run for this truck. Collects outside a run still work.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          );
        }
        final remaining = route.stops.length;
        final total = route.totalStops;
        final done = total == null ? null : (total - remaining).clamp(0, total);
        final headline = total == null
            ? (remaining == 0
                ? 'Run complete'
                : '$remaining ${remaining == 1 ? 'stop' : 'stops'} to go')
            : (remaining == 0
                ? 'All $total collected'
                : 'Collected $done of $total');
        var next = remaining > 0 ? route.stops.first : null;
        double? nextMeters;
        final center = position;
        if (next != null && center != null) {
          next = route.stops.reduce((a, b) =>
              metersBetween(center, a.location) <=
                      metersBetween(center, b.location)
                  ? a
                  : b);
          nextMeters = metersBetween(center, next.location);
        }
        final nextStop = next;
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Run progress', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(headline, style: theme.textTheme.bodyLarge),
                if (total != null && total > 0) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: done! / total),
                ],
                if (nextStop != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Next: ${nextStop.types.map(pretty).join(', ')}'
                    '${nextMeters != null ? ' · ${formatDistance(nextMeters)}' : ''}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One preview candidate: types, district, live distance, and a Collect
/// button that runs the standard vicinity collect centered on the post.
class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.post,
    required this.meters,
    required this.enabled,
    required this.onCollect,
  });

  final GarbagePost post;
  final double? meters;
  final bool enabled;
  final VoidCallback onCollect;

  @override
  Widget build(BuildContext context) {
    final district = post.district?.trim();
    return Card(
      child: ListTile(
        leading: TypeDots(post.types),
        title: Text(post.types.map(pretty).join(', ')),
        subtitle: Text(
          [
            if (meters != null) formatDistance(meters!),
            pretty(post.status),
            if (district != null && district.isNotEmpty) district,
          ].join(' · '),
        ),
        trailing: FilledButton.tonal(
          onPressed: enabled ? onCollect : null,
          child: const Text('Collect'),
        ),
      ),
    );
  }
}
