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
  var signInAs = 'passenger'; // role of the account the fake server signs in

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppData.instance.loadPrefs(await SharedPreferences.getInstance());
    AppData.instance.session.value = null;
    Api.instance.token = null;
    calls = [];
    Api.instance.baseUrl = 'http://10.0.0.7:8000';
    Api.instance.client = MockClient((req) async {
      calls.add(req);
      Object body = [];
      if (req.url.path == '/auth/login') {
        final sent = jsonDecode(req.body) as Map<String, dynamic>;
        body = sent['password'] == 'right'
            ? {'token': 'tok-123', 'user': _user(signInAs)}
            : {'detail': 'Wrong email or password'};
        if (sent['password'] != 'right') return http.Response(jsonEncode(body), 401);
      } else if (req.url.path == '/auth/register') {
        body = {'verificationRequired': true, 'email': 'new@mail.com', 'resendSeconds': 60};
      } else if (req.url.path == '/auth/verify') {
        if (jsonDecode(req.body)['code'] != '123456') {
          return http.Response(jsonEncode({'detail': "That code isn't right. 4 attempt(s) left."}), 400);
        }
        body = {'token': 'tok-new', 'user': _user('passenger')};
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

  Future<void> signIn(WidgetTester tester, String role, String password) async {
    signInAs = role;
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const LostFoundApp(splash: false));
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Staff'), findsNothing); // no role picker: the account decides
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'someone@skyfindr.app');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), password);
    await tester.tap(find.text('Sign in'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('sign-up asks for the emailed code, then opens the passenger app', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const LostFoundApp(splash: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Full name'), 'New Pax');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'new@mail.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'secret1');
    await tester.tap(find.text('Create account'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    // No session yet: the code screen.
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('new@mail.com', findRichText: true), findsOneWidget);
    expect(find.text('Resend code in 60s'), findsOneWidget);
    expect(AppData.instance.user, isNull);

    // A wrong code shows the server's message and clears the boxes.
    await tester.enterText(find.byType(TextField), '111111'); // six digits submit by themselves
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.textContaining('4 attempt(s) left'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(AppData.instance.user!.role, 'passenger');
    expect(Api.instance.token, 'tok-new');
    expect(find.text('Check your email'), findsNothing); // closed: the passenger app is showing
  });

  testWidgets('wrong password shows the error and stays on the sign-in page', (tester) async {
    await signIn(tester, 'staff', 'wrong');
    expect(find.text('Wrong email or password'), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(AppData.instance.user, isNull);
  });

  testWidgets('staff sign-in opens the staff desk and sends the token', (tester) async {
    await signIn(tester, 'staff', 'right');
    expect(jsonDecode(calls.firstWhere((r) => r.url.path == '/auth/login').body)['role'], isNull);
    expect(AppData.instance.user!.role, 'staff');
    expect(find.text('Staff · Smart Intake'), findsOneWidget);
    expect(calls.last.headers['Authorization'], 'Bearer tok-123');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('token'), 'tok-123'); // stays signed in after a restart

    // Only administrators see the server address.
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Server address'), findsNothing);
    expect(find.textContaining('10.0.0.7'), findsNothing);
  });

  testWidgets('server down: a plain message, never the server address', (tester) async {
    Api.instance.client = MockClient((req) async => throw http.ClientException('Connection refused', req.url));
    await signIn(tester, 'passenger', 'right');
    expect(find.text("Can't reach the server. Check your connection and try again."), findsOneWidget);
    expect(find.textContaining('10.0.0.7'), findsNothing);
    expect(find.textContaining('Server'), findsNothing);
  });

  testWidgets('administrator sign-in lists the accounts; sign out returns to the sign-in page', (tester) async {
    await signIn(tester, 'admin', 'right');
    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('Test Staff'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Staff · 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Server address'), findsOneWidget);
    expect(find.text('http://10.0.0.7:8000'), findsOneWidget);
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
