import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../api.dart';
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

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnect;

  @override
  void initState() {
    super.initState();
    _connect();
    // Staff start at their home airport (set by the administrator).
    final home = AppData.instance.user?.airport;
    if (home != null && home != AppData.instance.airport.code) {
      AppData.instance.setAirport(home);
    } else if (AppData.instance.zones.isEmpty) {
      AppData.instance.refresh();
    }
  }

  @override
  void dispose() {
    _reconnect?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  // Live alerts from the backend, e.g. an item a passenger just handed in.
  void _connect() {
    final user = AppData.instance.user;
    if (user == null) return;
    try {
      _channel = Api.instance.notificationStream(user.id);
      _sub = _channel!.stream.listen(
        (msg) {
          final data = jsonDecode(msg) as Map<String, dynamic>;
          if (data['type'] == 'handed_in') _onHandedIn(data);
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!mounted) return;
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 5), _connect);
  }

  /// A passenger handed an item in: it is already in the inventory, show it.
  void _onHandedIn(Map<String, dynamic> e) {
    if (!mounted || e['airport'] != AppData.instance.airport.code) return;
    _inventoryKey.currentState?.refresh(highlight: e['itemId']);
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 10),
      content: Row(children: [
        const Icon(Icons.volunteer_activism, color: Colors.white),
        const SizedBox(width: 12),
        Expanded(
          child: Text('A passenger handed in {item} found at {place}.'.trf({
            'item': itemTitle(e['color'], e['category'] ?? 'other'),
            'place': e['location'] ?? '',
          })),
        ),
      ]),
      action: SnackBarAction(label: 'VIEW'.tr, onPressed: () => setState(() => _tab = 1)),
    ));
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
    const titles = ['Smart Intake', 'Inventory', 'Ownership review', 'Pick-up desk', 'Claim log'];
    return Scaffold(
      appBar: AppBar(
        title: Text('Staff · {page}'.trf({'page': titles[_tab].tr})),
        actions: [
          ListenableBuilder(
            listenable: AppData.instance,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.only(right: 12),
              // Staff work at the airport their administrator assigned; administrators can switch.
              child: FilterPill(
                label: '${AppData.instance.airport.code} · ${AppData.instance.airport.short}',
                active: true,
                trailingIcon: AppData.instance.user?.airport != null ? Icons.lock_outline : Icons.keyboard_arrow_down,
                onTap: AppData.instance.user?.airport != null
                    ? null
                    : () async {
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
          NavigationDestination(icon: const Icon(Icons.history), label: 'Log'.tr),
        ],
      ),
    );
  }
}
