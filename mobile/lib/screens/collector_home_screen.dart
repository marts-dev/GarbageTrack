import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import 'truck_detail_screen.dart';

/// Collector entry point: lands directly on the truck logistics assigned to
/// the signed-in collector. Unassigned collectors see an empty state instead
/// of a truck list; operator binding is managed by logistics/admins.
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
              return RefreshableEmpty(
                onRefresh: () async => setState(() => _reload++),
                empty: const EmptyState(
                  icon: Icons.local_shipping_outlined,
                  title: 'No truck assigned',
                  subtitle: 'Ask logistics to assign you a truck.',
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
