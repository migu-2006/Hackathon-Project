import 'dart:ui';

import 'i18n.dart';

const categories = [
  'backpack', 'handbag', 'suitcase', 'wallet', 'phone', 'laptop', 'electronics',
  'headphones', 'camera', 'glasses', 'watch', 'jewelry', 'keys', 'clothing',
  'shoes', 'umbrella', 'bottle', 'cup', 'book', 'toy', 'sports', 'other',
];

const colors = [
  'black', 'white', 'gray', 'red', 'orange', 'yellow', 'green', 'blue',
  'navy', 'purple', 'pink', 'brown', 'beige',
];

class FoundItem {
  final String id;
  final String imageUrl; // blurred preview for passengers unless photoHidden is false
  final bool photoHidden; // true until the passenger finds it with a reverse image search
  final String category;
  final String label;
  final String color;
  final String colorHex;
  final String text;
  final String airport;
  final String? zoneId;
  final String location; // zone label, e.g. "Terminal 5 · Gate B42"; empty when locationHidden
  final bool locationHidden; // passengers: hidden until staff approve their claim on this item
  final String? notes;
  final String? secretDetail; // only present in the staff scan view
  final String source; // staff, or passenger (handed in through the app)
  final DateTime timestamp;
  final String status;

  bool get handedInByPassenger => source == 'passenger';

  FoundItem.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        airport = j['airport'] ?? 'LHR',
        zoneId = j['zoneId'],
        imageUrl = j['imageUrl'] ?? '',
        photoHidden = j['photoHidden'] ?? false,
        category = j['category'] ?? 'other',
        label = j['label'] ?? '',
        color = j['color'] ?? '',
        colorHex = j['colorHex'] ?? '#888888',
        text = j['text'] ?? '',
        location = j['location'] ?? '',
        locationHidden = j['locationHidden'] ?? false,
        notes = j['notes'],
        secretDetail = j['secretDetail'],
        source = j['source'] ?? 'staff',
        timestamp = DateTime.parse(j['timestamp']).toLocal(),
        status = j['status'] ?? 'available';
}

/// A step on a baggage file's timeline (reported, located, forwarded, delivered, ...).
class BagEvent {
  final String kind;
  final String? station;
  final String? flight;
  final String? eta;
  final String? note;
  final String? byName;
  final DateTime timestamp;

  BagEvent.fromJson(Map<String, dynamic> j)
      : kind = j['kind'],
        station = j['station'],
        flight = j['flight'],
        eta = j['eta'],
        note = j['note'],
        byName = j['byName'],
        timestamp = DateTime.parse(j['timestamp']).toLocal();
}

/// An unclaimed checked bag registered by the baggage desk.
class OnHandBag {
  final String id;
  final String airport;
  final String? tagNumber;
  final String? flight;
  final String bagType;
  final String? color;
  final String? brand;
  final String? nameOnTag;
  final String? location;
  final String? notes;
  final String imageUrl;
  final String status; // on_hand, matched, delivered
  final String? reportId;
  final DateTime timestamp;

  OnHandBag.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        airport = j['airport'] ?? '',
        tagNumber = j['tagNumber'],
        flight = j['flight'],
        bagType = j['bagType'] ?? 'other',
        color = j['color'],
        brand = j['brand'],
        nameOnTag = j['nameOnTag'],
        location = j['location'],
        notes = j['notes'],
        imageUrl = j['imageUrl'] ?? '',
        status = j['status'] ?? 'on_hand',
        reportId = j['reportId'],
        timestamp = DateTime.parse(j['timestamp']).toLocal();
}

/// A checked bag that didn't arrive (or arrived damaged): the passenger's file at the arrival airport.
class BaggageReport {
  final String id;
  final String ref; // CRA-BG-00042
  final String userId;
  final String airport;
  final String kind; // delayed, damaged
  final String flight;
  final String? flightDate;
  final List<String> tagNumbers;
  final String? bagType;
  final String? color;
  final String? brand;
  final String? nameOnTag;
  final String? marks;
  final String? contents;
  final String deliveryMethod; // deliver, pickup
  final String? deliveryAddress;
  final String? deliveryPhone;
  final String? deliveryWindow;
  final String? imageUrl;
  final String status; // reported, located, forwarded, arrived, out_for_delivery, ready_for_pickup, delivered, declared_lost
  final String? matchedBagId;
  final String? handoverCode; // once out for delivery / ready for pickup
  final DateTime timestamp;
  final List<BagEvent> events;
  // Staff view
  final OnHandBag? bag;
  final List<({double score, OnHandBag bag})> suggestions;
  final String? passengerName;
  final String? passengerEmail;

