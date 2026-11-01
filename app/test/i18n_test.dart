import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lost_found_app/app_state.dart';
import 'package:lost_found_app/i18n.dart';
import 'package:lost_found_app/main.dart';
import 'package:lost_found_app/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => I18n.language.value = AppLanguage.en);

  test('plain, placeholder and plural text', () {
    I18n.language.value = AppLanguage.ro;
    expect('Find items'.tr, 'Caută obiecte');
    expect('Level {level}'.trf({'level': 2}), 'Nivelul 2');
    expect('No translation for this'.tr, 'No translation for this'); // falls back to English
    String items(int n) => trn(n, '{n} item found', '{n} items found');
    expect([items(1), items(3), items(20), items(101)],
        ['1 obiect găsit', '3 obiecte găsite', '20 de obiecte găsite', '101 obiecte găsite']);

    I18n.language.value = AppLanguage.es;
    expect([items(1), items(5)], ['1 objeto encontrado', '5 objetos encontrados']);

    I18n.language.value = AppLanguage.en;
    expect([items(1), items(2)], ['1 item found', '2 items found']);
  });

  test('item names agree with the colour; dates use local month names', () {
    final d = DateTime(2026, 11, 1);
    I18n.language.value = AppLanguage.en;
    expect(itemName('black', 'backpack'), 'Black backpack');
    expect(longDate(d), '1 November 2026');

    I18n.language.value = AppLanguage.ro;
    expect([itemName('black', 'backpack'), itemName('black', 'handbag'), itemName('white', 'keys'), itemName(null, 'other')],
        ['Rucsac negru', 'Geantă neagră', 'Chei albe', 'Obiect']);
    expect(longDate(d), '1 noiembrie 2026');

    I18n.language.value = AppLanguage.es;
    expect([itemName('black', 'backpack'), itemName('red', 'shoes'), categoryName('other')],
        ['Mochila negra', 'Zapatos rojos', 'Otros']);
    expect(longDate(d), '1 de noviembre de 2026');
  });

  testWidgets('switching language updates the open screen in place', (tester) async {
    AppData.instance.userId = 'pax-test';
    AppData.instance.session.value = const AppUser(id: 'pax-test', email: 'ana@mail.com', name: 'Ana Pop', role: 'passenger');
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const LostFoundApp(splash: false));
    await tester.pump();
    expect(find.text('Report a lost item'), findsOneWidget);

    await tester.runAsync(() => I18n.set(AppLanguage.ro));
    await tester.pump();
    expect(find.text('Raportați un obiect pierdut'), findsOneWidget);
    expect(find.text('Caută obiecte'), findsOneWidget); // bottom navigation
    expect(Localizations.localeOf(tester.element(find.text('Caută obiecte'))), const Locale('ro'));

    await tester.runAsync(() => I18n.set(AppLanguage.es));
    await tester.pump();
    expect(find.text('Informar de un objeto perdido'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('language'), 'es');
  });
}
