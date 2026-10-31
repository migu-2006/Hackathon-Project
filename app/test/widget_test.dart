import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lost_found_app/app_state.dart';
import 'package:lost_found_app/main.dart';
import 'package:lost_found_app/models.dart';
import 'package:lost_found_app/theme.dart';
import 'package:lost_found_app/ui.dart';
import 'package:lost_found_app/widgets.dart';

void main() {
  setUp(() => AppData.instance.userId = 'pax-test');

  testWidgets('home shows the SkyFindr landing page in light and dark', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      AppData.instance.themeMode.value = mode;
      await tester.pumpWidget(const LostFoundApp(splash: false));
      await tester.pump(const Duration(milliseconds: 500)); // theme switch animates
      expect(find.text('SkyFindr'), findsOneWidget);
      expect(find.text("Let's get you\nreunited."), findsOneWidget);
      expect(find.text('Report a lost item'), findsOneWidget);
      expect(find.text('Browse found items'), findsOneWidget);
      expect(find.text('Find items'), findsOneWidget);
      expect(Theme.of(tester.element(find.text('SkyFindr'))).scaffoldBackgroundColor,
          mode == ThemeMode.dark ? Palette.dark.background : Palette.light.background);
    }
  });

  test('stage and labels', () {
    final data = AppData.instance;
    final report = LostReport.fromJson({
      'id': 'abcdef123456', 'userId': 'pax-test', 'category': 'headphones', 'color': 'black',
      'timestamp': '2026-10-24T09:12:00Z', 'status': 'searching',
    });
    data.reports = [report];
    expect(data.stageOf(report), ReportStage.searching);
    data.claims = [
      Claim.fromJson({'id': 'c1', 'reportId': report.id, 'itemId': 'i1', 'timestamp': '2026-10-25T10:00:00Z', 'status': 'under_review'}),
    ];
    expect(data.stageOf(report), ReportStage.underReview);
    expect(data.reportRef(report), 'LHR-ABCDE');
    expect(itemTitle('black', 'headphones'), 'Black headphones');
    expect(categoryLabel('headphones'), 'Electronics · Headphones');
    expect(fmtDayYear(DateTime(2026, 10, 24)), '24 Oct 2026');
    expect(capitalize('backpack'), 'Backpack');
  });
}
