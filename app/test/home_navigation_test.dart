import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lost_found_app/api.dart';
import 'package:lost_found_app/app_state.dart';
import 'package:lost_found_app/models.dart';
import 'package:lost_found_app/screens/passenger/shell.dart';
import 'package:lost_found_app/theme.dart';

void main() {
  // Screens opened from Home must open on the Home tab, so Back returns to Home.
  testWidgets('Back from the map and the report forms opened on Home returns to Home', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    AppData.instance.session.value = const AppUser(id: 'p1', email: 'ana@mail.com', name: 'Ana', role: 'passenger');
    AppData.instance.userId = 'p1';
    Api.instance.baseUrl = 'http://test.local';
    Api.instance.client = MockClient((req) async {
      final body = req.url.path == '/meta'
          ? {
              'airport': {'code': 'CRA', 'name': 'Craiova', 'short': 'Craiova', 'country': 'RO', 'desk': '', 'team': ''},
              'airports': [],
              'zones': [],
            }
          : [];
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });

    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: AppShell.create()));
    await tester.pump(const Duration(seconds: 1));
    final home = find.text("Let's get you\nreunited.");
    expect(home, findsOneWidget);

    Future<void> openAndGoBack(Finder card, String screenText) async {
      await tester.ensureVisible(card);
      await tester.tap(card.hitTestable());
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(screenText), findsWidgets);
      await tester.tap(find.byIcon(Icons.arrow_back).hitTestable().first);
      await tester.pump(const Duration(seconds: 1));
      // Home is showing again (scrolled to the card that was tapped), not another tab.
      expect(card.hitTestable(), findsOneWidget, reason: 'Back from "$screenText" should land on Home');
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, ShellTab.home.index);
    }

    await openAndGoBack(find.text('Open map'), 'Craiova map');
    await openAndGoBack(find.text('Report a lost item').first, 'What did you lose?');
    await openAndGoBack(find.text("My checked bag didn't arrive"), "Your bag didn't arrive?");

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });
}
