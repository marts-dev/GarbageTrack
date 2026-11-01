import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/cards.dart';
import 'classify_screen.dart';
import 'enroute_screen.dart';
import 'location_screen.dart';
import 'new_post_screen.dart';
import 'posts_screen.dart';

class ResidentHomeScreen extends StatelessWidget {
  const ResidentHomeScreen({super.key});

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
    final user = context.watch<AuthProvider>().user;
    final canReport = user?.isResident ?? false;
    final entries = [
      (Icons.my_location_outlined, 'My location', 'Save your GPS position', const LocationScreen()),
      if (canReport)
        (Icons.add_a_photo_outlined, 'Report garbage', 'Post waste for collection',
            const NewPostScreen()),
      (Icons.list_alt_outlined, 'My reports', 'Track and confirm pickups', const PostsScreen()),
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
                trailing: Icon(
                  Icons.chevron_right,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => screen),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
