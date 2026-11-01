// Screenshots of the main passenger, staff and sign-up screens for the presentation, with a fake backend:
//   flutter test test/deck_screenshots_test.dart --update-goldens --dart-define=SCREENSHOTS=true --dart-define=DECK_IMAGES=<dir>
// DECK_IMAGES holds phone.jpg, phone_blur.jpg and qr.png (photos served to Image.network).
// Output: build/screenshots/deck_*.png. Skipped in normal test runs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lost_found_app/api.dart';
import 'package:lost_found_app/app_state.dart';
import 'package:lost_found_app/models.dart';
import 'package:lost_found_app/screens/chat_screen.dart';
import 'package:lost_found_app/screens/passenger/item_details_screen.dart';
import 'package:lost_found_app/screens/passenger/my_reports_screen.dart';
import 'package:lost_found_app/screens/passenger/report_screen.dart';
import 'package:lost_found_app/screens/passenger/shell.dart';
import 'package:lost_found_app/screens/staff/chats_screen.dart';
import 'package:lost_found_app/screens/staff/pickup_screen.dart';
import 'package:lost_found_app/screens/staff/staff_home.dart';
import 'package:lost_found_app/screens/verify_email_screen.dart';
import 'package:lost_found_app/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = bool.fromEnvironment('SCREENSHOTS');
const _images = String.fromEnvironment('DECK_IMAGES');

const _pax = AppUser(id: 'pax-ana', email: 'ana.pop@gmail.com', name: 'Ana Pop', role: 'passenger');
const _staff = AppUser(id: 's1', email: 'maria.ionescu@skyfindr.app', name: 'Maria Ionescu', role: 'staff', airport: 'CRA');

const _cra = {'code': 'CRA', 'name': 'Craiova International Airport', 'short': 'Craiova', 'country': 'Romania', 'desk': 'Lost & Found desk', 'team': 'Lost & Found team'};

List<Map<String, dynamic>> _zones() {
  final map = jsonDecode(File('../backend/app/maps/CRA.json').readAsStringSync()) as Map<String, dynamic>;
  return [for (final z in map['zones'] as List) {...z as Map<String, dynamic>, 'label': '${z['terminal']} · ${z['name']}', 'items': []}];
}

Map<String, dynamic> _item(String id, String category, String color, String hex, String zone, String where, String time,
        {bool phone = false, bool hidden = true, String status = 'available', String text = '', String? secret}) =>
    {
      'id': id, 'airport': 'CRA', 'zoneId': 'cra-terminal-2-$zone', 'category': category, 'label': category, 'color': color,
      'colorHex': hex, 'location': 'Terminal 2 · $where', 'timestamp': time, 'status': status, 'text': text,
      'imageUrl': phone ? (hidden ? '/images/phone_blur.jpg' : '/images/phone.jpg') : '', 'photoHidden': phone && hidden,
      'secretDetail': ?secret,
    };

/// Passengers only see where their own approved item (the phone) was found.
List<Map<String, dynamic>> _items({bool staff = false}) => [
      for (final i in _allItems(staff: staff))
        staff || i['id'] == '9c1e7a2b44d0' ? i : {...i, 'location': '', 'zoneId': null, 'locationHidden': true},
    ];

List<Map<String, dynamic>> _allItems({bool staff = false}) => [
      _item('9c1e7a2b44d0', 'phone', 'black', '#1f1f22', 'gates', 'Departure gates', '2026-10-31T07:40:00Z',
          phone: true, hidden: !staff, text: 'gold case', secret: staff ? 'Gold bumper case, cracked corner' : null),
      _item('a1b2c3d4e5f6', 'backpack', 'black', '#222222', 'security', 'Security', '2026-10-31T06:55:00Z',
          secret: staff ? 'Cat sticker, initials M.A.' : null),
      _item('f00dcafe0001', 'wallet', 'brown', '#7b4a2a', 'food', 'Food court', '2026-10-30T18:20:00Z',
          secret: staff ? 'Student card inside' : null),
      _item('b0b0c0c0d0d0', 'headphones', 'white', '#eeeeee', 'baggage', 'Baggage claim', '2026-10-30T15:05:00Z'),
      {
        ..._item('c4c4e8e8f1f1', 'umbrella', 'blue', '#2d5fa8', 'arrivals', 'Arrivals hall', '2026-10-30T11:30:00Z'),
        'source': 'passenger', 'notes': 'Blue umbrella left on a bench by the exit',
      },
      _item('d7d7a1a1b2b2', 'suitcase', 'red', '#b3202a', 'check-in', 'Check-in hall', '2026-10-29T09:15:00Z',
          status: staff ? 'claimed' : 'available'),
    ];

