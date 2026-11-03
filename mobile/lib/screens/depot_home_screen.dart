import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import 'depot_setup_screen.dart';

/// Depot staff home: see the bound facility, receive loaded trucks
/// (clearing their load with an audit receipt), and review history.
class DepotHomeScreen extends StatefulWidget {
  const DepotHomeScreen({super.key});

  @override
  State<DepotHomeScreen> createState() => _DepotHomeScreenState();
}

class _DepotHomeScreenState extends State<DepotHomeScreen> {
  int _reload = 0;
  bool _busy = false;

  Future<void> _receive(Truck truck) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Receive ${truck.plateNumber}?'),
        content: Text(
          'This unloads ${truck.load} collected ${truck.load == 1 ? 'item' : 'items'} '
          'and records a receipt. The truck returns to available.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Receive')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final receipt =
          await context.read<AuthProvider>().depot.receive(truck.id);
      if (mounted) {
        showOk(context,
            'Received ${receipt.loadCleared} from ${receipt.plateNumber}');
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
    // First-run gate: no binding yet means the setup screen instead of
    // the depot entries.
    if (auth.user?.depotId == null) {
      return DepotSetupScreen(
        onSaved: () => context.read<AuthProvider>().refreshUser(),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Depot'),
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
      body: RefreshIndicator(
        onRefresh: () async => setState(() => _reload++),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FutureBuilder(
              key: ValueKey(('depot', _reload)),
              future: auth.depot.myDepot(),
              builder: (context, snapshot) {
                final error = snapshot.error;
                // Unassigned depot users land here, not on an error wall.
                if (error is ApiException && error.statusCode == 400) {
                  return const Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No facility assigned yet — ask an administrator to bind this account to a depot.',
                      ),
                    ),
                  );
                }
                return AsyncView<Facility>(
                  snapshot: snapshot,
                  onRetry: () => setState(() => _reload++),
                  builder: (context, depot) => Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const CardIcon(icon: Icons.warehouse_outlined),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(depot.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                Text(
                                  '${pretty(depot.kind)}'
                                  '${depot.address == null ? '' : ' · ${depot.address}'}',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            Text('Inbound trucks',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FutureBuilder(
              key: ValueKey(('inbound', _reload)),
              future: auth.depot.inboundTrucks(),
              builder: (context, snapshot) => AsyncView<List<Truck>>(
                snapshot: snapshot,
                onRetry: () => setState(() => _reload++),
                builder: (context, trucks) {
                  if (trucks.isEmpty) {
                    return const Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No trucks carrying a load.'),
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final truck in trucks)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: const CardIcon(
                                icon: Icons.local_shipping_outlined),
                            title: Text(truck.plateNumber),
                            subtitle: Text(
                              'Load ${truck.load}'
                              '${truck.capacity == null ? '' : ' / ${truck.capacity}'}'
                              ' · ${pretty(truck.availability)}',
                            ),
                            trailing: FilledButton(
                              onPressed:
                                  _busy ? null : () => _receive(truck),
                              child: const Text('Receive'),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            Text('Recent receipts',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FutureBuilder(
              key: ValueKey(('receipts', _reload)),
              future: auth.depot.receipts(),
              builder: (context, snapshot) => AsyncView<List<DepotReceipt>>(
                snapshot: snapshot,
                onRetry: () => setState(() => _reload++),
                builder: (context, receipts) {
                  if (receipts.isEmpty) {
                    return const Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No receipts yet.'),
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final receipt in receipts)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: const CardIcon(
                                icon: Icons.receipt_long_outlined),
                            title: Text(receipt.plateNumber),
                            subtitle: Text(
                              '${receipt.loadCleared} cleared · '
                              '${receipt.receivedAt.toLocal()}',
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
