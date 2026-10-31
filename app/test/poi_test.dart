import 'package:flutter_test/flutter_test.dart';
import 'package:lost_found_app/poi.dart';

void main() {
  test('reads common opening_hours values', () {
    final h = OpeningHours.tryParse('Mo-Fr 09:00-17:30; Sa 09:00-13:00')!;
    expect(h.lines, ['Mon–Fri · 09:00–17:30', 'Sat · 09:00–13:00']);
    // 2026-11-02 is a Monday.
    expect(h.statusAt(DateTime(2026, 11, 2, 10)), (true, 'Open now · closes 17:30'));
    expect(h.statusAt(DateTime(2026, 11, 2, 8)), (false, 'Closed now · opens 09:00'));
    expect(h.statusAt(DateTime(2026, 11, 7, 14)), (false, 'Closed now · opens Mon 09:00'));

    expect(OpeningHours.tryParse('24/7')!.statusAt(DateTime(2026, 11, 2, 3)).$1, isTrue);
    expect(OpeningHours.tryParse('Mo-Su 00:00-24:00')!.lines, ['Every day · Open 24 hours']);
    expect(OpeningHours.tryParse('Mo-Su 06:00-24:00')!.statusAt(DateTime(2026, 11, 2, 23)).$2, 'Open now · closes 00:00');
    expect(OpeningHours.tryParse('05:00-22:00')!.lines, ['Every day · 05:00–22:00']);
    expect(OpeningHours.tryParse('sunrise-sunset'), isNull);
  });

  test('every POI type has its own icon', () {
    final icons = <Object>{};
    for (final e in poiStyles.entries.where((e) => e.key != 'tobacco')) {
      expect(icons.add(e.value.icon), isTrue, reason: '${e.key} reuses an icon');
    }
  });
}
