import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';

/// Where a passenger's report stands, derived from the report and its latest claim.
enum ReportStage { searching, actionNeeded, underReview, readyForPickup, recovered }

/// Cached passenger data shared by Home, Find items and My reports.
class AppData extends ChangeNotifier {
  AppData._();
  static final instance = AppData._();

  /// Scores at or above this count as "Potential match" (same as the backend auto-match threshold).
  static const matchThreshold = 0.55;

  /// Signed-in account (null: show the sign-in page). Passengers' reports and claims belong to it.
  final session = ValueNotifier<AppUser?>(null);
  AppUser? get user => session.value;
  String userId = '';
  Airport airport = Airport.fallback;
  List<Airport> airports = const [Airport.fallback];
  List<Zone> zones = [];
  final Map<String, AirportMap> _maps = {};
  List<LostReport> reports = [];
  List<Claim> claims = [];

  /// Live events from the backend WebSocket (chat messages, ...), re-published for open screens.
  final live = StreamController<Map<String, dynamic>>.broadcast();

  /// Passenger: checked bags that didn't arrive.
  List<BaggageReport> baggage = [];

  /// Passenger: conversations with the airport team, one per report.
  List<ChatThread> chats = [];

  /// Report whose chat is on screen (no pop-up alert for its messages).
  String? openChat;

  ChatThread? chatFor(String reportId) => chats.where((t) => t.report.id == reportId).firstOrNull;

  Future<void> refreshBaggage() async {
    try {
      baggage = await Api.instance.baggageReports();
      notifyListeners();
    } catch (_) {
      // Baggage files are extra: the rest of the app works without them.
    }
  }

  Future<void> refreshChats() async {
    try {
      chats = await Api.instance.chats();
      notifyListeners();
    } catch (_) {
      // Chats are extra: the rest of the app works without them.
    }
  }
  final Map<String, List<Match>> matchesByReport = {};
  final Map<String, FoundItem> itemCache = {};
  final themeMode = ValueNotifier(ThemeMode.system);
  bool loaded = false;
  Object? error;

  /// Set once the developer tools are unlocked with the server's developer key.
  String? devKey;

  Future<void> setDevKey(String? key) async {
    devKey = key;
    final prefs = await SharedPreferences.getInstance();
    key == null ? await prefs.remove('devKey') : await prefs.setString('devKey', key);
    notifyListeners();
  }

  /// After a developer reset: forget everything shown on this device, then reload (now empty).
  Future<void> clearPassengerData() async {
    reports = [];
    chats = [];
    baggage = [];
    claims = [];
    matchesByReport.clear();
    itemCache.clear();
    revealedPhotos.clear();
    zones = []; // pin counts on the map
    notifyListeners();
    await refresh();
  }

  /// Remembers the session on this device and opens the matching part of the app.
  Future<void> signIn(String token, AppUser user) async {
    Api.instance.token = token;
    userId = user.id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
    await prefs.setString('user', jsonEncode(user.toJson()));
    _forgetPassengerData();
    session.value = user;
  }

  /// Back to the sign-in page. [server] false: the server already ended the session.
  Future<void> signOut({bool server = true}) async {
    if (server && Api.instance.token != null) {
      try {
        await Api.instance.logout();
      } catch (_) {
        // Offline: the token is forgotten here anyway.
      }
    }
    Api.instance.token = null;
    userId = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('user');
    _forgetPassengerData();
    session.value = null;
  }

  void _forgetPassengerData() {
    reports = [];
    chats = [];
    baggage = [];
    claims = [];
    matchesByReport.clear();
    itemCache.clear();
    revealedPhotos.clear();
    loaded = false;
  }

  /// Checks a remembered session with the server (name/role may have changed). Offline keeps it.
  Future<void> verifySession() async {
    if (Api.instance.token == null) return;
    try {
      final fresh = await Api.instance.me();
      await (await SharedPreferences.getInstance()).setString('user', jsonEncode(fresh.toJson()));
      session.value = fresh;
    } on ApiException {
      await signOut(server: false); // expired, revoked or disabled
    } catch (_) {
      // Server unreachable: keep the cached account; requests will retry.
    }
  }

  Future<void> loadPrefs(SharedPreferences prefs) async {
    final token = prefs.getString('token');
    final user = prefs.getString('user');
    if (token != null && user != null) {
      Api.instance.token = token;
      session.value = AppUser.fromJson(jsonDecode(user));
      userId = session.value!.id;
    }
    Api.instance.onUnauthorized = () {
      if (session.value != null) signOut(server: false);
    };
    devKey = prefs.getString('devKey');
    themeMode.value = ThemeMode.values.byName(prefs.getString('themeMode') ?? 'system');
    final code = prefs.getString('airport');
    // Placeholder until /meta returns the full airport details.
    if (code != null) airport = Airport(code: code, name: code, short: code, country: '', desk: '', team: '');
  }

  /// Switch the airport used for browsing, reporting, the map and staff intake.
  Future<void> setAirport(String code) async {
    if (code == airport.code && zones.isNotEmpty) return;
    airport = airports.firstWhere((a) => a.code == code, orElse: () => airport);
    zones = [];
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString('airport', code);
    await refresh();
  }

  Future<AirportMap> mapFor(String code) async => _maps[code] ??= await Api.instance.airportMap(code);

  final Map<String, List<Place>> _places = {};

  /// Route places of an airport (fetched once per airport).
  Future<List<Place>> placesFor(String code) async => _places[code] ??= await Api.instance.places(code);

