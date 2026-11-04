import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import 'truck_detail_screen.dart';

/// Collector entry point: lands directly on the signed-in collector's
/// truck. Unassigned collectors pick from the claimable trucks instead;
/// only when every truck is taken does the empty state ask logistics.
class CollectorHomeScreen extends StatefulWidget {
  const CollectorHomeScreen({super.key, this.tileProvider});

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  @override
  State<CollectorHomeScreen> createState() => _CollectorHomeScreenState();
}

class _CollectorHomeScreenState extends State<CollectorHomeScreen> {
  int _reload = 0;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final myId = auth.user!.id;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Collector'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout_outlined),
            onPressed: () => context.read<AuthProvider>().logout(),
          ),
        ],
      ),
      body: FutureBuilder(
        key: ValueKey(_reload),
        future: auth.trucks.listTrucks(),
        builder: (context, snapshot) => AsyncView<List<Truck>>(
          snapshot: snapshot,
          onRetry: () => setState(() => _reload++),
          builder: (context, trucks) {
            Truck? assigned;
            for (final truck in trucks) {
              if (truck.isOperatedBy(myId)) {
                assigned = truck;
                break;
              }
            }
            final match = assigned;
            if (match == null) {
              final claimable =
                  trucks.where((t) => t.operatorId == null).toList();
              if (claimable.isEmpty) {
                return RefreshableEmpty(
                  onRefresh: () async => setState(() => _reload++),
                  empty: const EmptyState(
                    icon: Icons.local_shipping_outlined,
                    title: 'No truck assigned',
                    subtitle: 'Ask logistics to assign you a truck.',
                  ),
                );
              }
              return RefreshIndicator(
                onRefresh: () async => setState(() => _reload++),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      'Available trucks',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Claim a truck to start collecting.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    for (final truck in claimable)
                      TruckCard(
                        truck: truck,
                        onTap: () => Navigator.of(context)
                            .push(
                              MaterialPageRoute(
                                builder: (_) => TruckDetailScreen(
                                  truckId: truck.id,
                                  tileProvider: widget.tileProvider,
                                ),
                              ),
                            )
                            .then((_) {
                          // A claim may have happened inside: reload so
                          // home can land on the truck.
                          if (context.mounted) setState(() => _reload++);
                        }),
                      ),
                  ],
                ),
              );
            }
            return TruckDetailBody(
              key: ValueKey(match.id),
              truckId: match.id,
              tileProvider: widget.tileProvider,
            );
          },
        ),
      ),
    );
  }
}
