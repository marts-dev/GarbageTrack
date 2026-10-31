import 'package:flutter/material.dart';

import '../models/models.dart';

Color _statusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'collected' || 'done' => scheme.primary,
    'scheduled' || 'enroute' || 'working' => scheme.tertiary,
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
    return Card(
      child: ListTile(
        leading: CardIcon(
          icon: post.hasImage ? Icons.image_outlined : Icons.delete_outline,
          status: post.status,
        ),
        title: Text(post.types.map(pretty).join(', ')),
        subtitle: Text(
          '${pretty(post.status)} · ${post.location.short}'
          '${post.description != null && post.description!.isNotEmpty ? '\n${post.description}' : ''}',
        ),
        isThreeLine: post.description != null && post.description!.isNotEmpty,
        trailing: StatusPill(label: pretty(post.status), status: post.status),
        onTap: onTap,
      ),
    );
  }
}

class TruckCard extends StatelessWidget {
  const TruckCard({super.key, required this.truck, this.onTap});

  final Truck truck;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      pretty(truck.status),
      if (truck.currentLocation != null) truck.currentLocation!.short,
      if (truck.etaMinutes != null) 'ETA ${truck.etaMinutes} min',
      if (truck.capacity != null) 'Load ${truck.load}/${truck.capacity}',
    ].join(' · ');
    return Card(
      child: ListTile(
        leading: const CardIcon(icon: Icons.local_shipping_outlined),
        title: Text(truck.plateNumber),
        subtitle: Text(
          '$subtitle\n${truck.garbageTypes.map(pretty).join(', ')}',
        ),
        isThreeLine: true,
        trailing:
            StatusPill(label: pretty(truck.availability), status: truck.availability),
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
