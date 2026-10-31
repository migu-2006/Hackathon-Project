import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lost_found_app/api.dart';
import 'package:lost_found_app/app_state.dart';
import 'package:lost_found_app/screens/developer_screen.dart';
import 'package:lost_found_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('developer reset sends the key and shows what was deleted', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = <http.Request>[];
    Api.instance.client = MockClient((req) async {
      calls.add(req);
      final body = req.url.path == '/dev/reset'
          ? {'deleted': {'lost_reports': 4, 'claims': 2}}
          : <String, dynamic>{};
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });
    AppData.instance.devKey = 'k3y';

    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const DeveloperScreen()));

    await tester.tap(find.text('Reset passenger data'));
    await tester.pumpAndSettle();
    expect(find.text('Reset all passenger data?'), findsOneWidget);
    await tester.tap(find.text('Delete everything'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    final reset = calls.firstWhere((r) => r.url.path == '/dev/reset');
    expect(reset.headers['X-Dev-Key'], 'k3y');
    expect(jsonDecode(reset.body), {'includeItems': false});
    expect(find.text('Reset done'), findsOneWidget);
    expect(find.textContaining('lost_reports: 4'), findsOneWidget);
  });
}
