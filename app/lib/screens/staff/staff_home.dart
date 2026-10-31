import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../ui.dart';

import 'intake_screen.dart';
import 'inventory_screen.dart';
import 'pickup_screen.dart';
import 'review_screen.dart';

class StaffHome extends StatefulWidget {
  const StaffHome({super.key});

  @override
  State<StaffHome> createState() => _StaffHomeState();
}

class _StaffHomeState extends State<StaffHome> {
  int _tab = 0;
  final _inventoryKey = GlobalKey<InventoryScreenState>();
  final _reviewKey = GlobalKey<ReviewScreenState>();

  @override
  Widget build(BuildContext context) {
    final pages = [
      IntakeScreen(onSaved: () => _inventoryKey.currentState?.refresh()),
      InventoryScreen(key: _inventoryKey),
      ReviewScreen(key: _reviewKey),
      const PickupScreen(),
    ];
    const titles = ['Smart Intake', 'Inventory', 'Ownership review', 'Pick-up desk'];
    return Scaffold(
      appBar: AppBar(
        title: Text('Staff · ${titles[_tab]}'),
        actions: [
          ListenableBuilder(
            listenable: AppData.instance,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilterPill(
                label: '${AppData.instance.airport.code} · ${AppData.instance.airport.short}',
                active: true,
                onTap: () async {
                  await pickAirport(context);
                  _inventoryKey.currentState?.refresh();
                },
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i == 1) _inventoryKey.currentState?.refresh();
          if (i == 2) _reviewKey.currentState?.refresh();
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.add_a_photo_outlined), selectedIcon: Icon(Icons.add_a_photo), label: 'Intake'),
          NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'Inventory'),
          NavigationDestination(icon: Icon(Icons.fact_check_outlined), selectedIcon: Icon(Icons.fact_check), label: 'Review'),
          NavigationDestination(icon: Icon(Icons.qr_code_scanner), label: 'Pick-up'),
        ],
      ),
    );
  }
}
