import 'package:flutter/material.dart';

import '../models/models.dart';
import 'type_dots.dart';

Color _statusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'collected' || 'done' => scheme.primary,
    'scheduled' || 'pending_confirmation' || 'enroute' || 'working' =>
      scheme.tertiary,
    'full' => scheme.error,
    _ => scheme.secondary,
  };
}

/// Rounded status pill tinted from the theme color scheme.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.status});

  final String label;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _statusColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Tinted rounded-square icon used as a card leading widget.
class CardIcon extends StatelessWidget {
  const CardIcon({super.key, required this.icon, this.status});

  final IconData icon;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color =
        status == null ? scheme.primary : _statusColor(context, status!);
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color),
    );
  }
}

class PostCard extends StatelessWidget {
  const PostCard({super.key, required this.post, this.onTap});

  final GarbagePost post;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final district = post.district?.trim();
    final hasDescription =
        post.description != null && post.description!.isNotEmpty;
    return Card(
      child: ListTile(
        leading: CardIcon(
          icon: post.hasImage ? Icons.image_outlined : Icons.delete_outline,
          status: post.status,
        ),
        title: Row(
          children: [
            Expanded(child: Text(post.types.map(pretty).join(', '))),
            TypeDots(post.types),
          ],
        ),
        subtitle: Text(
          '${pretty(post.status)} · ${post.location.short}'
          '${district != null && district.isNotEmpty ? ' · $district' : ''}'
          '${hasDescription ? '\n${post.description}' : ''}',
        ),
        isThreeLine: hasDescription,
        trailing: StatusPill(label: pretty(post.status), status: post.status),
        onTap: onTap,
      ),
    );
  }
}

class TruckCard extends StatelessWidget {
  const TruckCard({super.key, required this.truck, this.onTap, this.badge, this.action});

  final Truck truck;
  final VoidCallback? onTap;

  /// Optional status pill shown under the subtitle.
  final Widget? badge;

  /// Optional action button shown next to [badge].
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      pretty(truck.availability),
      if (truck.currentLocation != null) truck.currentLocation!.short,
      if (truck.etaMinutes != null) 'ETA ${truck.etaMinutes} min',
      truck.loadSummary,
    ].join(' · ');
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(subtitle),
        const SizedBox(height: 4),
        TypeChips(truck.garbageTypes),
      ],
    );
    return Card(
      child: ListTile(
        leading: const CardIcon(icon: Icons.local_shipping_outlined),
        title: Text(truck.plateNumber),
        subtitle: badge == null && action == null
            ? summary
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  summary,
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (badge != null) badge!,
                      if (action != null) action!,
                    ],
                  ),
                ],
              ),
        isThreeLine: true,
        trailing: StatusPill(
            label: pretty(truck.availability), status: truck.availability),
        onTap: onTap,
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
