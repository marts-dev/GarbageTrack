import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import 'facility_form_screen.dart';

/// First-run setup for unbound depot users: join an existing depot or
/// register a new one. Either path binds the caller via [onSaved].
class DepotSetupScreen extends StatefulWidget {
  const DepotSetupScreen({super.key, required this.onSaved, this.tileProvider});

  final Future<void> Function() onSaved;

  /// Overrides tile loading in the registration form's map picker.
  final TileProvider? tileProvider;

  @override
  State<DepotSetupScreen> createState() => _DepotSetupScreenState();
}

class _DepotSetupScreenState extends State<DepotSetupScreen> {
  String? _selected;
  bool _busy = false;

  Future<void> _join() async {
    final facilityId = _selected;
    if (facilityId == null) {
      showError(context, 'Pick a depot to join');
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AuthProvider>().depot.joinDepot(facilityId);
      await widget.onSaved();
      if (mounted) showOk(context, 'Depot joined');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _register() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => FacilityFormScreen(
          selfRegister: true,
          tileProvider: widget.tileProvider,
        ),
      ),
    );
    if (saved == true && mounted) {
      await widget.onSaved();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up your depot'),
        actions: [
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout_outlined),
              onPressed: () => context.read<AuthProvider>().logout(),
            ),
          ),
        ],
      ),
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
                  Text('Join an existing depot',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Already working at a registered depot? Pick it below.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  FutureBuilder(
                    future: auth.logistics.listFacilities(limit: 100),
                    builder: (context, snapshot) =>
                        AsyncView<List<Facility>>(
                      snapshot: snapshot,
                      onRetry: () => setState(() {}),
                      builder: (context, facilities) {
                        if (facilities.isEmpty) {
                          return const Text(
                              'No depots registered yet — set yours up below.');
                        }
                        return RadioGroup<String>(
                          groupValue: _selected,
                          onChanged: (v) => setState(() => _selected = v),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final facility in facilities)
                                RadioListTile<String>(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                      '${facility.name} (${pretty(facility.kind)})'),
                                  subtitle: facility.address == null
                                      ? null
                                      : Text(facility.address!),
                                  value: facility.id,
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy ? null : _join,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Join depot'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Or register a new depot',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Set up a new depot with its location and accepted types.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _register,
                    child: const Text('Register depot'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
