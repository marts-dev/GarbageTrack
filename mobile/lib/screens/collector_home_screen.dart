import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import 'truck_detail_screen.dart';

/// Collector entry point: pick one of the enroute trucks to work with.
class CollectorHomeScreen extends StatefulWidget {
  const CollectorHomeScreen({super.key});

  @override
  State<CollectorHomeScreen> createState() => _CollectorHomeScreenState();
}

class _CollectorHomeScreenState extends State<CollectorHomeScreen> {
  final _filter = TextEditingController();
  int _reload = 0;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _open(Truck truck) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TruckDetailScreen(truckId: truck.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Collector')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: TextField(
              controller: _filter,
              decoration: const InputDecoration(
                labelText: 'Filter by plate number',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: FutureBuilder(
              key: ValueKey(_reload),
              future: auth.trucks.listEnroute(),
              builder: (context, snapshot) => AsyncView<List<Truck>>(
                snapshot: snapshot,
                onRetry: () => setState(() => _reload++),
                builder: (context, trucks) {
                  final needle = _filter.text.trim().toLowerCase();
                  final shown = needle.isEmpty
                      ? trucks
                      : trucks
                          .where((t) => t.plateNumber.toLowerCase().contains(needle))
                          .toList();
                  if (shown.isEmpty) {
                    return RefreshableEmpty(
                      onRefresh: () async => setState(() => _reload++),
                      empty: EmptyState(
                        icon: Icons.local_shipping_outlined,
                        title: needle.isEmpty
                            ? 'No trucks enroute.'
                            : 'No matching trucks enroute.',
                        subtitle: needle.isEmpty
                            ? 'Pull down to check again.'
                            : 'Try a different plate number.',
                      ),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: () async => setState(() => _reload++),
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: shown.length,
                      itemBuilder: (context, i) => TruckCard(
                        truck: shown[i],
                        onTap: () => _open(shown[i]),
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
