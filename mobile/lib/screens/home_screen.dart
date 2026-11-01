import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_provider.dart';
import 'collector_home_screen.dart';
import 'logistics_home_screen.dart';
import 'resident_home_screen.dart';
import 'users_screen.dart';

/// Material 3 navigation with destinations gated by the signed-in user's role.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user!;
    // Each role lands directly on the screen that shows its capabilities.
    switch (user.role) {
      case 'resident':
        return const ResidentHomeScreen();
      case 'collector':
        return const CollectorHomeScreen();
      case 'logistics':
        return const LogisticsHomeScreen();
      case 'admin':
        break;
    }
    // Admins keep the tabbed overview of every area plus user management.
    final tabs = [
      (
        const ResidentHomeScreen(),
        const NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
      ),
      (
        const CollectorHomeScreen(),
        const NavigationDestination(
          icon: Icon(Icons.local_shipping_outlined),
          selectedIcon: Icon(Icons.local_shipping),
          label: 'Collect',
        ),
      ),
      (
        const LogisticsHomeScreen(),
        const NavigationDestination(
          icon: Icon(Icons.forklift),
          label: 'Logistics',
        ),
      ),
      (
        const UsersScreen(),
        const NavigationDestination(
          icon: Icon(Icons.group_outlined),
          selectedIcon: Icon(Icons.group),
          label: 'Users',
        ),
      ),
    ];
    // NavigationBar requires at least two destinations; single-role users
    // get their one screen directly.
    if (tabs.length == 1) return tabs[0].$1;
    final index = _index.clamp(0, tabs.length - 1);
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: [for (final (screen, _) in tabs) screen],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [for (final (_, destination) in tabs) destination],
      ),
    );
  }
}
