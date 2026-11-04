import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import 'classify_screen.dart';
import 'enroute_screen.dart';
import 'location_screen.dart';
import 'new_post_screen.dart';
import 'pickup_calendar_screen.dart';
import 'posts_screen.dart';

class ResidentHomeScreen extends StatefulWidget {
  const ResidentHomeScreen({super.key});

  @override
  State<ResidentHomeScreen> createState() => _ResidentHomeScreenState();
}

class _ResidentHomeScreenState extends State<ResidentHomeScreen> {
  /// Bumped when returning from My reports so the pending badge refetches.
  /// Popping a route does not otherwise rebuild this screen, so without it
  /// the badge would keep its stale count after confirming pickups.
  int _badgeReload = 0;

  /// Saved collection point check for the first-run gate. Hoisted so the
  /// badge reload above never refetches it.
  Future<UserLocation?>? _pointFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Residents only: the gate below never subscribes for anyone else, and
    // an unobserved future failing would fail the widget tree.
    if (context.read<AuthProvider>().user?.isResident == true) {
      _pointFuture ??= _loadPoint(context.read<AuthProvider>());
    }
  }

  /// Null when the resident never saved a collection point (404). Any other
  /// failure rethrows so the gate can fail open to the home screen instead
  /// of stranding the user on setup while offline.
  Future<UserLocation?> _loadPoint(AuthProvider auth) async {
    try {
      return await auth.users.getLocation(auth.user!.id);
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> _editName(BuildContext context, User user) async {
    final controller = TextEditingController(text: user.fullName ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(
            hintText: 'Your name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final name = controller.text.trim();
    controller.dispose();
    if (saved != true || !context.mounted) return;
    if (name.isEmpty) return;
    try {
      await context.read<AuthProvider>().updateProfile(name);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Name updated')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    // First-run gate, residents only: no saved collection point means the
    // setup screen instead of the home entries.
    if (auth.user?.isResident == true) {
      return FutureBuilder(
        future: _pointFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Scaffold(
              appBar: AppBar(title: const Text('GarbageTrack')),
              body: const LoadingView(),
            );
          }
          if (!snapshot.hasError && snapshot.data == null) {
            return LocationScreen(
              setupMode: true,
              onSaved: () => setState(
                () => _pointFuture = _loadPoint(context.read<AuthProvider>()),
              ),
            );
          }
          return _home(auth);
        },
      );
    }
    return _home(auth);
  }

  Widget _home(AuthProvider auth) {
    final user = auth.user;
    final canReport = user?.isResident ?? false;
    final entries = [
      (Icons.pin_drop_outlined, 'Collection point', 'Where collectors pick up your garbage',
          const LocationScreen()),
      if (canReport)
        (Icons.add_a_photo_outlined, 'Report garbage', 'Post waste for collection',
            const NewPostScreen()),
      (Icons.list_alt_outlined, 'My reports', 'Track and confirm pickups', const PostsScreen()),
      (Icons.calendar_month_outlined, 'Pickup calendar', 'See scheduled pickups',
          const PickupCalendarScreen()),
      (Icons.local_shipping_outlined, 'Trucks nearby', 'See enroute collections',
          const EnrouteScreen()),
      (Icons.psychology_outlined, 'Classify waste', 'Ask the AI helper', const ClassifyScreen()),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('GarbageTrack'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout_outlined),
            onPressed: () => context.read<AuthProvider>().logout(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Hello, ${user?.displayName ?? ''}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              if (user != null)
                IconButton(
                  tooltip: 'Edit name',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _editName(context, user),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            user == null ? '' : pretty(user.role),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          for (final (icon, title, subtitle, screen) in entries)
            Card(
              child: ListTile(
                leading: CardIcon(icon: icon),
                title: Text(title),
                subtitle: Text(subtitle),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (screen is PostsScreen)
                      _PendingCountBadge(key: ValueKey(_badgeReload)),
                    Icon(
                      Icons.chevron_right,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => screen),
                  );
                  if (!mounted || screen is! PostsScreen) return;
                  setState(() => _badgeReload++);
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Count of the signed-in resident's posts awaiting pickup confirmation.
/// Hidden while loading, on error, when signed out, or when zero.
class _PendingCountBadge extends StatelessWidget {
  const _PendingCountBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final userId = auth.user?.id;
    if (userId == null) return const SizedBox.shrink();
    return FutureBuilder(
      future: auth.garbage.listPosts(
        userId: userId,
        status: 'pending_confirmation',
        limit: 100,
      ),
      builder: (context, snapshot) {
        final count = snapshot.data?.length ?? 0;
        if (!snapshot.hasData || count == 0) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Badge.count(count: count),
        );
      },
    );
  }
}