  bool get closed => status == 'delivered' || status == 'declared_lost';
  bool get handover => status == 'out_for_delivery' || status == 'ready_for_pickup';

  BaggageReport.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        ref = j['ref'] ?? '',
        userId = j['userId'] ?? '',
        airport = j['airport'] ?? '',
        kind = j['kind'] ?? 'delayed',
        flight = j['flight'] ?? '',
        flightDate = j['flightDate'],
        tagNumbers = List<String>.from(j['tagNumbers'] ?? const []),
        bagType = j['bagType'],
        color = j['color'],
        brand = j['brand'],
        nameOnTag = j['nameOnTag'],
        marks = j['marks'],
        contents = j['contents'],
        deliveryMethod = j['deliveryMethod'] ?? 'deliver',
        deliveryAddress = j['deliveryAddress'],
        deliveryPhone = j['deliveryPhone'],
        deliveryWindow = j['deliveryWindow'],
        imageUrl = j['imageUrl'],
        status = j['status'] ?? 'reported',
        matchedBagId = j['matchedBagId'],
        handoverCode = j['handoverCode'],
        timestamp = DateTime.parse(j['timestamp']).toLocal(),
        events = [for (final e in j['events'] ?? const []) BagEvent.fromJson(e)],
        bag = j['bag'] == null ? null : OnHandBag.fromJson(j['bag']),
        suggestions = [
          for (final s in j['suggestions'] ?? const [])
            (score: (s['score'] as num).toDouble(), bag: OnHandBag.fromJson(s['bag'])),
        ],
        passengerName = j['passengerName'],
        passengerEmail = j['passengerEmail'];
}

/// One message in the live chat about a lost report.
class ChatMessage {
  final String id;
  final String reportId;
  final String senderId;
  final String senderRole; // passenger, staff
  final String? senderName; // staff only
  final String text;
  final DateTime timestamp;
  final bool read;

  bool get fromStaff => senderRole == 'staff';

  ChatMessage.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        reportId = j['reportId'],
        senderId = j['senderId'] ?? '',
        senderRole = j['senderRole'] ?? 'passenger',
        senderName = j['senderName'],
        text = j['text'] ?? '',
        timestamp = DateTime.parse(j['timestamp']).toLocal(),
        read = (j['read'] ?? 0) == 1 || j['read'] == true;
}

/// A conversation between a passenger and the airport's staff about one lost report.
class ChatThread {
  final LostReport report;
  final FoundItem? item; // the item the report matched, if any
  final String? passengerName; // staff view
  final String? staffName; // the staff member looking after the passenger, once one answered
  final ChatMessage? last;
  final int unread;
  final List<ChatMessage> messages; // only when the conversation is opened

  ChatThread.fromJson(Map<String, dynamic> j)
      : report = LostReport.fromJson(j['report']),
        item = j['item'] == null ? null : FoundItem.fromJson(j['item']),
        passengerName = j['passengerName'],
        staffName = j['staffName'],
        last = j['last'] == null ? null : ChatMessage.fromJson(j['last']),
        unread = j['unread'] ?? 0,
        messages = [for (final m in j['messages'] ?? const []) ChatMessage.fromJson(m)];
}

class LostReport {
  final String id;
  final String userId;
  final String airport;
  final String description;
  final String category;
  final String? color;
  final String? lastSeenLocation; // the route as text ("A → B → C"), or one place on older reports
  final List<String> route; // ids of the places on the route (see Place)
  final DateTime? travelDate;
  final String? imageUrl;
  final DateTime timestamp;
  final String status;
  final String? matchedItemId;
  final String? ref; // baggage files have their own reference (CRA-BG-00042)
  final String kind; // lost_item, or baggage (a checked-bag file shown in the shared chat)

  LostReport.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        userId = j['userId'],
        airport = j['airport'] ?? 'LHR',
        description = j['description'] ?? '',
        category = j['category'] ?? 'other',
        color = j['color'],
        lastSeenLocation = j['lastSeenLocation'],
        route = List<String>.from(j['route'] ?? const []),
        travelDate = j['travelDate'] == null ? null : DateTime.tryParse(j['travelDate']),
        imageUrl = j['imageUrl'],
        timestamp = DateTime.parse(j['timestamp']).toLocal(),
        status = j['status'] ?? 'searching',
        matchedItemId = j['matchedItemId'],
        ref = j['ref'],
        kind = j['kind'] ?? 'lost_item';
}

class Match {
  final double score;
  final Map<String, dynamic> breakdown;
  final FoundItem item;

