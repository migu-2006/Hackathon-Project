// Screenshots of the sign-in page and the administrator's accounts screen, with a fake backend:
//   flutter test test/login_screenshots_test.dart --update-goldens --dart-define=SCREENSHOTS=true
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lost_found_app/api.dart';
import 'package:lost_found_app/app_state.dart';
import 'package:lost_found_app/models.dart';
import 'package:lost_found_app/screens/admin/admin_home.dart';
import 'package:lost_found_app/screens/login_screen.dart';
import 'package:lost_found_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = bool.fromEnvironment('SCREENSHOTS');

const _admin = AppUser(id: 'a1', email: 'admin@skyfindr.app', name: 'Administrator', role: 'admin');

Future<void> _loadFonts() async {
  final dir = '${Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter'}/bin/cache/artifacts/material_fonts';
  Future<ByteData> bytes(String f) async => ByteData.view(File('$dir/$f').readAsBytesSync().buffer);
  await (FontLoader('Roboto')
        ..addFont(bytes('roboto-regular.ttf'))
        ..addFont(bytes('roboto-medium.ttf'))
        ..addFont(bytes('roboto-bold.ttf')))
      .load();
  await (FontLoader('MaterialIcons')..addFont(bytes('materialicons-regular.otf'))).load();
}

Future<void> _show(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.light), home: page));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (!_enabled) return;
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
    Api.instance.client = MockClient((req) async {
      Object body = [];
      if (req.url.path == '/admin/users') {
        body = [
          _admin.toJson(),
          {'id': 's1', 'email': 'maria.ionescu@skyfindr.app', 'name': 'Maria Ionescu', 'role': 'staff', 'airport': 'CRA'},
          {'id': 's2', 'email': 'james.cole@skyfindr.app', 'name': 'James Cole', 'role': 'staff', 'airport': 'LHR'},
          {'id': 'p1', 'email': 'ana.pop@gmail.com', 'name': 'Ana Pop', 'role': 'passenger'},
          {'id': 'p2', 'email': 'tom.r@outlook.com', 'name': 'Tom Reed', 'role': 'passenger', 'disabled': 1},
        ];
      }
      if (req.url.path == '/meta') {
        body = {'airport': {'code': 'CRA', 'name': 'Craiova', 'short': 'Craiova', 'country': 'RO', 'desk': '', 'team': ''}, 'airports': [], 'zones': []};
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
  });

  testWidgets('sign-in page', skip: !_enabled, (tester) async {
    await _show(tester, const LoginScreen());
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screenshots/login_passenger.png'));
    await tester.tap(find.text('Staff'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screenshots/login_staff.png'));
  });

  testWidgets('administrator accounts', skip: !_enabled, (tester) async {
    AppData.instance.session.value = _admin;
    await _show(tester, const AdminHome());
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screenshots/admin_accounts.png'));
    await tester.tap(find.text('Add staff account'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screenshots/admin_new_account.png'));
  });
}
