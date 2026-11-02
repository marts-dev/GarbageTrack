import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';

class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  int _reload = 0;

  Future<void> _editRole(User target) async {
    var selected = target.role;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(target.email),
        content: StatefulBuilder(
          builder: (context, setDialog) => RadioGroup<String>(
            groupValue: selected,
            onChanged: (v) => v == null ? null : setDialog(() => selected = v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final role in userRoles)
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    title: Text(pretty(role)),
                    value: role,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    try {
      await context.read<AuthProvider>().auth.updateRole(target.id, selected);
      if (mounted) {
        showOk(context, 'Role updated');
        setState(() => _reload++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _toggleActive(User target) async {
    // Deactivation blocks login and releases trucks, so it gets a
    // confirmation; reactivation applies immediately.
    if (target.isActive) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Deactivate ${target.email}?'),
          content: const Text(
            'They will no longer be able to sign in, and any trucks they operate will be released.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Deactivate')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    try {
      await context
          .read<AuthProvider>()
          .auth
          .updateActive(target.id, !target.isActive);
      if (mounted) {
        showOk(context, target.isActive ? 'User deactivated' : 'User activated');
        setState(() => _reload++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Users')),
      body: FutureBuilder(
        key: ValueKey(_reload),
        future: auth.auth.listUsers(),
        builder: (context, snapshot) => AsyncView<List<User>>(
          snapshot: snapshot,
          onRetry: () => setState(() => _reload++),
          builder: (context, users) {
            if (users.isEmpty) {
              return RefreshableEmpty(
                onRefresh: () async => setState(() => _reload++),
                empty: const EmptyState(
                  icon: Icons.group_outlined,
                  title: 'No users yet.',
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: () async => setState(() => _reload++),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: users.length,
                itemBuilder: (context, i) {
                  final user = users[i];
                  final initial = user.email.isEmpty
                      ? '?'
                      : user.email[0].toUpperCase();
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text(initial)),
                      title: Text(user.email),
                      subtitle: Text(
                        '${user.displayName} · ${pretty(user.role)}'
                        '${user.isActive ? '' : ' · Inactive'}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: user.isActive
                                ? 'Deactivate user'
                                : 'Activate user',
                            icon: Icon(
                              user.isActive
                                  ? Icons.person_off_outlined
                                  : Icons.person_outline,
                              color: user.isActive
                                  ? null
                                  : Theme.of(context).colorScheme.tertiary,
                            ),
                            onPressed: () => _toggleActive(user),
                          ),
                          IconButton(
                            tooltip: 'Edit role',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _editRole(user),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
