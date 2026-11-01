import 'package:flutter/material.dart';

import 'i18n.dart';

/// How a point of interest looks on the map: its icon, colour and a readable label.
class PoiStyle {
  final IconData icon;
  final Color color;
  final String label;
  const PoiStyle(this.icon, this.color, this.label);
}

const _food = Color(0xFFE07A16);
const _shop = Color(0xFF8E5BD8);
const _money = Color(0xFF2E9E5B);
const _care = Color(0xFF2A8FBD);
const _service = Color(0xFF5B6B85);

const poiStyles = <String, PoiStyle>{
  // Food & drink
  'cafe': PoiStyle(Icons.local_cafe, _food, 'Café'),
  'restaurant': PoiStyle(Icons.restaurant, _food, 'Restaurant'),
  'fast_food': PoiStyle(Icons.fastfood, _food, 'Fast food'),
  'food_court': PoiStyle(Icons.ramen_dining, _food, 'Food court'),
  'bar': PoiStyle(Icons.local_bar, _food, 'Bar / pub'),
  'ice_cream': PoiStyle(Icons.icecream, _food, 'Ice cream'),
  'vending': PoiStyle(Icons.local_drink, _food, 'Vending machine'),
  'water': PoiStyle(Icons.water_drop, _care, 'Drinking water'),
  // Shops
  'clothes': PoiStyle(Icons.checkroom, _shop, 'Fashion'),
  'shoes': PoiStyle(Icons.directions_walk, _shop, 'Shoes'),
  'gift': PoiStyle(Icons.card_giftcard, _shop, 'Gifts & souvenirs'),
  'newsagent': PoiStyle(Icons.newspaper, _shop, 'Newsagent'),
  'books': PoiStyle(Icons.menu_book, _shop, 'Books & magazines'),
  'bag': PoiStyle(Icons.shopping_bag, _shop, 'Bags & luggage'),
  'electronics': PoiStyle(Icons.headphones, _shop, 'Electronics'),
  'jewelry': PoiStyle(Icons.diamond, _shop, 'Jewellery'),
  'watch': PoiStyle(Icons.watch, _shop, 'Watches'),
  'beauty': PoiStyle(Icons.spa, _shop, 'Beauty & fragrance'),
  'duty_free': PoiStyle(Icons.local_mall, _shop, 'Duty free / department store'),
  'convenience': PoiStyle(Icons.local_grocery_store, _shop, 'Convenience store'),
  'alcohol': PoiStyle(Icons.wine_bar, _shop, 'Wine & spirits'),
  'optician': PoiStyle(Icons.remove_red_eye, _shop, 'Optician'),
  'toys': PoiStyle(Icons.toys, _shop, 'Toys'),
  'tobacco': PoiStyle(Icons.smoking_rooms, _shop, 'Tobacco'),
  'sweets': PoiStyle(Icons.cake, _shop, 'Sweets & chocolate'),
  'travel': PoiStyle(Icons.flight_takeoff, _shop, 'Travel agency'),
  'camera': PoiStyle(Icons.photo_camera, _shop, 'Photo'),
  'shop': PoiStyle(Icons.storefront, _shop, 'Shop'),
  // Money
  'atm': PoiStyle(Icons.local_atm, _money, 'Cash machine (ATM)'),
  'currency': PoiStyle(Icons.currency_exchange, _money, 'Currency exchange'),
  'bank': PoiStyle(Icons.account_balance, _money, 'Bank'),
  // Care & comfort
  'toilets': PoiStyle(Icons.wc, _care, 'Toilets'),
  'pharmacy': PoiStyle(Icons.local_pharmacy, _care, 'Pharmacy'),
  'medical': PoiStyle(Icons.medical_services, Color(0xFFD64545), 'Medical / first aid'),
  'baby': PoiStyle(Icons.baby_changing_station, _care, 'Baby changing'),
  'prayer': PoiStyle(Icons.self_improvement, _care, 'Prayer / quiet room'),
  'lounge': PoiStyle(Icons.weekend, _care, 'Lounge'),
  'charging': PoiStyle(Icons.battery_charging_full, _care, 'Device charging'),
  'smoking': PoiStyle(Icons.smoking_rooms, _service, 'Smoking area'),
  // Services
  'info': PoiStyle(Icons.info, Color(0xFF2F6FE4), 'Information desk'),
  'lost_property': PoiStyle(Icons.inventory_2, Color(0xFFE5484D), 'Lost property'),
  'telephone': PoiStyle(Icons.phone, _service, 'Payphone'),
  'post': PoiStyle(Icons.local_post_office, _service, 'Post box'),
  'wifi': PoiStyle(Icons.wifi, _service, 'Internet'),
  'luggage': PoiStyle(Icons.luggage, _service, 'Luggage lockers'),
  'police': PoiStyle(Icons.local_police, _service, 'Police'),
  'car_rental': PoiStyle(Icons.car_rental, _service, 'Car rental'),
  'taxi': PoiStyle(Icons.local_taxi, _service, 'Taxi'),
  'bus': PoiStyle(Icons.directions_bus, _service, 'Bus'),
};

PoiStyle poiStyle(String type, String kind) =>
    poiStyles[type] ??
    switch (kind) {
      'food' => poiStyles['restaurant']!,
      'shop' => poiStyles['shop']!,
      'toilets' => poiStyles['toilets']!,
      'money' => poiStyles['atm']!,
      'info' => poiStyles['info']!,
      'lost-property' => poiStyles['lost_property']!,
      _ => const PoiStyle(Icons.place, _service, 'Point of interest'),
    };