List<Map<String, dynamic>> _places() => [
      for (final z in _zones())
        {'id': z['id'], 'kind': 'area', 'type': 'area', 'name': z['name'], 'terminal': z['terminal'], 'label': z['label']},
      {'id': 'poi-592-189', 'kind': 'poi', 'type': 'atm', 'poiKind': 'money', 'name': 'OTP Bank', 'terminal': 'Terminal 2', 'label': 'OTP Bank · Terminal 2 · Check-in hall'},
      {'id': 'poi-649-181', 'kind': 'poi', 'type': 'atm', 'poiKind': 'money', 'name': 'BRD Bank', 'terminal': 'Terminal 2', 'label': 'BRD Bank · Terminal 2 · Food court'},
    ];

final _reports = [
  {
    'id': 'r7k2m9q4x1z0', 'userId': 'pax-ana', 'airport': 'CRA', 'description': 'Black phone in a gold case, left at gate 3',
    'category': 'phone', 'color': 'black', 'lastSeenLocation': 'Terminal 2 · Security → Terminal 2 · Departure gates', 'travelDate': '2026-10-31',
    'route': ['cra-terminal-2-security', 'cra-terminal-2-gates'],
    'timestamp': '2026-10-31T08:05:00Z', 'status': 'matched', 'matchedItemId': '9c1e7a2b44d0',
  },
  {
    'id': 'h3p8w2d6t5n1', 'userId': 'pax-ana', 'airport': 'CRA', 'description': 'White wireless headphones',
    'category': 'headphones', 'color': 'white', 'lastSeenLocation': 'Terminal 2 · Baggage claim → Terminal 2 · Arrivals hall', 'travelDate': '2026-10-30',
    'route': ['cra-terminal-2-baggage', 'cra-terminal-2-arrivals'],
    'timestamp': '2026-10-30T16:00:00Z', 'status': 'searching',
  },
];

Map<String, dynamic> _msg(String id, String role, String text, String time, {bool read = true}) => {
      'id': id, 'reportId': 'r7k2m9q4x1z0', 'airport': 'CRA', 'senderId': role == 'staff' ? 's1' : 'pax-ana',
      'senderRole': role, 'senderName': role == 'staff' ? 'Maria Ionescu' : null, 'text': text,
      'timestamp': '2026-10-31T$time:00Z', 'read': read ? 1 : 0,
    };

final _messages = [
  _msg('m1', 'staff', 'Hi Ana, I am Maria from the Lost & Found desk. We have a black phone from gate 3 that could be yours.', '08:12'),
  _msg('m2', 'passenger', 'That sounds like mine! It has a gold case.', '08:14'),
  _msg('m3', 'staff', 'Great. Please send the private claim from the app so I can confirm it.', '08:15'),
  _msg('m4', 'passenger', 'Done, I just sent it. When can I pick it up?', '08:21'),
  _msg('m5', 'staff', 'Approved! The desk in the arrivals hall is open until 22:00. Bring your ID and the pickup pass.', '08:33'),
];

Map<String, dynamic> _thread({bool staff = false, bool withMessages = false}) => {
      'report': _reports[0], 'item': _items(staff: staff)[0], 'passengerName': staff ? 'Ana Pop' : null,
      'staffName': 'Maria Ionescu', 'last': _messages.last, 'unread': staff ? 0 : 1,
      if (withMessages) 'messages': _messages,
    };

final _claim = {
  'id': 'c7f3a91c2d4e5', 'token': '7f3a91c2d4e5', 'pickupCode': 'K7M2QX', 'reportId': 'r7k2m9q4x1z0', 'itemId': '9c1e7a2b44d0',
  'question': 'Describe something distinctive about the item (case, stickers, scratches, engravings).',
  'answer': 'gold case with a cracked corner', 'timestamp': '2026-10-31T08:20:00Z', 'reviewedAt': '2026-10-31T08:32:00Z',
  'status': 'ready_for_pickup', 'userId': 'pax-ana',
};