  Match.fromJson(Map<String, dynamic> j)
      : score = (j['score'] as num).toDouble(),
        breakdown = Map<String, dynamic>.from(j['breakdown'] ?? {}),
        item = FoundItem.fromJson(j['item']);
}

class AiAnalysis {
  final String category;
  final String label;
  final double confidence;
  final String color;
  final String colorHex;
  final String text;

  AiAnalysis.fromJson(Map<String, dynamic> j)
      : category = j['category'],
        label = j['label'],
        confidence = (j['confidence'] as num).toDouble(),
        color = j['color'],
        colorHex = j['colorHex'],
        text = j['text'] ?? '';
}

/// Signed-in account. Passengers register in the app; staff and administrators are created
/// by an administrator.
class AppUser {
  final String id;
  final String email;
  final String name;
  final String role; // passenger, staff, admin
  final String? airport; // staff home airport
  final bool disabled;

  const AppUser({required this.id, required this.email, required this.name, required this.role, this.airport, this.disabled = false});

  AppUser.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        email = j['email'] ?? '',
        name = j['name'] ?? '',
        role = j['role'] ?? 'passenger',
        airport = j['airport'],
        disabled = (j['disabled'] ?? 0) == 1 || j['disabled'] == true;

  Map<String, dynamic> toJson() =>
      {'id': id, 'email': email, 'name': name, 'role': role, 'airport': airport, 'disabled': disabled ? 1 : 0};

  bool get isStaff => role == 'staff' || role == 'admin';
  bool get isAdmin => role == 'admin';
  String get roleLabel => switch (role) { 'admin' => 'Administrator', 'staff' => 'Staff', _ => 'Passenger' };
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return email.isEmpty ? '?' : email[0].toUpperCase();
    return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
  }
}

/// "K7QM4X" -> "K7Q-M4X": easier to read aloud and type.
String formatPickupCode(String? code) =>
    code == null || code.length != 6 ? '—' : '${code.substring(0, 3)}-${code.substring(3)}';

class Claim {
  final String id;
  final String? token; // only once staff approved the claim
  final String? pickupCode; // 6 characters typed at the desk when the QR can't be scanned
  final String reportId;
  final String itemId;
  final String question;
  final DateTime timestamp;
  final DateTime? reviewedAt;
  final String status; // awaiting_answer, under_review, ready_for_pickup, recovered, rejected, locked

  Claim.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        token = j['token'],
        pickupCode = j['pickupCode'],
        reportId = j['reportId'],
        itemId = j['itemId'],
        question = j['question'] ?? '',
        timestamp = DateTime.parse(j['timestamp']).toLocal(),
        reviewedAt = j['reviewedAt'] == null ? null : DateTime.parse(j['reviewedAt']).toLocal(),
        status = j['status'];
}

class Airport {
  final String code;
  final String name;
  final String short; // "Heathrow", "Craiova"
  final String country;
  final String desk;
  final String team;

  const Airport({
    required this.code,
    required this.name,
    required this.short,
    required this.country,
    required this.desk,
    required this.team,
  });

  Airport.fromJson(Map<String, dynamic> j)
      : code = j['code'],
        name = j['name'],
        short = j['short'] ?? j['name'],
        country = j['country'],
        desk = j['desk'],
        team = j['team'];

  static const fallback = Airport(
    code: 'LHR',
    name: 'London Heathrow',
    short: 'Heathrow',
    country: 'United Kingdom',
    desk: 'Lost Property desk',
    team: 'Lost Property team',
  );
}

/// A stop on a passenger's route: a lost & found area, or a named shop / café / service
/// (which the server ties to the nearest area).
class Place {
  final String id;
  final String kind; // area, poi
  final String type; // area, or the POI type (cafe, atm, ...)
  final String? poiKind;
  final String name;
  final String terminal;
  final String label; // "Terminal 2 · Food court", or "OTP Bank · Terminal 2 · Check-in hall"

  Place.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        kind = j['kind'] ?? 'area',
        type = j['type'] ?? 'area',
        poiKind = j['poiKind'],
        name = j['name'] ?? '',
        terminal = j['terminal'] ?? '',
        label = j['label'] ?? j['name'] ?? '';

  /// Area names come from our zone list (translatable); shop names are proper names.
  String get displayName => kind == 'area' ? name.tr : name;

  /// Second line: the terminal, and for a shop the area it is in.
  String get where => kind == 'area' ? terminal : label.split(' · ').skip(1).map((s) => s.tr).join(' · ');
}

/// A lost & found zone (gate, check-in, security, ...). x/y are metres on the airport map.
class Zone {
  final String id;
  final String name;
  final String terminal;
  final String label; // "Terminal 5 · Gate B42"
  final double x;
  final double y;
  final String? level;
  final bool estimated; // placed by heuristics because OpenStreetMap has no such feature
  final List<FoundItem> items;

