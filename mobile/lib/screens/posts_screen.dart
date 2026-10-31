import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import 'new_post_screen.dart';
import 'post_detail_screen.dart';

class PostsScreen extends StatefulWidget {
  const PostsScreen({super.key});

  @override
  State<PostsScreen> createState() => _PostsScreenState();
}

class _PostsScreenState extends State<PostsScreen> {
  String? _status;
  int _reload = 0;

  Future<List<GarbagePost>> _load(AuthProvider auth) =>
      auth.garbage.listPosts(userId: auth.user!.id, status: _status, limit: 100);

  Future<void> _report() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NewPostScreen()),
    );
    if (mounted) setState(() => _reload++);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('My reports')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Report'),
        onPressed: _report,
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: _status == null,
                  onSelected: (_) => setState(() => _status = null),
                ),
                const SizedBox(width: 8),
                for (final s in garbageStatuses)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(pretty(s)),
                      selected: _status == s,
                      onSelected: (_) => setState(() => _status = s),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder(
              key: ValueKey((_status, _reload)),
              future: _load(auth),
              builder: (context, snapshot) => AsyncView<List<GarbagePost>>(
                snapshot: snapshot,
                onRetry: () => setState(() => _reload++),
                builder: (context, posts) {
                  if (posts.isEmpty) {
                    return RefreshableEmpty(
                      onRefresh: () async => setState(() => _reload++),
                      empty: EmptyState(
                        icon: Icons.list_alt_outlined,
                        title: 'No reports yet.',
                        subtitle: _status == null
                            ? 'Report waste to see it here.'
                            : 'Nothing with this status.',
                        actionLabel: 'Report garbage',
                        onAction: _report,
                      ),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: () async => setState(() => _reload++),
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                      itemCount: posts.length,
                      itemBuilder: (context, i) => PostCard(
                        post: posts[i],
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => PostDetailScreen(postId: posts[i].id),
                            ),
                          );
                          if (mounted) setState(() => _reload++);
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
