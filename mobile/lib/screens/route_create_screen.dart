import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/country_viewports.dart';
import '../utils/geo.dart';
import '../widgets/async_view.dart';
import '../widgets/geo_map.dart';
import '../widgets/type_dots.dart';

/// Create a collection route for a truck: pick explicit posts, or let the
/// server auto-generate from the truck's capacity, types, and position.
///
/// Logistics picks one or more depot facilities, optionally narrows posted
/// garbage by garbage type, taps map pins to select stops, and taps the map
/// to place collection points.
class RouteCreateScreen extends StatefulWidget {
  const RouteCreateScreen({super.key, this.tileProvider});

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  @override
  State<RouteCreateScreen> createState() => _RouteCreateScreenState();
}

class _RouteCreateScreenState extends State<RouteCreateScreen> {
  final _name = TextEditingController();

  /// Selected garbage types. Constrained to the picked truck's capability
  /// (all on by default); without a truck, every type is available.
  Set<String> _selectedTypes = Set.of(garbageTypes);
  String? _truckId;
  Truck? _pickedTruck;
  bool _auto = true;
  final _picked = <String>{};

  /// Stable key for the selection: set iteration order is not enough.
  String get _typeKey => (_selectedTypes.toList()..sort()).join(',');

  /// Ordered depot picks in visit order: the last pick is the route end.
  final _depots = <String>[];
  final _collectionPoints = <GeoPoint>[];
  bool _addPointsMode = false;

