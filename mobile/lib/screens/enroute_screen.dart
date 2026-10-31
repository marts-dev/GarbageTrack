import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/geo_map.dart';

class EnrouteScreen extends StatefulWidget {
  const EnrouteScreen({super.key});

  @override
  State<EnrouteScreen> createState() => _EnrouteScreenState();
}

class _EnrouteScreenState extends State<EnrouteScreen> {
  int _reload = 0;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Trucks enroute')),
      body: FutureBuilder(
        key: ValueKey(_reload),
        future: auth.trucks.listEnroute(),
        builder: (context, snapshot) => AsyncView<List<Truck>>(
          snapshot: snapshot,
          onRetry: () => setState(() => _reload++),
          builder: (context, trucks) {
            if (trucks.isEmpty) {
              return RefreshableEmpty(
                onRefresh: () async => setState(() => _reload++),
                empty: const EmptyState(
                  icon: Icons.local_shipping_outlined,
                  title: 'No trucks enroute.',
                  subtitle: 'Pull down to check again.',
                ),
              );
            }
            final located = trucks.where((t) => t.currentLocation != null).toList();
            return RefreshIndicator(
              onRefresh: () async => setState(() => _reload++),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (located.isNotEmpty) ...[
                    GarbageMapView(
                      markers: [
                        for (final truck in located)
                          MapMarkerData(
                            point: truck.currentLocation!,
                            icon: Icons.local_shipping,
                            label: truck.plateNumber,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  for (final truck in trucks) TruckCard(truck: truck),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
