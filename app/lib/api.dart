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

  /// Session token of the signed-in account, sent as `Authorization: Bearer ...`.
  String? token;

  /// Called when the server rejects the session (expired, signed out elsewhere, account disabled).
  void Function()? onUnauthorized;

  Map<String, String> get _auth => token == null ? {} : {'Authorization': 'Bearer $token'};

  String imageUrl(String path) => path.startsWith('http') ? path : '$baseUrl$path';

  Uri _uri(String path, [Map<String, String?>? query]) {
    final q = {for (final e in (query ?? {}).entries) if (e.value != null) e.key: e.value!};
    return Uri.parse('$baseUrl$path').replace(queryParameters: q.isEmpty ? null : q);
  }

  dynamic _decode(http.Response r) {
    final body = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode == 401 && token != null) onUnauthorized?.call();
    if (r.statusCode >= 400) {
      final detail = body is Map ? body['detail'] : null;
      throw ApiException(detail is String ? detail : 'Request failed (${r.statusCode})');
    }
    return body;
  }

  Future<dynamic> _get(String path, [Map<String, String?>? query, Map<String, String>? headers]) async =>
      _decode(await client.get(_uri(path, query), headers: {..._auth, ...?headers}));

  Future<dynamic> _postJson(String path, Map<String, dynamic> body, {Map<String, String>? headers}) async =>
      _decode(await client.post(
        _uri(path),
        headers: {'Content-Type': 'application/json', ..._auth, ...?headers},
        body: jsonEncode(body),
      ));

  Future<dynamic> _patchJson(String path, Map<String, dynamic> body) async => _decode(await client.patch(
        _uri(path),
        headers: {'Content-Type': 'application/json', ..._auth},
        body: jsonEncode(body),
      ));

  Future<dynamic> _delete(String path) async => _decode(await client.delete(_uri(path), headers: _auth));

  Future<dynamic> _postMultipart(String path, Map<String, String?> fields, {XFile? image}) async {
    final req = http.MultipartRequest('POST', _uri(path))..headers.addAll(_auth);
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

  // ---------------------------------------------------------------- Accounts

  Future<({String token, AppUser user})> _session(dynamic r) async =>
      (token: r['token'] as String, user: AppUser.fromJson(r['user']));

  /// [role] is the portal signed in from (passenger / staff / admin); the server refuses
  /// e.g. a passenger account on the staff sign-in.
  Future<({String token, AppUser user})> login(String email, String password, {String? role}) async =>
      _session(await _postJson('/auth/login', {'email': email, 'password': password, 'role': role}));

  /// Passenger self sign-up.
  Future<({String token, AppUser user})> register(String name, String email, String password) async =>
      _session(await _postJson('/auth/register', {'name': name, 'email': email, 'password': password}));

  Future<AppUser> me() async => AppUser.fromJson(await _get('/auth/me'));

  Future<void> logout() async => _postJson('/auth/logout', {});

  Future<void> changePassword(String current, String next) async =>
      _postJson('/auth/password', {'currentPassword': current, 'newPassword': next});

  // Administrator
  Future<List<AppUser>> users({String? role}) async =>
      [for (final u in await _get('/admin/users', {'role': role})) AppUser.fromJson(u)];

  Future<AppUser> createUser({required String name, required String email, required String password,
          required String role, String? airport}) async =>
      AppUser.fromJson(await _postJson('/admin/users',
          {'name': name, 'email': email, 'password': password, 'role': role, 'airport': airport}));

  Future<AppUser> updateUser(String id, {String? name, String? role, String? airport, bool? disabled, String? password}) async =>
      AppUser.fromJson(await _patchJson('/admin/users/$id', {
        'name': ?name,
        'role': ?role,
        'airport': ?airport,
        'disabled': ?disabled,
        'password': ?password,
      }));

  Future<void> deleteUser(String id) async => _delete('/admin/users/$id');

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

  /// Passengers get blurred photos; [staff] (inventory) gets the real ones.
  Future<List<FoundItem>> foundItems({
    required String airport,
    String? category,
    String? color,
    String? status = 'available',
    bool staff = false,
  }) async {
    final r = await _get('/found-items', {
      'airport': airport,
      'category': category,
      'color': color,
      'status': status,
      'staff': staff ? 'true' : null,
    });
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
      WebSocketChannel.connect(Uri.parse('${baseUrl.replaceFirst('http', 'ws')}/ws/$userId?token=${Uri.encodeComponent(token ?? '')}'));

  // ---------------------------------------------------------------- Claim & Pick-up

  /// Returns (claimId, verification question, wrong answers still allowed).
  /// Throws an [ApiException] when the passenger is locked out of this item.
  Future<({String id, String question, int attemptsLeft})> createClaim(String reportId, String itemId) async {
    final r = await _postJson('/claims', {'reportId': reportId, 'itemId': itemId});
    return (id: r['id'] as String, question: r['question'] as String, attemptsLeft: (r['attemptsLeft'] as num?)?.toInt() ?? 3);
  }

  /// Sends the answer. status: under_review (right, goes to the airport team), awaiting_answer
  /// (wrong, try again) or locked (too many wrong answers).
  Future<({String status, int? attemptsLeft, String? message})> answerClaim(String claimId, String answer) async {
    final r = await _postJson('/claims/$claimId/answer', {'answer': answer});
    return (status: r['status'] as String, attemptsLeft: (r['attemptsLeft'] as num?)?.toInt(), message: r['message'] as String?);
  }

  /// The token in the URL lets Image.network load it (the pass belongs to the signed-in passenger).
  String claimQrUrl(String claimId) => '$baseUrl/claims/$claimId/qr?token=${Uri.encodeComponent(token ?? '')}';

  Future<List<Claim>> claims(String userId) async =>
      [for (final c in await _get('/claims', {'userId': userId})) Claim.fromJson(c)];

  /// Staff: claims waiting for review, each with claim (incl. answer), item (incl. secretDetail) and report.
  Future<List<Map<String, dynamic>>> staffClaims({String status = 'under_review'}) async =>
      [for (final c in await _get('/staff/claims', {'status': status})) Map<String, dynamic>.from(c)];

  /// Staff: verification attempts per passenger + item (answers, wrong count, lock state).
  Future<List<Map<String, dynamic>>> claimAttempts({String? airport, bool lockedOnly = false}) async => [
        for (final g in await _get('/staff/claim-attempts', {'airport': airport, 'lockedOnly': lockedOnly ? 'true' : null}))
          Map<String, dynamic>.from(g)
      ];

  /// Staff: lift a lockout after checking the passenger in person.
  Future<void> unlockClaims(String userId, String itemId) async =>
      _postJson('/staff/claim-attempts/unlock', {'userId': userId, 'itemId': itemId});

  Future<void> reviewClaim(String claimId, bool approved) async =>
      _postJson('/staff/claims/$claimId/review', {'approved': approved});

  /// Finds the pick-up QR in a photo (desk webcam frame or a screenshot); returns its content.
  Future<String> scanQrImage(XFile image) async =>
      (await _postMultipart('/claims/scan-image', {}, image: image))['code'];

  Future<Map<String, dynamic>> scanClaim(String token) async =>
      Map<String, dynamic>.from(await _get('/claims/scan/${Uri.encodeComponent(token)}'));

  // ---------------------------------------------------------------- Developer tools

  /// Throws an [ApiException] when the developer key is wrong.
  Future<void> devCheck(String key) async => _get('/dev/check', null, {'X-Dev-Key': key});

  /// Deletes every passenger request (and, with [includeItems], the found-items inventory).
  /// Returns how many rows were removed per table.
  Future<Map<String, dynamic>> devReset(String key, {bool includeItems = false}) async => Map<String, dynamic>.from(
      (await _postJson('/dev/reset', {'includeItems': includeItems}, headers: {'X-Dev-Key': key}))['deleted']);

  Future<String> decideClaim(String token, bool approved) async =>
      (await _postJson('/claims/scan/${Uri.encodeComponent(token)}/decision', {'approved': approved}))['status'];
}
