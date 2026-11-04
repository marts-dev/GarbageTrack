import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/dates.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/type_dots.dart';
import '../widgets/geo_map.dart';

class PostDetailScreen extends StatefulWidget {
  const PostDetailScreen({super.key, required this.postId, this.tileProvider});

  final String postId;

  /// Overrides map tile loading (offline stub in widget tests).
  final TileProvider? tileProvider;

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  int _reload = 0;
  bool _busy = false;

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      await context.read<AuthProvider>().garbage.confirmCollected(widget.postId);
      if (mounted) {
        showOk(context, 'Marked as collected');
        setState(() => _reload++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dispute() async {
    setState(() => _busy = true);
    try {
      await context.read<AuthProvider>().garbage.disputeCollected(widget.postId);
      if (mounted) {
        showOk(context, 'Collection disputed');
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
    return Scaffold(
      appBar: AppBar(title: const Text('Report')),
      body: FutureBuilder(
        key: ValueKey(_reload),
        future: auth.garbage.getPost(widget.postId),
        builder: (context, snapshot) => AsyncView<GarbagePost>(
          snapshot: snapshot,
          onRetry: () => setState(() => _reload++),
          builder: (context, post) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  post.types.map(pretty).join(', '),
                                  style:
                                      Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 4),
                                TypeDots(post.types, size: 12),
                              ],
                            ),
                          ),
                          StatusPill(
                            label: pretty(post.status),
                            status: post.status,
                          ),
                        ],
                      ),
                      if (post.hasImage)
                        const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CardIcon(icon: Icons.image_outlined),
                          title: Text('Photo attached'),
                        ),
                      const SizedBox(height: 8),
                      InfoRow(label: 'Position', value: post.location.short),
                      if (post.district != null && post.district!.trim().isNotEmpty)
                        InfoRow(label: 'District', value: post.district!.trim()),
                      if (post.description != null && post.description!.isNotEmpty)
                        InfoRow(label: 'Notes', value: post.description!),
                      InfoRow(
                          label: 'Reported', value: post.createdAt.toLocal().toString()),
                      if (post.collectedAt != null)
                        InfoRow(
                            label: post.status == 'collected'
                                ? 'Collected'
                                : 'Picked up',
                            value: post.collectedAt!.toLocal().toString()),
                      _CollectionAssignment(postId: post.id),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              GarbageMapView(
                markers: [MapMarkerData(point: post.location)],
                tileProvider: widget.tileProvider,
              ),
              const SizedBox(height: 12),
              // Only a collector-swept (pending) post can be confirmed or
              // disputed; posted/scheduled have nothing to confirm yet and
              // collected is final.
              if (post.status == 'pending_confirmation') ...[
                FilledButton.icon(
                  onPressed: _busy ? null : _confirm,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Confirm collected'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _dispute,
                  icon: const Icon(Icons.report_outlined),
                  label: const Text('Dispute collection'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Truck + route rows for the pickup attributed to a post. Renders nothing
/// while loading, on error, or when the post is on no relevant route (404).
class _CollectionAssignment extends StatelessWidget {
  const _CollectionAssignment({required this.postId});

  final String postId;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return FutureBuilder(
      future: auth.garbage.getCollection(postId),
      builder: (context, snapshot) {
        final assignment = snapshot.data;
        if (!snapshot.hasData || assignment == null) {
          return const SizedBox.shrink();
        }
        return Column(
          children: [
            InfoRow(
              label: 'Truck',
              value: assignment.plateNumber,
            ),
            InfoRow(
              label: 'Route',
              value: [
                assignment.routeName ?? assignment.routeId,
                pretty(assignment.routeStatus),
                if (assignment.scheduledFor != null)
                  formatDay(assignment.scheduledFor!),
              ].join(' · '),
            ),
          ],
        );
      },
    );
  }
}