MockClient _backend() => MockClient((req) async {
      final path = req.url.path;
      final staff = req.url.queryParameters['staff'] == 'true' || AppData.instance.user?.isStaff == true;
      Object? body = [];
      if (path == '/meta') {
        body = {'airport': _cra, 'zones': _zones(), 'airports': [_cra]};
      } else if (path == '/airports/CRA/places') {
        body = _places();
      } else if (path == '/chats') {
        body = staff
            ? [
                {..._thread(staff: true), 'last': _msg('x1', 'passenger', 'Is the desk open on Sunday morning?', '09:40', read: false), 'unread': 2},
                {
                  ..._thread(staff: true), 'report': {..._reports[1], 'id': 'w4n8c2x7k5p3', 'category': 'wallet', 'color': 'brown'},
                  'item': _items(staff: true)[2], 'passengerName': 'Radu Marin', 'last': null, 'unread': 0,
                },
                _thread(staff: true),
              ]
            : [_thread()];
      } else if (path.startsWith('/chats/')) {
        body = _thread(staff: staff, withMessages: true);
      } else if (path == '/handed-in') {
        body = [
          {..._allItems()[4], 'imageUrl': '', 'photoHidden': false, 'locationHidden': false},
        ];
      } else if (path == '/found-items') {
        final route = {'cra-terminal-2-security', 'cra-terminal-2-gates', 'cra-terminal-2-baggage', 'cra-terminal-2-arrivals'};
        body = req.url.queryParameters['onMyRoute'] == 'true'
            ? [for (final i in _allItems()) if (route.contains(i['zoneId'])) _items().firstWhere((x) => x['id'] == i['id'])]
            : _items(staff: staff);
      } else if (path.startsWith('/found-items/')) {
        body = _items(staff: staff).firstWhere((i) => i['id'] == path.split('/').last);
      } else if (path == '/lost-reports' && req.method == 'GET') {
        body = _reports;
      } else if (path == '/claims' && req.method == 'GET') {
        body = [_claim];
      } else if (path.endsWith('/matches')) {
        body = path.contains('h3p8')
            ? [
                {'score': 0.81, 'breakdown': {'category': 1.0, 'color': 1.0, 'location': 1.0}, 'item': _items()[3]},
              ]
            : [];
      } else if (path == '/staff/claims') {
        body = [
          {
            'claim': {..._claim, 'status': 'under_review', 'token': null, 'pickupCode': null}, 'item': _items(staff: true)[0],
            'report': _reports[0],
          },
          {
            'claim': {..._claim, 'id': 'c2', 'status': 'under_review', 'itemId': 'f00dcafe0001', 'answer': 'my student card is inside', 'userId': 'pax-02c4e8aa'},
            'item': _items(staff: true)[2], 'report': {..._reports[1], 'id': 'w1', 'category': 'wallet', 'color': 'brown', 'description': 'Brown leather wallet'},
          },
        ];
      } else if (path.startsWith('/claims/scan/')) {
        body = {'claim': _claim, 'item': _items(staff: true)[0], 'report': _reports[0]};
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });

// Image.network goes through dart:io's HttpClient, which tests block: serve the files from DECK_IMAGES instead.
class _ImageOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _ImageClient();
}

class _ImageClient implements HttpClient {
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _ImageRequest(url);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageRequest implements HttpClientRequest {
  final Uri url;
  _ImageRequest(this.url);

  @override
  Future<HttpClientResponse> close() async {
    final name = url.path.contains('/qr') ? 'qr.png' : url.pathSegments.last;
    final file = File('$_images/$name');
    return _ImageResponse(file.existsSync() ? file.readAsBytesSync() : null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  final List<int>? bytes;
  _ImageResponse(this.bytes);

  @override
  int get statusCode => bytes == null ? 404 : 200;
  @override
  int get contentLength => bytes?.length ?? 0;
  @override
  HttpClientResponseCompressionState get compressionState => HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream<List<int>>.fromIterable([?bytes]).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _loadFonts() async {
  final dir = '${Platform.environment['FLUTTER_ROOT'] ?? r'C:\src\flutter'}/bin/cache/artifacts/material_fonts';
  Future<ByteData> bytes(String f) async => ByteData.view(File('$dir/$f').readAsBytesSync().buffer);
  await (FontLoader('Roboto')
        ..addFont(bytes('roboto-regular.ttf'))
        ..addFont(bytes('roboto-medium.ttf'))
        ..addFont(bytes('roboto-bold.ttf')))
      .load();
  await (FontLoader('MaterialIcons')..addFont(bytes('materialicons-regular.otf'))).load();
  // Pickup codes and claim tokens use the platform's 'monospace' family.
  final mono = File(r'C:\Windows\Fonts\consola.ttf');
  if (mono.existsSync()) {
    await (FontLoader('monospace')..addFont(Future.value(ByteData.view(mono.readAsBytesSync().buffer)))).load();
  }
}

/// Lets requests, image downloads and decoding finish (they run outside the fake clock).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
  }
}

Future<void> _show(WidgetTester tester, Widget page, {Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  debugDisableShadows = false; // real shadows (tests draw them as black outlines by default)
  await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(brightness), home: page));
  await _settle(tester);
}

Future<void> _shot(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('../build/screenshots/deck_$name.png'));

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.tap(find.text(text).last);
  await _settle(tester);
}

