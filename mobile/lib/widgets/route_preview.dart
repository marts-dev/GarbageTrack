import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';

/// Static schematic of a route's graph: the route path plus its key nodes,
/// drawn without map tiles. Used as a list-row thumbnail; the full map lives
/// on the route detail screen.
class RouteGraphPreview extends StatelessWidget {
  const RouteGraphPreview(this.route, {super.key, this.size = 64});

  final PlannedRoute route;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      size: Size.square(size),
      painter: _RouteGraphPainter(
        line: route.displayLine,
        origin: route.origin,
        stops: [for (final stop in route.stops) stop.location],
        collectionPoints: route.collectionPoints,
        background: scheme.surfaceContainerHighest,
        pathColor: scheme.primary,
        originColor: scheme.primary,
        stopColor: scheme.secondary,
        pointColor: scheme.tertiary,
      ),
    );
  }
}

class _RouteGraphPainter extends CustomPainter {
  const _RouteGraphPainter({
    required this.line,
    required this.origin,
    required this.stops,
    required this.collectionPoints,
    required this.background,
    required this.pathColor,
    required this.originColor,
    required this.stopColor,
    required this.pointColor,
  });

  final List<GeoPoint> line;
  final GeoPoint origin;
  final List<GeoPoint> stops;
  final List<GeoPoint> collectionPoints;
  final Color background;
  final Color pathColor;
  final Color originColor;
  final Color stopColor;
  final Color pointColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      Paint()..color = background,
    );
    final all = <GeoPoint>[...line, ...collectionPoints];
    if (all.isEmpty) return;
    var minLon = all.first.longitude;
    var maxLon = minLon;
    var minLat = all.first.latitude;
    var maxLat = minLat;
    for (final p in all.skip(1)) {
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
    }
    const pad = 10.0;
    final spanLon = (maxLon - minLon).abs();
    final spanLat = (maxLat - minLat).abs();
    Offset project(GeoPoint p) {
      final dx = spanLon < 1e-9
          ? size.width / 2
          : pad + (p.longitude - minLon) / spanLon * (size.width - 2 * pad);
      final dy = spanLat < 1e-9
          ? size.height / 2
          : pad + (maxLat - p.latitude) / spanLat * (size.height - 2 * pad);
      return Offset(dx, dy);
    }

    if (line.length >= 2) {
      final path = Path()..moveTo(project(line.first).dx, project(line.first).dy);
      for (final p in line.skip(1)) {
        final o = project(p);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = pathColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    for (final p in collectionPoints) {
      canvas.drawCircle(project(p), 2.5, Paint()..color = pointColor);
    }
    for (final p in stops) {
      canvas.drawCircle(project(p), 3, Paint()..color = stopColor);
    }
    final o = project(origin);
    canvas.drawCircle(o, 5, Paint()..color = background);
    canvas.drawCircle(o, 3.5, Paint()..color = originColor);
  }

  @override
  bool shouldRepaint(_RouteGraphPainter old) {
    return !listEquals(line, old.line) ||
        !identical(origin, old.origin) ||
        !listEquals(stops, old.stops) ||
        !listEquals(collectionPoints, old.collectionPoints) ||
        background != old.background ||
        pathColor != old.pathColor ||
        originColor != old.originColor ||
        stopColor != old.stopColor ||
        pointColor != old.pointColor;
  }
}
