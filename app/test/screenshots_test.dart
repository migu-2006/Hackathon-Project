// Renders real-looking screenshots of the airport map without a device or backend:
//   flutter test test/screenshots_test.dart --update-goldens --dart-define=SCREENSHOTS=true
// Output: build/screenshots/*.png. Skipped in normal test runs.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lost_found_app/api.dart';
import 'package:lost_found_app/app_state.dart';
import 'package:lost_found_app/screens/passenger/map_screen.dart';
import 'package:lost_found_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = bool.fromEnvironment('SCREENSHOTS');

const _airports = {
  'LHR': {'code': 'LHR', 'name': 'London Heathrow', 'short': 'Heathrow', 'country': 'United Kingdom', 'desk': 'Lost Property desk', 'team': 'Lost Property team'},
  'CRA': {'code': 'CRA', 'name': 'Craiova International Airport', 'short': 'Craiova', 'country': 'Romania', 'desk': 'Lost & Found desk', 'team': 'Lost & Found team'},
};

Map<String, dynamic> _map(String code) =>
    jsonDecode(File('../backend/app/maps/$code.json').readAsStringSync()) as Map<String, dynamic>;

List<Map<String, dynamic>> _zones(String code, {bool withItems = false}) {
  final zones = [
    for (final z in _map(code)['zones'] as List) {...z as Map<String, dynamic>, 'label': '${z['terminal']} · ${z['name']}', 'items': []}
  ];
  if (withItems) {
    // A few fake found items so pins show up.
    for (final (i, z) in zones.indexed.where((e) => e.$1 % (code == 'LHR' ? 23 : 2) == 0).take(5)) {
      z['items'] = [
        for (var k = 0; k <= i % 3; k++)
          {
            'id': 'it$i$k', 'airport': code, 'zoneId': z['id'], 'category': 'backpack', 'color': 'black',
            'location': z['label'], 'timestamp': '2026-10-31T09:00:00Z', 'status': 'available',
          }
      ];
    }
  }
  return zones;
}

MockClient _backend() => MockClient((req) async {
      final path = req.url.path;
      final airport = req.url.queryParameters['airport'] ?? 'LHR';
      Object? body;
      if (path == '/meta') {
        body = {'airport': _airports[airport], 'zones': _zones(airport), 'airports': _airports.values.toList()};
      } else if (path.startsWith('/map/')) {
        body = _map(path.split('/').last);
      } else if (path.startsWith('/airports/') && path.endsWith('/zones')) {
        body = _zones(path.split('/')[2], withItems: true);
      } else {
        body = [];
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });

Future<void> _loadFonts() async {
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter';
  final dir = '$sdk/bin/cache/artifacts/material_fonts';
  Future<ByteData> bytes(String f) async => ByteData.view(Uint8List.fromList(File('$dir/$f').readAsBytesSync()).buffer);
  await (FontLoader('Roboto')
        ..addFont(bytes('roboto-regular.ttf'))
        ..addFont(bytes('roboto-medium.ttf'))
        ..addFont(bytes('roboto-bold.ttf')))
      .load();
  await (FontLoader('MaterialIcons')..addFont(bytes('materialicons-regular.otf'))).load();
}

void main() {
  setUpAll(() async {
    if (!_enabled) return;
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
    Api.instance.client = _backend();
    AppData.instance.userId = 'pax-shots';
  });

  // (airport, dark, zone to zoom on like "View on map", file suffix)
  final shots = [
    ('LHR', false, null, 'light'),
    ('LHR', true, null, 'dark'),
    ('CRA', false, null, 'light'),
    ('CRA', true, null, 'dark'),
    ('LHR', false, 'lhr-gate-a5', 'zoom_t5'),
  ];
  for (final (code, dark, focus, suffix) in shots) {
    {
      testWidgets('map $code $suffix', skip: !_enabled, (tester) async {
        tester.view.physicalSize = const Size(1170, 2400);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        AppData.instance.airports = [];
        await tester.runAsync(() async {
          AppData.instance.zones = [];
          await AppData.instance.setAirport(code);
          await AppData.instance.mapFor(code);
        });
        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(dark ? Brightness.dark : Brightness.light),
          home: AirportMapScreen(airport: code, focusZoneId: focus),
        ));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(AirportMapScreen),
          matchesGoldenFile('../build/screenshots/map_${code.toLowerCase()}_$suffix.png'),
        );
      });
    }
  }

  testWidgets('map LHR poi popup', skip: !_enabled, (tester) async {
    tester.view.physicalSize = const Size(1170, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await AppData.instance.setAirport('LHR');
      await AppData.instance.mapFor('LHR');
    });
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      home: const AirportMapScreen(airport: 'LHR', focusZoneId: 'lhr-gate-b44'),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(AirportMapScreen), matchesGoldenFile('../build/screenshots/map_lhr_pois.png'));
    final cafe = find.byIcon(Icons.local_cafe).hitTestable();
    expect(cafe, findsWidgets);
    await tester.tap(cafe.first);
    await tester.pumpAndSettle();
    expect(find.text('Opening hours'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screenshots/map_lhr_poi_popup.png'));
  });
}
