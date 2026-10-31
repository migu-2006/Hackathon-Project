import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'app_state.dart';
import 'screens/passenger/shell.dart';
import 'screens/splash.dart';
import 'theme.dart';

/// Anonymous passenger identity. Built from two 16-bit halves because on web `1 << 32`
/// is 0 (JS 32-bit shifts), which made `nextInt` throw and left a blank page.
String newPassengerId() {
  final r = Random();
  String half() => r.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
  return 'pax-${half()}${half()}';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // Anonymous passenger identity, persisted on the device.
  final userId = prefs.getString('userId') ?? newPassengerId();
  await prefs.setString('userId', userId);
  final savedUrl = prefs.getString('baseUrl');
  if (savedUrl != null) Api.instance.baseUrl = savedUrl;
  await AppData.instance.loadPrefs(prefs, userId);
  runApp(const LostFoundApp());
}

class LostFoundApp extends StatelessWidget {
  final bool splash; // startup animation (off in tests)
  const LostFoundApp({super.key, this.splash = true});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppData.instance.themeMode,
      builder: (_, mode, _) => MaterialApp(
        title: 'SkyFindr · Airport Lost & Found',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        home: AppShell.create(),
        builder: (context, child) => splash ? StartupSplash(child: child!) : child!,
      ),
    );
  }
}
