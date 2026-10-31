import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lost_found_app/api.dart';
import 'package:lost_found_app/app_state.dart';
import 'package:lost_found_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _user(String role) =>
    {'id': 'u-$role', 'email': '$role@skyfindr.app', 'name': 'Test ${role[0].toUpperCase()}${role.substring(1)}', 'role': role};

void main() {
  late List<http.Request> calls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppData.instance.loadPrefs(await SharedPreferences.getInstance());
    AppData.instance.session.value = null;
    Api.instance.token = null;
    calls = [];
    Api.instance.client = MockClient((req) async {
      calls.add(req);
      Object body = [];
      if (req.url.path == '/auth/login') {
        final sent = jsonDecode(req.body) as Map<String, dynamic>;
        body = sent['password'] == 'right'
            ? {'token': 'tok-123', 'user': _user(sent['role'] as String)}
            : {'detail': 'Wrong email or password'};
        if (sent['password'] != 'right') return http.Response(jsonEncode(body), 401);
      } else if (req.url.path == '/admin/users') {
        body = [_user('admin'), _user('staff'), {..._user('passenger'), 'disabled': 1}];
      } else if (req.url.path == '/meta') {
        body = {
          'airport': {'code': 'LHR', 'name': 'London Heathrow', 'short': 'Heathrow', 'country': 'UK', 'desk': '', 'team': ''},
          'airports': [],
          'zones': [],
        };
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });
  });

  Future<void> signIn(WidgetTester tester, String portal, String password) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const LostFoundApp(splash: false));
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    await tester.tap(find.text(portal));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'someone@skyfindr.app');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), password);
    await tester.tap(find.text('Sign in'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('wrong password shows the error and stays on the sign-in page', (tester) async {
    await signIn(tester, 'Staff', 'wrong');
    expect(find.text('Wrong email or password'), findsOneWidget);
    expect(find.text('Staff sign-in'), findsOneWidget);
    expect(AppData.instance.user, isNull);
  });

  testWidgets('staff sign-in opens the staff desk and sends the token', (tester) async {
    await signIn(tester, 'Staff', 'right');
    expect(jsonDecode(calls.firstWhere((r) => r.url.path == '/auth/login').body)['role'], 'staff');
    expect(AppData.instance.user!.role, 'staff');
    expect(find.text('Staff · Smart Intake'), findsOneWidget);
    expect(calls.last.headers['Authorization'], 'Bearer tok-123');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), 'tok-123'); // stays signed in after a restart
  });

  testWidgets('administrator sign-in lists the accounts; sign out returns to the sign-in page', (tester) async {
    await signIn(tester, 'Admin', 'right');
    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('Test Staff'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Staff · 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    expect(Api.instance.token, isNull);
    expect(calls.any((r) => r.url.path == '/auth/logout'), isTrue);
  });
}