  /// Ids of every place on the routes of the passenger's open reports at [code]: what Find items is limited to.
  Set<String> routeAt(String code) =>
      {for (final r in reports) if (r.airport == code && r.status != 'recovered') ...r.route};

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await (await SharedPreferences.getInstance()).setString('themeMode', mode.name);
  }

  Future<void> refresh() async {
    final api = Api.instance;
    try {
      if (zones.isEmpty) {
        final m = await api.meta(airport.code);
        airport = m.airport;
        zones = m.zones;
        airports = m.airports;
      }
      if (user == null || user!.isStaff) {
        // Staff screens only need the airport info; reports and claims are passenger data.
        error = null;
        loaded = true;
        notifyListeners();
        return;
      }
      unawaited(refreshChats());
      unawaited(refreshBaggage());
      final r = await Future.wait([api.lostReports(userId), api.claims(userId)]);
      reports = r[0] as List<LostReport>;
      claims = r[1] as List<Claim>;
      matchesByReport.clear();
      await Future.wait([
        for (final rep in reports.where((r) => r.status != 'recovered'))
          api.reportMatches(rep.id).then((m) => matchesByReport[rep.id] = m),
        // Approved claims: fetch again, the server now includes where the item was found.
        for (final c in claims.where((c) =>
            !itemCache.containsKey(c.itemId) ||
            (itemCache[c.itemId]!.locationHidden && (c.status == 'ready_for_pickup' || c.status == 'recovered'))))
          _cacheItem(c.itemId),
      ]);
      for (final list in matchesByReport.values) {
        for (final m in list) {
          if (itemCache[m.item.id]?.locationHidden == false) continue; // keep the copy with the location
          itemCache[m.item.id] = m.item;
        }
      }
      error = null;
    } catch (e) {
      error = e;
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _cacheItem(String id) async {
    try {
      itemCache[id] = await Api.instance.foundItem(id);
    } catch (_) {
      // Item removed from the inventory; the claim still renders without a photo.
    }
  }

  // ---------------------------------------------------------------- derived data

  /// Clear photos of items the passenger found with a reverse image search (this session only).
  /// Everywhere else found items show the blurred preview the server sends.
  final revealedPhotos = <String, String>{};

  void revealPhotos(Iterable<FoundItem> items) {
    for (final i in items) {
      if (!i.photoHidden && i.imageUrl.isNotEmpty) revealedPhotos[i.id] = i.imageUrl;
    }
  }

  String photoOf(FoundItem i) => revealedPhotos[i.id] ?? i.imageUrl;
  bool photoHidden(FoundItem i) => i.photoHidden && !revealedPhotos.containsKey(i.id);

  List<LostReport> get activeReports => reports.where((r) => r.status != 'recovered').toList();
  List<LostReport> get closedReports => reports.where((r) => r.status == 'recovered').toList();
  LostReport? get latestReport => reports.isEmpty ? null : reports.first;

  /// Item ids that score as a potential match for any of my active reports.
  Set<String> get potentialItemIds => {
        for (final list in matchesByReport.values)
          for (final m in list)
            if (m.score >= matchThreshold) m.item.id,
      };

  List<Match> potentialMatches(String reportId) =>
      (matchesByReport[reportId] ?? []).where((m) => m.score >= matchThreshold).toList();

  /// Most recent active claim of a report (rejected and locked claims no longer count).
  Claim? claimFor(String reportId) {
    for (final c in claims) {
      if (c.reportId == reportId && c.status != 'rejected' && c.status != 'locked') return c;
    }
    return null;
  }

  /// Latest claim on an item, including a lockout after too many wrong answers.
  Claim? claimForItem(String itemId) {
    for (final c in claims) {
      // Rejected claims count too: a passenger can claim an item only once.
      if (c.itemId == itemId) return c;
    }
    return null;
  }

  ReportStage stageOf(LostReport r) {
    if (r.status == 'recovered') return ReportStage.recovered;
    final claim = claimFor(r.id);
    switch (claim?.status) {
      case 'under_review':
        return ReportStage.underReview;
      case 'ready_for_pickup':
        return ReportStage.readyForPickup;
      case 'recovered':
        return ReportStage.recovered;
      case 'awaiting_answer':
        return ReportStage.actionNeeded;
    }
    return potentialMatches(r.id).isNotEmpty || r.status == 'matched' ? ReportStage.actionNeeded : ReportStage.searching;
  }

  /// Report that best fits an item: one that already lists it as a match, else same category.
  LostReport? reportForItem(FoundItem item) {
    for (final r in activeReports) {
      if ((matchesByReport[r.id] ?? []).any((m) => m.item.id == item.id)) return r;
    }
    for (final r in activeReports) {
      if (r.airport == item.airport && r.category == item.category && claimFor(r.id) == null) return r;
    }
    return null;
  }

  Zone? zoneByName(String name) {
    for (final z in zones) {
      if (z.label == name || z.id == name) return z;
    }
    return null;
  }

  Airport airportByCode(String code) => airports.firstWhere((a) => a.code == code, orElse: () => airport);

  String zoneLabel(String? location) {
    if (location == null || location.isEmpty) return '';
    return zoneByName(location)?.label ?? location;
  }

  String reportRef(LostReport r) => r.ref ?? '${r.airport}-${r.id.substring(0, 5).toUpperCase()}';
  String itemRef(FoundItem i) => '${i.airport}-F-${i.id.length >= 4 ? i.id.substring(0, 4).toUpperCase() : i.id}';
}
