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

  late String userId;
  Airport airport = Airport.fallback;
  List<Airport> airports = const [Airport.fallback];
  List<Zone> zones = [];
  final Map<String, AirportMap> _maps = {};
  List<LostReport> reports = [];
  List<Claim> claims = [];
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
    claims = [];
    matchesByReport.clear();
    itemCache.clear();
    revealedPhotos.clear();
    zones = []; // pin counts on the map
    notifyListeners();
    await refresh();
  }

  Future<void> loadPrefs(SharedPreferences prefs, String userId) async {
    this.userId = userId;
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
      final r = await Future.wait([api.lostReports(userId), api.claims(userId)]);
      reports = r[0] as List<LostReport>;
      claims = r[1] as List<Claim>;
      matchesByReport.clear();
      await Future.wait([
        for (final rep in reports.where((r) => r.status != 'recovered'))
          api.reportMatches(rep.id).then((m) => matchesByReport[rep.id] = m),
        for (final c in claims.where((c) => !itemCache.containsKey(c.itemId))) _cacheItem(c.itemId),
      ]);
      for (final list in matchesByReport.values) {
        for (final m in list) {
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
      if (c.itemId == itemId && c.status != 'rejected') return c;
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

  String reportRef(LostReport r) => '${r.airport}-${r.id.substring(0, 5).toUpperCase()}';
  String itemRef(FoundItem i) => '${i.airport}-F-${i.id.length >= 4 ? i.id.substring(0, 4).toUpperCase() : i.id}';
}