  /// Drawn-area selection: map taps append vertices until the shape closes,
  /// then enclosed posted garbage becomes the manual stop set.
  bool _polygonMode = false;
  final _polygon = <GeoPoint>[];
  bool _polygonClosed = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_truckId == null) {
      showError(context, 'Pick a truck');
      return;
    }
    if (_depots.isEmpty) {
      showError(context, 'Pick at least one depot');
      return;
    }
    if (_auto && _selectedTypes.isEmpty) {
      showError(context, 'Pick at least one garbage type');
      return;
    }
    if (!_auto && _picked.isEmpty) {
      showError(context, 'Pick at least one post');
      return;
    }
    setState(() => _busy = true);
    try {
      final auth = context.read<AuthProvider>();
      await auth.logistics.createRoute(
        truckId: _truckId!,
        depotIds: _depots.toList(),
        name: _name.text.trim().isEmpty ? null : _name.text.trim(),
        postIds: _auto ? null : _picked.toList(),
        collectionPoints:
            _collectionPoints.isEmpty ? null : List.of(_collectionPoints),
        types: _selectedTypes.toList(),
        country: auth.country,
      );
      if (mounted) {
        showOk(context, 'Route assigned');
        Navigator.of(context).pop(true);
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
    final viewport = viewportFor(auth.country);
    return Scaffold(
      appBar: AppBar(title: const Text('New route')),
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
                  Text('Details', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Route name (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  FutureBuilder(
                    future: auth.trucks.listTrucks(),
                    builder: (context, snapshot) => AsyncView<List<Truck>>(
                      snapshot: snapshot,
                      builder: (context, trucks) => DropdownButtonFormField<String>(
                        initialValue: _truckId,
                        decoration: const InputDecoration(
                          labelText: 'Truck',
                        ),
                        // Two-line menu rows need a taller item slot.
                        itemHeight: 68,
                        items: [
                          for (final truck in trucks)
                            DropdownMenuItem(
                              value: truck.id,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                      '${truck.plateNumber} (${pretty(truck.status)})'),
                                  if (truck.garbageTypes.isNotEmpty)
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        TypeDots(truck.garbageTypes),
                                        const SizedBox(width: 6),
                                        Flexible(
                                          child: Text(
                                            truck.garbageTypes
                                                .map(pretty)
                                                .join(', '),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                        ],
                        // Closed field stays a single plate line.
                        selectedItemBuilder: (context) => [
                          for (final truck in trucks)
                            Text(
                                '${truck.plateNumber} (${pretty(truck.status)})'),
                        ],
                        onChanged: (v) => setState(() {
                          _truckId = v;
                          _pickedTruck = null;
                          for (final truck in trucks) {
                            if (truck.id == v) _pickedTruck = truck;
                          }
                          // A new truck resets the selection to everything
                          // it can carry.
                          _selectedTypes = Set.of(
                              _pickedTruck?.garbageTypes ?? garbageTypes);
                        }),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Depots (pick at least one)',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Any facility can serve as a depot. Picks run in visit order; the last pick is the route end.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  FutureBuilder(
                    future: auth.logistics.listFacilities(limit: 100),
                    builder: (context, snapshot) => AsyncView<List<Facility>>(
                      snapshot: snapshot,
                      onRetry: () => setState(() {}),
                      builder: (context, facilities) {
                        if (facilities.isEmpty) {
                          return const Text(
                              'No facilities yet — register one first.');
                        }
                        return Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final facility in facilities)
                              FilterChip(
                                label: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '${facility.name} (${pretty(facility.kind)})'
                                      '${_depots.isNotEmpty && _depots.last == facility.id ? ' · End' : ''}',
                                    ),
                                    const SizedBox(height: 2),
                                    TypeDots(facility.acceptedTypes, size: 8),
                                  ],
                                ),
                                selected: _depots.contains(facility.id),
                                onSelected: (on) => setState(() {
                                  if (on) {
                                    if (!_depots.contains(facility.id)) {
                                      _depots.add(facility.id);
                                    }
                                  } else {
                                    _depots.remove(facility.id);
                                  }
                                }),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile(
              title: const Text('Auto-generate stops'),
              subtitle: const Text('Nearest matching posts, within capacity'),
              value: _auto,
              onChanged: (v) => setState(() => _auto = v),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Posted garbage',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Text(
                    _pickedTruck == null
                        ? 'Showing all types — pick a truck to constrain by capability.'
                        : 'Only types ${_pickedTruck!.plateNumber} can carry.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final type
                          in _pickedTruck?.garbageTypes ?? garbageTypes)
                        FilterChip(
                          label: Text(pretty(type)),
                          avatar: TypeDot(type),
                          selected: _selectedTypes.contains(type),
                          onSelected: (on) => setState(() {
                            if (on) {
                              _selectedTypes.add(type);
                            } else {
                              _selectedTypes.remove(type);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _PostsMap(
                    key: ValueKey((
                      _typeKey,
                      _truckId,
                      _depots.isEmpty ? null : _depots.last,
                    )),
                    typeFilter: _selectedTypes,
                    picked: _picked,
                    collectionPoints: _collectionPoints,
                    addPointsMode: _addPointsMode,
                    polygonMode: _polygonMode,
                    polygon: _polygon,
                    truckId: _truckId,
                    endDepotId: _depots.isEmpty ? null : _depots.last,
                    fallbackCenter: viewport.center,
                    fallbackZoom: viewport.zoom,
                    tileProvider: widget.tileProvider,
                    onTogglePost: (post) => setState(() {
                      if (_picked.contains(post.id)) {
                        _picked.remove(post.id);
                      } else {
                        _picked.add(post.id);
                      }
                    }),
                    onAddPoint: (point) =>
                        setState(() => _collectionPoints.add(point)),
                    onAddVertex: (point) => setState(() {
                      _polygonClosed = false;
                      _polygon.add(point);
                    }),
                  ),
                  _PolygonPanel(
                    key: ValueKey(('polygon', _typeKey)),
                    typeFilter: _selectedTypes,
                    polygonMode: _polygonMode,
                    polygon: _polygon,
                    polygonClosed: _polygonClosed,
                    onToggleMode: (v) => setState(() {
                      _polygonMode = v;
                      // Draw mode and tap-to-add mode are mutually exclusive.
                      if (v) _addPointsMode = false;
                    }),
                    onUndo: () => setState(() {
                      if (_polygon.isNotEmpty) _polygon.removeLast();
                      _polygonClosed = false;
                    }),
                    onClear: () => setState(() {
                      _polygon.clear();
                      _polygonClosed = false;
                    }),
                    onEdit: () => setState(() => _polygonClosed = false),
                    onClose: (enclosedIds) {
                      if (enclosedIds.isEmpty) {
                        showError(context, 'No posted garbage inside the area');
                        return;
                      }
                      setState(() {
                        _polygonClosed = true;
                        // The drawn area submits through the manual path.
                        _auto = false;
                        _picked
                          ..clear()
                          ..addAll(enclosedIds);
                      });
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Tap map to add collection points'),
                    subtitle: Text(_addPointsMode
                        ? 'Map taps place a collection point.'
                        : 'Pin taps ${_auto ? 'highlight posts' : 'select stops'}.'),
                    value: _addPointsMode,
                    onChanged: (v) => setState(() {
                      _addPointsMode = v;
                      if (v) _polygonMode = false;
                    }),
                  ),
                  if (_collectionPoints.isNotEmpty) ...[
                    Text(
                      'Collection points (${_collectionPoints.length})',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    for (var i = 0; i < _collectionPoints.length; i++)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: Icon(
                          Icons.flag,
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                        title: Text(_collectionPoints[i].short),
                        trailing: IconButton(
                          tooltip: 'Remove collection point',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () =>
                              setState(() => _collectionPoints.removeAt(i)),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          if (!_auto) ...[
            const SizedBox(height: 12),
            Text('Pick posts', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _PostsList(
              key: ValueKey(('list', _typeKey)),
              typeFilter: _selectedTypes,
              picked: _picked,
              onToggle: (post, on) => setState(() {
                if (on) {
                  _picked.add(post.id);
                } else {
                  _picked.remove(post.id);
                }
              }),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Assign route'),
          ),
        ],
      ),
    );
  }
}

/// Loads posted garbage and narrows it to the selected garbage types
/// (client-side; a post shows when any of its types is selected).
/// Shared loader for map and list.
Future<List<GarbagePost>> _loadPosted(
    AuthProvider auth, Set<String> typeFilter) async {
  final posts = await auth.logistics.listAllPosts(
    status: 'posted',
    country: auth.country,
    limit: 200,
  );
  if (typeFilter.isEmpty) return [];
  return posts.where((p) => p.types.any(typeFilter.contains)).toList();
}

/// Posted garbage plus the route endpoints: the selected truck's position
/// (route start) and the last-picked depot (route end).
class _MapData {
  const _MapData({required this.posts, this.truckStart, this.endDepot});

  final List<GarbagePost> posts;
  final GeoPoint? truckStart;
  final Facility? endDepot;
}

Future<_MapData> _loadMapData(
  AuthProvider auth,
  Set<String> typeFilter,
  String? truckId,
  String? endDepotId,
) async {
  final posts = await _loadPosted(auth, typeFilter);
  GeoPoint? truckStart;
  if (truckId != null) {
    final trucks = await auth.trucks.listTrucks();
    for (final truck in trucks) {
      if (truck.id == truckId) {
        truckStart = truck.currentLocation;
        break;
      }
    }
  }
  Facility? endDepot;
  if (endDepotId != null) {
    final facilities = await auth.logistics.listFacilities(limit: 100);
    for (final facility in facilities) {
      if (facility.id == endDepotId) {
        endDepot = facility;
        break;
      }
    }
  }
  return _MapData(posts: posts, truckStart: truckStart, endDepot: endDepot);
}

/// Clustered map of posted garbage. Tapping a pin toggles selection (unless
/// a draw mode is on); tapping empty map area adds a collection point when
/// [addPointsMode] is on, or a polygon vertex when [polygonMode] is on.
///
/// The load future is created once per [key]: vertex taps, picks, and mode
/// toggles rebuild with the same future so the map element (and its camera)
/// survives them instead of flashing back to a loader.
class _PostsMap extends StatefulWidget {
  const _PostsMap({
    super.key,
    required this.typeFilter,
    required this.picked,
    required this.collectionPoints,
    required this.addPointsMode,
    required this.polygonMode,
    required this.polygon,
    required this.truckId,
    required this.endDepotId,
    required this.fallbackCenter,
    required this.fallbackZoom,
    required this.onTogglePost,
    required this.onAddPoint,
    required this.onAddVertex,
    this.tileProvider,
  });

  final Set<String> typeFilter;
  final Set<String> picked;
  final List<GeoPoint> collectionPoints;
  final bool addPointsMode;
  final bool polygonMode;
  final List<GeoPoint> polygon;
  final String? truckId;
  final String? endDepotId;
  final LatLng fallbackCenter;
  final double fallbackZoom;
  final ValueChanged<GarbagePost> onTogglePost;
  final ValueChanged<GeoPoint> onAddPoint;
  final ValueChanged<GeoPoint> onAddVertex;
  final TileProvider? tileProvider;

  @override
  State<_PostsMap> createState() => _PostsMapState();
}

class _PostsMapState extends State<_PostsMap> {
  late final Future<_MapData> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadMapData(
      context.read<AuthProvider>(),
      widget.typeFilter,
      widget.truckId,
      widget.endDepotId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder(
      future: _future,
      builder: (context, snapshot) => AsyncView<_MapData>(
        snapshot: snapshot,
        builder: (context, data) {
          final posts = data.posts;
          final truckStart = data.truckStart;
          final endDepot = data.endDepot;
          final polygon = widget.polygon;
          if (posts.isEmpty &&
              widget.collectionPoints.isEmpty &&
              truckStart == null &&
              endDepot == null &&
              polygon.isEmpty) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No posted garbage right now.'),
            );
          }
          return GarbageMapView(
            height: 260,
            clustered: true,
            tileProvider: widget.tileProvider,
            fallbackCenter: widget.fallbackCenter,
            fallbackZoom: widget.fallbackZoom,
            markers: [
              for (final post in posts)
                MapMarkerData(
                  point: post.location,
                  icon: widget.picked.contains(post.id)
                      ? Icons.check_circle
                      : Icons.location_on,
                  color: widget.picked.contains(post.id)
                      ? scheme.tertiary
                      : post.types.isEmpty
                          ? null
                          : garbageTypeColor(
                              post.types.first, scheme.brightness),
                  label:
                      '${post.types.map(pretty).join(', ')} · ${post.district ?? 'No district'}',
                  clusterGroup: MarkerGroups.garbage,
                ),
              for (final point in widget.collectionPoints)
                MapMarkerData(
                  point: point,
                  icon: Icons.flag,
                  color: scheme.tertiary,
                  label: 'Collection point',
                  clusterGroup: MarkerGroups.collectionPoint,
                ),
              if (truckStart != null)
                MapMarkerData(
                  point: truckStart,
                  icon: Icons.local_shipping,
                  color: scheme.primary,
                  label: 'Start: truck position',
                  clusterGroup: MarkerGroups.truck,
                ),
              if (endDepot != null)
                MapMarkerData(
                  point: endDepot.location,
                  icon: Icons.home_work,
                  color: scheme.secondary,
                  label: 'End: ${endDepot.name}',
                  clusterGroup: MarkerGroups.depot,
                ),
            ],
            overlayMarkers: [
              for (final vertex in polygon)
                MapMarkerData(
                  point: vertex,
                  icon: Icons.circle,
                  color: scheme.tertiary,
                  label: 'Area vertex',
                ),
            ],
            polygons: polygon.length >= 3 ? [List.of(polygon)] : const [],
            // In draw modes marker taps are disabled so a pin tap can never
            // also drop a point underneath it.
            onMarkerTap: (widget.addPointsMode || widget.polygonMode)
                ? null
                : (index) {
                    if (index < posts.length) {
                      widget.onTogglePost(posts[index]);
                    }
                  },
            onMapTap: widget.polygonMode
                ? (ll) => widget.onAddVertex(ll.geoPoint)
                : (widget.addPointsMode
                    ? (ll) => widget.onAddPoint(ll.geoPoint)
                    : null),
          );
        },
      ),
    );
  }
}

/// Drawn-area selection controls: toggle draw mode, edit vertices, and close
/// the shape to select the enclosed posts. The live inside-count loads the
/// same posted list as the map and tests inclusion client-side. The future
/// is created once per [key] so vertex taps never reload the count.
class _PolygonPanel extends StatefulWidget {
  const _PolygonPanel({
    super.key,
    required this.typeFilter,
    required this.polygonMode,
    required this.polygon,
    required this.polygonClosed,
    required this.onToggleMode,
    required this.onUndo,
    required this.onClear,
    required this.onEdit,
    required this.onClose,
  });

  final Set<String> typeFilter;
  final bool polygonMode;
  final List<GeoPoint> polygon;
  final bool polygonClosed;
  final ValueChanged<bool> onToggleMode;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onEdit;
  final ValueChanged<List<String>> onClose;

  @override
  State<_PolygonPanel> createState() => _PolygonPanelState();
}

class _PolygonPanelState extends State<_PolygonPanel> {
  late final Future<List<GarbagePost>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadPosted(context.read<AuthProvider>(), widget.typeFilter);
  }

  @override
  Widget build(BuildContext context) {
    final polygon = widget.polygon;
    final polygonClosed = widget.polygonClosed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (widget.polygonMode)
              FilledButton.tonal(
                onPressed: () => widget.onToggleMode(false),
                child: const Text('Drawing area'),
              )
            else
              OutlinedButton(
                onPressed: () => widget.onToggleMode(true),
                child: const Text('Draw area'),
              ),
            if (polygon.isNotEmpty && !polygonClosed) ...[
              OutlinedButton(
                  onPressed: widget.onUndo, child: const Text('Undo')),
              OutlinedButton(
                  onPressed: widget.onClear, child: const Text('Clear')),
            ],
            if (polygonClosed)
              OutlinedButton(
                  onPressed: widget.onEdit, child: const Text('Edit area')),
          ],
        ),
        if (polygon.isNotEmpty)
          FutureBuilder(
            future: _future,
            builder: (context, snapshot) => AsyncView<List<GarbagePost>>(
              snapshot: snapshot,
              builder: (context, posts) {
                final enclosed = polygon.length >= 3
                    ? [
                        for (final post in posts)
                          if (pointInPolygon(post.location, polygon)) post,
                      ]
                    : <GarbagePost>[];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    Text(
                      '${polygon.length} vertices · ${enclosed.length} posts inside',
                    ),
                    if (!polygonClosed) ...[
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: polygon.length >= 3
                            ? () => widget
                                .onClose([for (final p in enclosed) p.id])
                            : null,
                        child: const Text('Close shape'),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Checkbox list of posted garbage for manual stop picking.
class _PostsList extends StatelessWidget {
  const _PostsList({
    super.key,
    required this.typeFilter,
    required this.picked,
    required this.onToggle,
  });

  final Set<String> typeFilter;
  final Set<String> picked;
  final void Function(GarbagePost post, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return FutureBuilder(
      future: _loadPosted(auth, typeFilter),
      builder: (context, snapshot) => AsyncView<List<GarbagePost>>(
        snapshot: snapshot,
        builder: (context, posts) {
          if (posts.isEmpty) {
            return const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'No posted garbage right now.',
            );
          }
          return Column(
            children: [
              for (final post in posts)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: CheckboxListTile(
                    title: Row(
                      children: [
                        Expanded(
                            child: Text(post.types.map(pretty).join(', '))),
                        TypeDots(post.types),
                      ],
                    ),
                    subtitle: Text(
                        '${post.district ?? 'No district'} · ${post.location.short}'),
                    value: picked.contains(post.id),
                    onChanged: (on) => onToggle(post, on == true),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
