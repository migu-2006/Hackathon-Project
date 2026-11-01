import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lost_found_app/models.dart';
import 'package:lost_found_app/screens/passenger/baggage_screens.dart';
import 'package:lost_found_app/theme.dart';

Map<String, dynamic> _file(String status, List<String> events, {String method = 'deliver'}) => {
      'id': 'bg7k2m9q4x1z', 'ref': 'CRA-BG-00042', 'userId': 'p1', 'airport': 'CRA', 'flight': 'RO642',
      'tagNumbers': ['0281123456'], 'bagType': 'suitcase', 'color': 'red', 'deliveryMethod': method,
      'deliveryAddress': 'Hotel Ramada', 'status': status, 'handoverCode': status == 'out_for_delivery' ? 'B7K4QX' : null,
      'timestamp': '2026-10-31T11:20:00Z',
      'events': [
        for (final (i, k) in events.indexed)
          {'kind': k, 'station': k == 'located' ? 'OTP' : null, 'flight': k == 'forwarded' ? 'RO644' : null, 'timestamp': '2026-10-31T1$i:00:00Z'},
      ],
    };

Future<void> _show(WidgetTester tester, Map<String, dynamic> json) async {
  tester.view.physicalSize = const Size(1170, 4000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: SingleChildScrollView(child: BaggageCase(report: BaggageReport.fromJson(json)))),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a bag on its way shows the timeline and no delivery code yet', (tester) async {
    await _show(tester, _file('forwarded', ['reported', 'located', 'forwarded']));
    expect(find.text('Red suitcase'), findsOneWidget);
    expect(find.text('Bag located'), findsOneWidget);
    expect(find.textContaining('At OTP'), findsOneWidget);
    expect(find.textContaining('Flight RO644'), findsOneWidget);
    expect(find.text('Your bag reaches the airport'), findsOneWidget); // what comes next
    expect(find.text('Show delivery code'), findsNothing);
  });

  testWidgets('out for delivery: the passenger can open the delivery code', (tester) async {
    await _show(tester, _file('out_for_delivery', ['reported', 'found_here', 'out_for_delivery']));
    expect(find.text('Show delivery code'), findsOneWidget);
    expect(find.text('Delivered to you'), findsOneWidget);
    expect(find.text('Your next step: meet the driver'), findsOneWidget);
  });
}
