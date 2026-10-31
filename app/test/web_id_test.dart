import 'package:flutter_test/flutter_test.dart';
import 'package:lost_found_app/main.dart';

void main() {
  // Run with `flutter test --platform chrome` too: ids used `1 << 32`, which is 0 on web.
  test('passenger id format', () {
    expect(newPassengerId(), matches(RegExp(r'^pax-[0-9a-f]{8}$')));
  });
}
