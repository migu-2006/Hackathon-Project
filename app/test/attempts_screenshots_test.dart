// Screenshots of the verification log (staff) and a wrong answer (passenger), with a fake backend:
//   flutter test test/attempts_screenshots_test.dart --update-goldens --dart-define=SCREENSHOTS=true
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
import 'package:lost_found_app/screens/passenger/item_details_screen.dart';
import 'package:lost_found_app/screens/staff/attempts_screen.dart';
import 'package:lost_found_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = bool.fromEnvironment('SCREENSHOTS');

final _item = {
  'id': 'a1b2c3d4e5f6', 'airport': 'LHR', 'zoneId': 'lhr-gate-a5', 'category': 'backpack', 'color': 'black',
  'location': 'Terminal 5 · Gate A5', 'timestamp': '2026-10-31T08:10:00Z', 'status': 'available',
  'secretDetail': 'Engraved initials M.A. and a cat sticker',
};

Map<String, dynamic> _attempt(String answer, String result, String time, {bool cleared = false}) =>
    {'id': answer.hashCode.toString(), 'claimId': 'c1', 'answer': answer, 'result': result, 'timestamp': time, 'cleared': cleared};

final _log = [
  {
    'userId': 'pax-7f3a91c2', 'itemId': 'a1b2c3d4e5f6', 'item': _item, 'failed': 3, 'maxAttempts': 3, 'locked': true,
    'lastAttempt': '2026-10-31T10:42:00Z',
    'attempts': [
      _attempt('nothing special', 'wrong', '2026-10-31T10:42:00Z'),
      _attempt('a dog sticker', 'wrong', '2026-10-31T10:41:00Z'),
      _attempt('a red keychain', 'wrong', '2026-10-31T10:39:00Z'),
    ],
  },
  {
    'userId': 'pax-02c4e8aa', 'itemId': 'f00d', 'failed': 1, 'maxAttempts': 3, 'locked': false,
    'item': {..._item, 'id': 'f00dcafe0001', 'category': 'wallet', 'color': 'brown', 'location': 'Terminal 3 · Security', 'secretDetail': 'Oyster card inside'},
    'lastAttempt': '2026-10-31T09:20:00Z',
    'attempts': [
      _attempt('there is an oyster card inside', 'correct', '2026-10-31T09:20:00Z'),
      _attempt('a train ticket', 'wrong', '2026-10-31T09:18:00Z'),
    ],
  },
];

MockClient _backend() => MockClient((req) async {
      final path = req.url.path;
      Object? body = [];
      if (path == '/staff/claim-attempts') body = _log;
      if (path == '/claims' && req.method == 'POST') {
        body = {'id': 'c9', 'question': 'Describe something distinctive about the item (contents, stickers, scratches, engravings).', 'status': 'awaiting_answer', 'attemptsLeft': 3};
      }
      if (path.endsWith('/answer')) {
        body = {'id': 'c9', 'status': 'awaiting_answer', 'correct': false, 'attemptsLeft': 2, 'message': "That doesn't match the details we hold. 2 attempt(s) left."};
      }
      if (path == '/lost-reports' && req.method == 'POST') {
        body = {'report': {'id': 'r1', 'userId': 'pax', 'airport': 'LHR', 'category': 'backpack', 'timestamp': '2026-10-31T08:00:00Z', 'status': 'searching'}, 'matches': []};
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });

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
    Api.instance.client = _backend();
    AppData.instance.userId = 'pax-shots';
  });

  testWidgets('staff verification log', skip: !_enabled, (tester) async {
    await _show(tester, const Scaffold(body: AttemptsScreen()));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screenshots/attempts_log.png'));
  });

  testWidgets('passenger wrong answer', skip: !_enabled, (tester) async {
    await _show(tester, VerifyClaimScreen(item: FoundItem.fromJson(_item)));
    await tester.enterText(find.byType(TextField), 'a red keychain');
    await tester.tap(find.text('Submit answer'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screenshots/verify_wrong_answer.png'));
  });
}