  Zone.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        terminal = j['terminal'] ?? '',
        label = j['label'] ?? '${j['terminal']} · ${j['name']}',
        x = (j['x'] as num).toDouble(),
        y = (j['y'] as num).toDouble(),
        level = j['level'],
        estimated = j['source'] == 'estimated',
        items = [for (final i in (j['items'] as List? ?? [])) FoundItem.fromJson(i)];
}

/// Airport plan built from OpenStreetMap (backend/tools/fetch_osm_map.py), in metres.
class AirportMap {
  final String code;
  final double width;
  final double height;
  final List<String> levels;
  final List<MapShape> terminals;
  final List<MapShape> rooms;
  final List<MapPoint> gates;
  final List<MapPoint> pois;
  final String attribution;

  AirportMap.fromJson(Map<String, dynamic> j)
      : code = j['code'],
        width = (j['width'] as num).toDouble(),
        height = (j['height'] as num).toDouble(),
        levels = List<String>.from(j['levels'] ?? []),
        terminals = [
          for (final t in j['terminals']) MapShape(t['poly'], name: t['name'] ?? '', group: t['group'] ?? '')
        ],
        rooms = [
          for (final r in j['rooms'])
            MapShape(r['poly'], name: r['name'] ?? '', kind: r['kind'] ?? 'room', levels: List<String>.from(r['levels']))
        ],
        gates = [for (final g in j['gates']) MapPoint.fromJson(g, name: g['ref'], group: g['terminal'])],
        pois = [
          for (final p in j['pois'])
            MapPoint.fromJson(p, name: p['name'] ?? '', kind: p['kind'], type: p['type'] ?? p['kind'])
        ],
        zones = [for (final z in j['zones'] ?? []) MapPoint.fromJson(z, name: z['name'], group: z['terminal'])],
        attribution = j['attribution'] ?? '© OpenStreetMap contributors';

  final List<MapPoint> zones;

  /// Floors worth offering in the switcher (enough mapped rooms to be useful).
  List<String> get usefulLevels =>
      levels.where((l) => rooms.where((r) => r.levels.contains(l)).length >= 5).toList();

  /// Passenger terminals (ones with lost & found zones; closed buildings like LHR T1 are left out).
  List<String> get terminalGroups {
    final active = {for (final z in zones) z.group};
    return (active.isEmpty ? {for (final t in terminals) t.group} : active).toList()..sort();
  }

  /// Area worth showing first: around the zones, or every building if there are none.
  Rect get focusBounds {
    final pts = zones.isEmpty ? [for (final t in terminals) ...t.points] : [for (final z in zones) z.pos];
    var r = Rect.fromPoints(pts.first, pts.first);
    for (final p in pts) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r.inflate(zones.isEmpty ? 20 : 60);
  }
}

class MapShape {
  final List<Offset> points;
  final String name;
  final String group;
  final String kind;
  final List<String> levels;

  MapShape(List raw, {this.name = '', this.group = '', this.kind = '', this.levels = const []})
      : points = [for (final p in raw) Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())];

  Rect get bounds {
    var r = Rect.fromPoints(points.first, points.first);
    for (final p in points) {
      r = r.expandToInclude(Rect.fromPoints(p, p));
    }
    return r;
  }

  double get area {
    var a = 0.0;
    for (var i = 0; i < points.length; i++) {
      final p = points[i], q = points[(i + 1) % points.length];
      a += p.dx * q.dy - q.dx * p.dy;
    }
    return a.abs() / 2;
  }
}

class MapPoint {
  final Offset pos;
  final String name;
  final String group;
  final String kind; // coarse: food, shop, toilets, money, info, service...
  final String type; // fine: cafe, atm, pharmacy... (one icon each)
  final List<String> levels;
  final Map<String, String> info; // OSM details: hours, cuisine, brand, website, phone, wheelchair...

  MapPoint.fromJson(Map<String, dynamic> j, {required this.name, this.group = '', this.kind = '', this.type = ''})
      : pos = Offset((j['x'] as num).toDouble(), (j['y'] as num).toDouble()),
        levels = List<String>.from(j['levels'] ?? []),
        info = {for (final e in (j['info'] as Map? ?? {}).entries) '${e.key}': '${e.value}'};
}

class AppNotification {
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final DateTime timestamp;

  AppNotification.fromJson(Map<String, dynamic> j)
      : title = j['title'],
        body = j['body'],
        data = Map<String, dynamic>.from(j['data'] ?? {}),
        timestamp = DateTime.parse(j['timestamp']).toLocal();
}
