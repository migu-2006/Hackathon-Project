import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'app_state.dart';
import 'i18n.dart';
import 'models.dart';
import 'screens/admin/admin_home.dart';
import 'screens/login_screen.dart';
import 'screens/passenger/shell.dart';
import 'screens/splash.dart';
import 'screens/staff/staff_home.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final savedUrl = prefs.getString('baseUrl');
  if (savedUrl != null) Api.instance.baseUrl = savedUrl;
  I18n.load(prefs);
  await AppData.instance.loadPrefs(prefs); // remembered session, if any
  unawaited(AppData.instance.verifySession());
  runApp(const LostFoundApp());
}

final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Sign-in page, or the home of the signed-in account's role.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  @override
  void initState() {
    super.initState();
    AppData.instance.session.addListener(_closePushedScreens);
  }

  @override
  void dispose() {
    AppData.instance.session.removeListener(_closePushedScreens);
    super.dispose();
  }

  /// Signing out (or a revoked session) must not leave e.g. the staff desk open on top.
  void _closePushedScreens() => rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppUser?>(
        valueListenable: AppData.instance.session,
        builder: (_, user, _) => KeyedSubtree(
          key: ValueKey(user?.id),
          child: switch (user?.role) {
            null => const LoginScreen(),
            'admin' => const AdminHome(),
            'staff' => const StaffHome(),
            _ => AppShell.create(),
          },
        ),
      );
}

class LostFoundApp extends StatelessWidget {
  final bool splash; // startup animation (off in tests)
  const LostFoundApp({super.key, this.splash = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([AppData.instance.themeMode, I18n.language]),
      builder: (_, _) => MaterialApp(
        title: 'SkyFindr · Airport Lost & Found',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: AppData.instance.themeMode.value,
        // Language picked in Account & settings; Flutter's own widgets (date pickers...) follow it.
        locale: I18n.current.locale,
        supportedLocales: [for (final l in AppLanguage.values) l.locale],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        navigatorKey: rootNavigatorKey,
        home: const RootGate(),
        builder: (context, child) => splash ? StartupSplash(child: child!) : child!,
      ),
    );
  }
}
