import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';

/// Create a collection route for a truck: pick explicit posts, or let the
/// server auto-generate from the truck's capacity, types, and position.
class RouteCreateScreen extends StatefulWidget {
  const RouteCreateScreen({super.key});

  @override
  State<RouteCreateScreen> createState() => _RouteCreateScreenState();
}

class _RouteCreateScreenState extends State<RouteCreateScreen> {
  final _name = TextEditingController();
  String? _truckId;
  bool _auto = true;
  final _picked = <String>{};
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_truckId == null || (!_auto && _picked.isEmpty)) {
      showError(context, 'Pick a truck${_auto ? '' : ' and at least one post'}');
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AuthProvider>().logistics.createRoute(
            truckId: _truckId!,
            name: _name.text.trim().isEmpty ? null : _name.text.trim(),
            postIds: _auto ? null : _picked.toList(),
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
                    future: auth.logistics.truckLocations(),
                    builder: (context, snapshot) => AsyncView<List<Truck>>(
                      snapshot: snapshot,
                      builder: (context, trucks) => DropdownButtonFormField<String>(
                        initialValue: _truckId,
                        decoration: const InputDecoration(
                          labelText: 'Truck',
                        ),
                        items: [
                          for (final truck in trucks)
                            DropdownMenuItem(
                              value: truck.id,
                              child: Text(
                                  '${truck.plateNumber} (${pretty(truck.status)})'),
                            ),
                        ],
                        onChanged: (v) => setState(() => _truckId = v),
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
            child: SwitchListTile(
              title: const Text('Auto-generate stops'),
              subtitle: const Text('Nearest matching posts, within capacity'),
              value: _auto,
              onChanged: (v) => setState(() => _auto = v),
            ),
          ),
          if (!_auto) ...[
            const SizedBox(height: 12),
            Text('Pick posts', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FutureBuilder(
              future: auth.logistics.listAllPosts(status: 'posted'),
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
                            title: Text(post.types.map(pretty).join(', ')),
                            subtitle: Text(post.location.short),
                            value: _picked.contains(post.id),
                            onChanged: (on) => setState(() {
                              if (on == true) {
                                _picked.add(post.id);
                              } else {
                                _picked.remove(post.id);
                              }
                            }),
                          ),
                        ),
                    ],
                  );
                },
              ),
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
