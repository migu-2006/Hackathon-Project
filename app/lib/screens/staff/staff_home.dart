import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../i18n.dart';
import '../../models.dart';
import '../../ui.dart';

import '../account.dart';
import 'attempts_screen.dart';
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
  final _attemptsKey = GlobalKey<AttemptsScreenState>();

  @override
  void initState() {
    super.initState();
    // Staff start at their home airport (set by the administrator).
    final home = AppData.instance.user?.airport;
    if (home != null && home != AppData.instance.airport.code) {
      AppData.instance.setAirport(home);
    } else if (AppData.instance.zones.isEmpty) {
      AppData.instance.refresh();
    }
  }

  /// After intake: confirm, then show the item in the inventory.
  void _onRegistered(FoundItem item, int notified) {
    _inventoryKey.currentState?.refresh(highlight: item.id);
    setState(() => _tab = 1);
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.green.shade700,
      duration: const Duration(seconds: 6),
      content: Row(children: [
        const Icon(Icons.check_circle, color: Colors.white),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '{item} registered at {place}.'.trf({'item': itemTitle(item.color, item.category), 'place': item.location}) +
                (notified > 0
                    ? ' ${trn(notified, '{n} passenger with a matching report was notified.', '{n} passengers with a matching report were notified.')}'
                    : ''),
          ),
        ),
      ]),
      action: SnackBarAction(
        label: 'REGISTER ANOTHER'.tr,
        textColor: Colors.white,
        onPressed: () => setState(() => _tab = 0),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      IntakeScreen(onSaved: _onRegistered),
      InventoryScreen(key: _inventoryKey),
      ReviewScreen(key: _reviewKey),
      const PickupScreen(),
      AttemptsScreen(key: _attemptsKey),
    ];
    const titles = ['Smart Intake', 'Inventory', 'Ownership review', 'Pick-up desk', 'Verification log'];
    return Scaffold(
      appBar: AppBar(
        title: Text('Staff · {page}'.trf({'page': titles[_tab].tr})),
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
                  _attemptsKey.currentState?.refresh();
                },
              ),
            ),
          ),
          // Intake and Pick-up have nothing to reload.
          if (_tab == 1) RefreshButton(onRefresh: () => _inventoryKey.currentState?.refresh()),
          if (_tab == 2) RefreshButton(onRefresh: () => _reviewKey.currentState?.refresh()),
          if (_tab == 4) RefreshButton(onRefresh: () => _attemptsKey.currentState?.refresh()),
          const AccountButton(),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i == 1) _inventoryKey.currentState?.refresh();
          if (i == 2) _reviewKey.currentState?.refresh();
          if (i == 4) _attemptsKey.currentState?.refresh();
        },
        destinations: [
          NavigationDestination(icon: const Icon(Icons.add_a_photo_outlined), selectedIcon: const Icon(Icons.add_a_photo), label: 'Intake'.tr),
          NavigationDestination(icon: const Icon(Icons.inventory_2_outlined), selectedIcon: const Icon(Icons.inventory_2), label: 'Inventory'.tr),
          NavigationDestination(icon: const Icon(Icons.fact_check_outlined), selectedIcon: const Icon(Icons.fact_check), label: 'Review'.tr),
          NavigationDestination(icon: const Icon(Icons.qr_code_scanner), label: 'Pick-up'.tr),
          NavigationDestination(icon: const Icon(Icons.gpp_maybe_outlined), selectedIcon: const Icon(Icons.gpp_maybe), label: 'Attempts'.tr),
        ],
      ),
    );
  }
}
