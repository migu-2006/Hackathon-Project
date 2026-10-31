import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

/// Thin client over the FastAPI backend (see backend/README.md for the endpoints).
class Api {
  Api._();
  static final instance = Api._();

  /// Baked in with `--dart-define=API_URL=http://192.168.x.x:8000` for real phones;
  /// otherwise the Android emulator reaches the host machine via 10.0.2.2.
  static const _builtInUrl = String.fromEnvironment('API_URL');
  String baseUrl = _builtInUrl.isNotEmpty
      ? _builtInUrl
      : (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
          ? 'http://10.0.2.2:8000'
          : 'http://localhost:8000';

  /// Replaceable for tests (package:http/testing.dart MockClient).
  http.Client client = http.Client();

  String imageUrl(String path) => path.startsWith('http') ? path : '$baseUrl$path';

  Uri _uri(String path, [Map<String, String?>? query]) {
    final q = {for (final e in (query ?? {}).entries) if (e.value != null) e.key: e.value!};
    return Uri.parse('$baseUrl$path').replace(queryParameters: q.isEmpty ? null : q);
  }

  dynamic _decode(http.Response r) {
    final body = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 400) {
      final detail = body is Map ? body['detail'] : null;
      throw ApiException(detail is String ? detail : 'Request failed (${r.statusCode})');
    }
    return body;
  }

  Future<dynamic> _get(String path, [Map<String, String?>? query]) async =>
      _decode(await client.get(_uri(path, query)));

  Future<dynamic> _postJson(String path, Map<String, dynamic> body) async => _decode(await client.post(
        _uri(path),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ));

  Future<dynamic> _postMultipart(String path, Map<String, String?> fields, {XFile? image}) async {
    final req = http.MultipartRequest('POST', _uri(path));
    fields.forEach((k, v) {
      if (v != null && v.isNotEmpty) req.fields[k] = v;
    });
    if (image != null) {
      // Bytes (not paths) so the same code works on web.
      req.files.add(http.MultipartFile.fromBytes('image', await image.readAsBytes(),
          filename: image.name.isEmpty ? 'photo.jpg' : image.name));
    }
    return _decode(await http.Response.fromStream(await client.send(req)));
  }

  // ---------------------------------------------------------------- Smart Intake (staff)

  Future<AiAnalysis> analyze(XFile image) async =>
      AiAnalysis.fromJson(await _postMultipart('/intake/analyze', {}, image: image));

  Future<({FoundItem item, int notified})> createFoundItem({
    required XFile image,
    required String airport,
    required String location,
    String? category,
    String? color,
    String? notes,
    String? secretDetail,
  }) async {
    final r = await _postMultipart('/found-items', {
      'airport': airport,
      'location': location,
      'category': category,
      'color': color,
      'notes': notes,
      'secretDetail': secretDetail,
    }, image: image);
    return (item: FoundItem.fromJson(r['item']), notified: (r['notifiedReports'] as List).length);
  }

  Future<FoundItem> foundItem(String id) async => FoundItem.fromJson(await _get('/found-items/$id'));

  Future<({Airport airport, List<Zone> zones, List<Airport> airports})> meta(String airport) async {
    final r = await _get('/meta', {'airport': airport});
    return (
      airport: Airport.fromJson(r['airport']),
      zones: [for (final z in r['zones']) Zone.fromJson(z)],
      airports: [for (final a in r['airports']) Airport.fromJson(a)],
    );
  }

  Future<AirportMap> airportMap(String airport) async => AirportMap.fromJson(await _get('/map/$airport'));

  /// Zones of an airport with the available items pinned on each.
  Future<List<Zone>> zones(String airport) async =>
      [for (final z in await _get('/airports/$airport/zones')) Zone.fromJson(z)];

  Future<List<FoundItem>> foundItems({required String airport, String? category, String? color, String? status = 'available'}) async {
    final r = await _get('/found-items', {'airport': airport, 'category': category, 'color': color, 'status': status});
    return [for (final i in r) FoundItem.fromJson(i)];
  }

  // ---------------------------------------------------------------- Passenger

  Future<({AiAnalysis query, List<Match> matches})> visualSearch(XFile image, {required String airport}) async {
    final r = await _postMultipart('/search/visual', {'airport': airport}, image: image);
    return (
      query: AiAnalysis.fromJson(r['query']),
      matches: [for (final m in r['matches']) Match.fromJson(m)],
    );
  }

  Future<({LostReport report, List<Match> matches})> createLostReport({
    required String userId,
    required String airport,
    required String description,
    String? category,
    String? color,
    String? lastSeenLocation,
    DateTime? travelDate,
    XFile? image,
  }) async {
    final r = await _postMultipart('/lost-reports', {
      'userId': userId,
      'airport': airport,
      'description': description,
      'category': category,
      'color': color,
      'lastSeenLocation': lastSeenLocation,
      'travelDate': travelDate?.toIso8601String().substring(0, 10),
    }, image: image);
    return (
      report: LostReport.fromJson(r['report']),
      matches: [for (final m in r['matches']) Match.fromJson(m)],
    );
  }

  Future<List<LostReport>> lostReports(String userId) async =>
      [for (final r in await _get('/lost-reports', {'userId': userId})) LostReport.fromJson(r)];

  Future<List<Match>> reportMatches(String reportId) async =>
      [for (final m in await _get('/lost-reports/$reportId/matches')) Match.fromJson(m)];


  Future<List<AppNotification>> notifications(String userId) async =>
      [for (final n in await _get('/users/$userId/notifications')) AppNotification.fromJson(n)];

  WebSocketChannel notificationStream(String userId) =>
      WebSocketChannel.connect(Uri.parse('${baseUrl.replaceFirst('http', 'ws')}/ws/$userId'));

  // ---------------------------------------------------------------- Claim & Pick-up

  /// Returns (claimId, verification question).
  Future<({String id, String question})> createClaim(String reportId, String itemId) async {
    final r = await _postJson('/claims', {'reportId': reportId, 'itemId': itemId});
    return (id: r['id'] as String, question: r['question'] as String);
  }

  /// Sends the answer; the claim then waits for the airport team's ownership review.
  Future<void> answerClaim(String claimId, String answer) async =>
      _postJson('/claims/$claimId/answer', {'answer': answer});

  String claimQrUrl(String claimId) => '$baseUrl/claims/$claimId/qr';

  Future<List<Claim>> claims(String userId) async =>
      [for (final c in await _get('/claims', {'userId': userId})) Claim.fromJson(c)];

  /// Staff: claims waiting for review, each with claim (incl. answer), item (incl. secretDetail) and report.
  Future<List<Map<String, dynamic>>> staffClaims({String status = 'under_review'}) async =>
      [for (final c in await _get('/staff/claims', {'status': status})) Map<String, dynamic>.from(c)];

  Future<void> reviewClaim(String claimId, bool approved) async =>
      _postJson('/staff/claims/$claimId/review', {'approved': approved});

  Future<Map<String, dynamic>> scanClaim(String token) async =>
      Map<String, dynamic>.from(await _get('/claims/scan/${Uri.encodeComponent(token)}'));

  Future<String> decideClaim(String token, bool approved) async =>
      (await _postJson('/claims/scan/${Uri.encodeComponent(token)}/decision', {'approved': approved}))['status'];
}