/// Which markers win when they overlap on screen (lower = more important).
int poiPriority(String type, bool named) {
  const top = {'lost_property', 'info', 'toilets', 'medical', 'pharmacy'};
  const mid = {'cafe', 'restaurant', 'fast_food', 'food_court', 'bar', 'currency', 'atm', 'lounge', 'charging'};
  const low = {'vending', 'telephone', 'post', 'water'};
  final base = top.contains(type) ? 0 : mid.contains(type) ? 2 : low.contains(type) ? 6 : 4;
  return base + (named ? 0 : 1);
}

// ---------------------------------------------------------------- opening hours

const _dayKeys = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

class _Rule {
  final Set<int> days; // 0 = Monday
  final List<(int, int)> spans; // minutes from midnight; empty = closed
  final String text;
  _Rule(this.days, this.spans, this.text);
}

/// Simple OpenStreetMap `opening_hours` reader ("Mo-Fr 09:00-17:30; Sa 09:00-13:00", "24/7").
/// Returns null when the value uses syntax it doesn't understand (the raw text is shown instead).
class OpeningHours {
  final List<_Rule> _rules;
  OpeningHours._(this._rules);

  static OpeningHours? tryParse(String raw) {
    final rules = <_Rule>[];
    for (var part in raw.split(';')) {
      part = part.trim();
      if (part.isEmpty) continue;
      if (part == '24/7') {
        rules.add(_Rule({0, 1, 2, 3, 4, 5, 6}, [(0, 1440)], 'Open 24 hours, every day'.tr));
        continue;
      }
      final m = RegExp(r'^((?:Mo|Tu|We|Th|Fr|Sa|Su)(?:-(?:Mo|Tu|We|Th|Fr|Sa|Su))?(?:,(?:Mo|Tu|We|Th|Fr|Sa|Su)(?:-(?:Mo|Tu|We|Th|Fr|Sa|Su))?)*)?\s*(.+)$')
          .firstMatch(part);
      if (m == null) return null;
      final days = <int>{};
      if (m.group(1) == null) {
        days.addAll([0, 1, 2, 3, 4, 5, 6]);
      } else {
        for (final d in m.group(1)!.split(',')) {
          final ends = d.split('-').map(_dayKeys.indexOf).toList();
          for (var i = ends.first;; i = (i + 1) % 7) {
            days.add(i);
            if (i == ends.last) break;
          }
        }
      }
      final times = m.group(2)!.trim();
      final spans = <(int, int)>[];
      if (times != 'off' && times != 'closed') {
        for (final t in times.split(',')) {
          final tm = RegExp(r'^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$').firstMatch(t.trim());
          if (tm == null) return null;
          int mins(int i) => int.parse(tm.group(i)!) * 60 + int.parse(tm.group(i + 1)!);
          spans.add((mins(1), mins(3)));
        }
      }
      rules.add(_Rule(days, spans, '${_describeDays(days)} · ${_describeSpans(spans)}'));
    }
    return rules.isEmpty ? null : OpeningHours._(rules);
  }

  /// One readable line per rule, e.g. "Every day · 05:00–22:00".
  List<String> get lines => [for (final r in _rules) r.text];

  List<(int, int)> _spansOn(int day) {
    List<(int, int)> out = const [];
    for (final r in _rules) {
      if (r.days.contains(day)) out = r.spans; // later rules override earlier ones
    }
    return out;
  }

  /// "Open now · closes 22:00" / "Closed now · opens 05:00".
  (bool open, String text) statusAt(DateTime now) {
    final day = now.weekday - 1;
    final mins = now.hour * 60 + now.minute;
    final today = _spansOn(day);
    final yesterday = _spansOn((day + 6) % 7);
    for (final (a, b) in today) {
      if (b - a >= 1439 || (a == 0 && b >= 1439)) return (true, 'Open 24 hours'.tr);
      final end = b <= a ? b + 1440 : b;
      if (mins >= a && mins < end) return (true, 'Open now · closes {time}'.trf({'time': _hhmm(b)}));
    }
    for (final (a, b) in yesterday) {
      if (b <= a && mins < b) return (true, 'Open now · closes {time}'.trf({'time': _hhmm(b)}));
    }
    final later = today.where((s) => s.$1 > mins).map((s) => s.$1).toList()..sort();
    if (later.isNotEmpty) return (false, 'Closed now · opens {time}'.trf({'time': _hhmm(later.first)}));
    for (var i = 1; i <= 7; i++) {
      final spans = _spansOn((day + i) % 7);
      if (spans.isNotEmpty) {
        final when = i == 1 ? 'tomorrow'.tr : weekdayShort((day + i) % 7);
        return (false, 'Closed now · opens {day} {time}'.trf({'day': when, 'time': _hhmm(spans.first.$1)}));
      }
    }
    return (false, 'Closed'.tr);
  }

  static String _hhmm(int m) => '${(m ~/ 60 % 24).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  static String _describeSpans(List<(int, int)> spans) {
    if (spans.isEmpty) return 'Closed'.tr;
    if (spans.length == 1 && spans.first.$1 == 0 && spans.first.$2 >= 1439) return 'Open 24 hours'.tr;
    return spans.map((s) => '${_hhmm(s.$1)}–${s.$2 >= 1440 ? '24:00' : _hhmm(s.$2)}').join(', ');
  }

  static String _describeDays(Set<int> days) {
    if (days.length == 7) return 'Every day'.tr;
    final sorted = days.toList()..sort();
    if (sorted.length >= 3 && sorted.last - sorted.first == sorted.length - 1) {
      return '${weekdayShort(sorted.first)}–${weekdayShort(sorted.last)}';
    }
    return sorted.map(weekdayShort).join(', ');
  }
}

/// "coffee_shop;sandwich" -> "Coffee shop, sandwich".
String humanizeTag(String v) {
  final s = v.split(';').map((e) => e.trim().replaceAll('_', ' ')).where((e) => e.isNotEmpty).join(', ');
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
