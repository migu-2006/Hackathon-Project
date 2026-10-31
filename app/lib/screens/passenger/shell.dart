import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../models.dart';
import '../../theme.dart';
import 'found_items_screen.dart';
import 'help_screen.dart';
import 'home_screen.dart';
import 'my_reports_screen.dart';

enum ShellTab { home, find, reports, help }

/// Passenger app frame: bottom navigation with one navigator per tab, so the bar stays
/// visible on inner screens (item details, pickup pass, ...) like in the design.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  static final _key = GlobalKey<_AppShellState>();
  static Widget create() => AppShell(key: _key);

  /// Switch tab; optionally reset it to its root and/or push a screen on top.
  static void goTo(ShellTab tab, {Widget? push, bool reset = false}) =>
      _key.currentState?._goTo(tab, push: push, reset: reset);

  /// Clear every tab after a developer reset (other devices get this through the live connection).
  static Future<void> resetAll() async => _key.currentState?._onReset();

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  ShellTab _tab = ShellTab.home;
  // Replaced after a developer reset so every tab is rebuilt from scratch.
  var _navigators = {for (final t in ShellTab.values) t: GlobalKey<NavigatorState>()};
  final _unread = ValueNotifier(0);

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnect;

  @override
  void initState() {
    super.initState();
    AppData.instance.refresh();
    _connect();
  }

  @override
  void dispose() {
    _reconnect?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  // Realtime notifications pushed by the backend (new match, claim approved, recovered).
  void _connect() {
    try {
      _channel = Api.instance.notificationStream(AppData.instance.userId);
      _sub = _channel!.stream.listen(
        (msg) {
          final data = jsonDecode(msg) as Map<String, dynamic>;
          data['type'] == 'reset' ? _onReset() : _onNotification(AppNotification.fromJson(data));
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

  void _onNotification(AppNotification n) {
    if (!mounted) return;
    AppData.instance.refresh();
    if (_tab != ShellTab.reports) _unread.value++;
    final p = Palette.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 8),
      backgroundColor: p.primary,
      content: Row(children: [
        const Icon(Icons.notifications_active, color: Colors.white),
        const SizedBox(width: 12),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.title, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(n.body, style: const TextStyle(fontSize: 12)),
          ]),
        ),
      ]),
      action: SnackBarAction(
        label: 'VIEW',
        textColor: Colors.white,
        onPressed: () => _goTo(ShellTab.reports, reset: true),
      ),
    ));
  }

  /// A developer reset wiped the passenger data on the server: close open screens and start clean.
  Future<void> _onReset() async {
    if (!mounted) return;
    _unread.value = 0;
    setState(() {
      _tab = ShellTab.home;
      _navigators = {for (final t in ShellTab.values) t: GlobalKey<NavigatorState>()};
    });
    await AppData.instance.clearPassengerData();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text('Demo data was reset. Everything starts fresh.'),
    ));
  }

  void _goTo(ShellTab tab, {Widget? push, bool reset = false}) {
    final nav = _navigators[tab]!.currentState;
    if (reset || (tab == _tab && push == null)) nav?.popUntil((r) => r.isFirst);
    setState(() => _tab = tab);
    if (tab == ShellTab.reports) _unread.value = 0;
    if (push != null) nav?.push(MaterialPageRoute(builder: (_) => push));
  }

  Widget _root(ShellTab tab) => switch (tab) {
        ShellTab.home => const HomeScreen(),
        ShellTab.find => const FoundItemsScreen(),
        ShellTab.reports => const MyReportsScreen(),
        ShellTab.help => const HelpScreen(),
      };

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // Android back: pop inside the tab first, then go Home, then leave the app.
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = _navigators[_tab]!.currentState!;
        if (nav.canPop()) {
          nav.pop();
        } else if (_tab != ShellTab.home) {
          setState(() => _tab = ShellTab.home);
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab.index,
          children: [
            for (final t in ShellTab.values)
              Navigator(
                key: _navigators[t],
                onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => _root(t)),
              ),
          ],
        ),
        bottomNavigationBar: ValueListenableBuilder<int>(
          valueListenable: _unread,
          builder: (_, unread, _) => NavigationBar(
            selectedIndex: _tab.index,
            onDestinationSelected: (i) => _goTo(ShellTab.values[i]),
            destinations: [
              const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
              const NavigationDestination(icon: Icon(Icons.search), label: 'Find items'),
              NavigationDestination(
                icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.assignment_outlined)),
                selectedIcon: const Icon(Icons.assignment),
                label: 'My reports',
              ),
              const NavigationDestination(icon: Icon(Icons.help_outline), selectedIcon: Icon(Icons.help), label: 'Help'),
            ],
          ),
        ),
      ),
    );
  }
}
