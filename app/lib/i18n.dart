import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n_strings.dart';

/// App languages. English text in the code is the translation key; Romanian and Spanish come
/// from [translations] (i18n_strings.dart). Anything without a translation stays in English.
enum AppLanguage {
  en('English'),
  ro('Română'),
  es('Español');

  final String nativeName;
  const AppLanguage(this.nativeName);

  Locale get locale => Locale(name);
}

class I18n {
  I18n._();

  static final language = ValueNotifier(AppLanguage.en);
  static AppLanguage get current => language.value;

  /// Saved choice, else the device language when it's one we have, else English.
  static void load(SharedPreferences prefs) {
    final saved = AppLanguage.values.asNameMap()[prefs.getString('language')];
    final device = AppLanguage.values.asNameMap()[PlatformDispatcher.instance.locale.languageCode];
    language.value = saved ?? device ?? AppLanguage.en;
  }

  static Future<void> set(AppLanguage lang) async {
    if (lang == language.value) return;
    language.value = lang;
    _rebuildAll();
    await (await SharedPreferences.getInstance()).setString('language', lang.name);
  }

  /// Text is looked up while building, so every widget has to build again. Rebuilding in place
  /// keeps open screens, tabs and typed text (no restart, no lost navigation).
  static void _rebuildAll() {
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(mark);
  }
}

String _lookup(String english) {
  final lang = I18n.current;
  if (lang == AppLanguage.en) return english;
  final t = translations[english];
  if (t == null) return english;
  final s = lang == AppLanguage.ro ? t.$1 : t.$2;
  return s.isEmpty ? english : s;
}

String _fill(String s, Map<String, Object?> args) {
  for (final e in args.entries) {
    s = s.replaceAll('{${e.key}}', '${e.value}');
  }
  return s;
}

extension Tr on String {
  /// This English text in the current language.
  String get tr => _lookup(this);

  /// Translated, with `{name}` placeholders filled in: `'Found {date}'.trf({'date': d})`.
  String trf(Map<String, Object?> args) => _fill(_lookup(this), args);
}

/// Count-dependent text. [other] is the translation key; its translations list the plural forms
/// separated by `|`: Romanian "one|few|many" (1 obiect | 3 obiecte | 20 de obiecte), Spanish
/// "one|other". `{n}` is replaced by the count.
String trn(int n, String one, String other, [Map<String, Object?> args = const {}]) {
  final all = {'n': n, ...args};
  final lang = I18n.current;
  final t = lang == AppLanguage.en ? null : translations[other];
  if (t == null) return _fill(n == 1 ? one : other, all);
  final forms = (lang == AppLanguage.ro ? t.$1 : t.$2).split('|');
  final int i;
  if (lang == AppLanguage.ro) {
    // CLDR: one = 1; few = 0 or 2..19 (by last two digits); many = the rest ("de").
    final r = n % 100;
    i = n == 1 ? 0 : (n == 0 || (r >= 1 && r <= 19)) ? 1 : 2;
  } else {
    i = n == 1 ? 0 : 1;
  }
  return _fill(forms[i.clamp(0, forms.length - 1)], all);
}

// ---------------------------------------------------------------- dates

const _monthsLong = {
  AppLanguage.en: ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'],
  AppLanguage.ro: ['ianuarie', 'februarie', 'martie', 'aprilie', 'mai', 'iunie', 'iulie', 'august', 'septembrie', 'octombrie', 'noiembrie', 'decembrie'],
  AppLanguage.es: ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'],
};

const _monthsShort = {
  AppLanguage.en: ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
  AppLanguage.ro: ['ian.', 'feb.', 'mar.', 'apr.', 'mai', 'iun.', 'iul.', 'aug.', 'sept.', 'oct.', 'nov.', 'dec.'],
  AppLanguage.es: ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sept', 'oct', 'nov', 'dic'],
};

/// "1 November 2026" / "1 noiembrie 2026" / "1 de noviembre de 2026".
String longDate(DateTime d) {
  final m = _monthsLong[I18n.current]![d.month - 1];
  return I18n.current == AppLanguage.es ? '${d.day} de $m de ${d.year}' : '${d.day} $m ${d.year}';
}

/// "1 Nov" / "1 nov." / "1 nov".
String shortDay(DateTime d) => '${d.day} ${_monthsShort[I18n.current]![d.month - 1]}';

/// Mon..Sun, 0 = Monday.
String weekdayShort(int i) => const {
      AppLanguage.en: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
      AppLanguage.ro: ['lun.', 'mar.', 'mie.', 'joi', 'vin.', 'sâm.', 'dum.'],
      AppLanguage.es: ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'],
    }[I18n.current]![i];

// ---------------------------------------------------------------- items

/// Category name on its own: "Backpack" / "Rucsac" / "Mochila".
String categoryName(String c) {
  if (I18n.current == AppLanguage.en) return _cap(c);
  if (c == 'other') return I18n.current == AppLanguage.ro ? 'Altele' : 'Otros';
  final n = categoryNouns[c];
  if (n == null) return _cap(c);
  return _cap(I18n.current == AppLanguage.ro ? n.$1 : n.$3);
}

/// Colour name on its own: "Black" / "Negru" / "Negro".
String colorName(String c) {
  if (I18n.current == AppLanguage.en) return _cap(c);
  final forms = colorForms[c];
  if (forms == null) return _cap(c);
  return _cap((I18n.current == AppLanguage.ro ? forms.$1 : forms.$2)[0]);
}

/// "Black backpack" / "Rucsac negru" / "Mochila negra": the colour agrees with the noun.
String itemName(String? color, String category) {
  final hasColor = color != null && color.isNotEmpty;
  if (I18n.current == AppLanguage.en) {
    return _cap('${hasColor ? '$color ' : ''}${category == 'other' ? 'item' : category}');
  }
  final ro = I18n.current == AppLanguage.ro;
  final n = categoryNouns[category] ?? categoryNouns['other']!;
  final noun = ro ? n.$1 : n.$3;
  final form = ro ? n.$2 : n.$4;
  final forms = hasColor ? colorForms[color] : null;
  final adj = forms == null ? (hasColor ? color : null) : (ro ? forms.$1 : forms.$2)[form];
  return _cap(adj == null ? noun : '$noun $adj');
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
