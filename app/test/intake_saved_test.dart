import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lost_found_app/api.dart';
import 'package:lost_found_app/models.dart';
import 'package:lost_found_app/screens/staff/intake_screen.dart';
import 'package:lost_found_app/screens/staff/staff_home.dart';
import 'package:lost_found_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('registering an item confirms it and opens the inventory', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final itemJson = {
      'id': 'abc123',
      'airport': 'CRA',
      'category': 'phone',
      'color': 'navy',
      'location': 'Gate 3',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };
    var listCalls = 0;
    Api.instance.client = MockClient((req) async {
      if (req.url.path == '/found-items') listCalls++;
      final body = req.url.path == '/found-items' ? [itemJson] : [];
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });

    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const StaffHome()));
    await tester.pump();

    // What IntakeScreen does after the backend accepted the item.
    tester.widget<IntakeScreen>(find.byType(IntakeScreen)).onSaved!(FoundItem.fromJson(itemJson), 2);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull); // used to throw "setState() callback argument returned a Future"
    expect(find.text('Staff · Inventory'), findsOneWidget);
    expect(find.textContaining('registered at Gate 3'), findsOneWidget);
    expect(find.textContaining('2 passenger(s)'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);

    // The app bar's refresh reloads the open tab (here: the inventory).
    final before = listCalls;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(listCalls, before + 1);
    expect(find.byTooltip('Refresh'), findsOneWidget); // spinner done, button back
  });
}