/// Unmounts the page (stops timers / sockets) and restores the test defaults.
Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  debugDisableShadows = true;
}

void main() {
  setUpAll(() async {
    if (!_enabled) return;
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
    HttpOverrides.global = _ImageOverrides();
    Api.instance.client = _backend();
    Api.instance.baseUrl = 'http://deck.local';
  });

  setUp(() {
    AppData.instance.zones = [];
  });

  testWidgets('passenger app', skip: !_enabled, (tester) async {
    AppData.instance.userId = _pax.id;
    AppData.instance.session.value = _pax;
    await _show(tester, AppShell.create());
    await _shot(tester, 'pax_home');
    await _tap(tester, 'Find items');
    await _shot(tester, 'pax_found');
    await _tap(tester, 'I found it');
    await _shot(tester, 'pax_hand_in');
    await tester.drag(find.byType(Scrollable).at(1), const Offset(0, -900));
    await _settle(tester);
    await _shot(tester, 'pax_hand_in_2');
    await _tap(tester, 'My reports');
    await _shot(tester, 'pax_reports');
    await _done(tester);
  });

  testWidgets('passenger pickup pass', skip: !_enabled, (tester) async {
    AppData.instance.session.value = _pax;
    await _show(
      tester,
      PickupPassScreen(
        report: LostReport.fromJson(_reports[0]),
        claim: Claim.fromJson(_claim),
        item: FoundItem.fromJson(_items()[0]),
      ),
    );
    await _shot(tester, 'pax_pass');
    await _show(tester, const ChatScreen(reportId: 'r7k2m9q4x1z0'));
    await _shot(tester, 'pax_chat');
    await _done(tester);
  });

  testWidgets('passenger item details and report form', skip: !_enabled, (tester) async {
    AppData.instance.session.value = _pax;
    await _show(tester, ItemDetailsScreen(item: FoundItem.fromJson(_items()[1])));
    await _shot(tester, 'pax_item');
    await _show(tester, const ReportScreen());
    await _tap(tester, 'Add the first place');
    await _shot(tester, 'pax_route_picker');
    await _tap(tester, 'Check-in hall');
    await _tap(tester, 'Add a place');
    await _tap(tester, 'BRD Bank');
    await _tap(tester, 'Add a place');
    await _tap(tester, 'Departure gates');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await _settle(tester);
    await _shot(tester, 'pax_report_form');
    await _done(tester);
  });

  testWidgets('email verification', skip: !_enabled, (tester) async {
    await _show(tester, const VerifyEmailScreen(email: 'ana.pop@gmail.com'));
    await tester.enterText(find.byType(TextField), '483');
    await tester.pump();
    await _shot(tester, 'verify_email');
    await _done(tester);
  });

  testWidgets('staff desk', skip: !_enabled, (tester) async {
    AppData.instance.session.value = _staff;
    await _show(tester, const StaffHome());
    await _shot(tester, 'staff_intake');
    await _tap(tester, 'Inventory');
    await _shot(tester, 'staff_inventory');
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -1200));
    await _settle(tester);
    await _shot(tester, 'staff_inventory_2');
    await _tap(tester, 'Review');
    await _shot(tester, 'staff_review');
    await _tap(tester, 'Pick-up');
    await _shot(tester, 'staff_pickup');
    await _show(tester, const ClaimReviewScreen(token: '7f3a91c2d4e5'));
    await _shot(tester, 'staff_scan');
    await _show(tester, const ChatsScreen());
    await _shot(tester, 'staff_chats');
    await _done(tester);
  });
}
