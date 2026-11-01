import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/type_dots.dart';
import '../widgets/geo_map.dart';

class PostDetailScreen extends StatefulWidget {
  const PostDetailScreen({super.key, required this.postId});

  final String postId;

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
                            label: 'Collected', value: post.collectedAt!.toLocal().toString()),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              GarbageMapView(
                markers: [MapMarkerData(point: post.location)],
              ),
              const SizedBox(height: 12),
              if (post.status != 'collected')
                FilledButton.icon(
                  onPressed: _busy ? null : _confirm,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Confirm collected'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
