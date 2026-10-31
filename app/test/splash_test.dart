// Startup animation: always checks it finishes and hands over to the app.
// With --dart-define=SCREENSHOTS=true --update-goldens it also saves frames to build/screenshots/splash_*.png.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lost_found_app/screens/splash.dart';

const _shots = bool.fromEnvironment('SCREENSHOTS');

void main() {
  testWidgets('startup animation plays and reveals the app', (tester) async {
    if (_shots) {
      final dir = '${Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter'}/bin/cache/artifacts/material_fonts';
      Future<ByteData> bytes(String f) async => ByteData.view(File('$dir/$f').readAsBytesSync().buffer);
      await tester.runAsync(() async {
        await (FontLoader('Roboto')..addFont(bytes('roboto-bold.ttf'))).load();
        await (FontLoader('MaterialIcons')..addFont(bytes('materialicons-regular.otf'))).load();
      });
    }
    tester.view.physicalSize = const Size(780, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Roboto'),
      home: const Scaffold(body: Center(child: Text('APP'))),
      builder: (context, child) => StartupSplash(child: child!),
    ));
    expect(find.text('SkyFindr'), findsOneWidget);

    var elapsed = 0;
    for (final ms in [40, 110, 200, 300, 450, 620, 760, 900, 1100, 1300]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      if (_shots) {
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screenshots/splash_${ms.toString().padLeft(4, '0')}.png'));
      }
    }
    await tester.pumpAndSettle();
    expect(find.text('SkyFindr'), findsNothing);
    expect(find.text('APP'), findsOneWidget);
  });
}
