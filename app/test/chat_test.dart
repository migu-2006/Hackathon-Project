import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lost_found_app/api.dart';
import 'package:lost_found_app/app_state.dart';
import 'package:lost_found_app/models.dart';
import 'package:lost_found_app/screens/chat_screen.dart';
import 'package:lost_found_app/theme.dart';

Map<String, dynamic> _msg(String id, String role, String text, {String? name}) => {
      'id': id, 'reportId': 'r7k2m9q4x1z0', 'senderId': role == 'staff' ? 's1' : 'p1', 'senderRole': role, 'senderName': name,
      'text': text, 'timestamp': '2026-11-01T09:0${id.length}:00Z', 'read': 0,
    };

void main() {
  testWidgets('chat shows the conversation, sends, and receives live messages', (tester) async {
    final sent = <String>[];
    AppData.instance.session.value = const AppUser(id: 'p1', email: 'ana@mail.com', name: 'Ana', role: 'passenger');
    Api.instance.client = MockClient((req) async {
      Object body = {};
      if (req.url.path == '/chats/r7k2m9q4x1z0' && req.method == 'GET') {
        body = {
          'report': {'id': 'r7k2m9q4x1z0', 'userId': 'p1', 'airport': 'CRA', 'category': 'phone', 'color': 'black',
                     'timestamp': '2026-10-31T08:00:00Z', 'status': 'matched', 'route': []},
          'item': null, 'passengerName': null, 'staffName': 'Maria Ionescu', 'unread': 0,
          'messages': [_msg('m1', 'passenger', 'Hello, is my phone there?')],
        };
      } else if (req.url.path == '/chats/r7k2m9q4x1z0' && req.method == 'POST') {
        final text = jsonDecode(req.body)['text'] as String;
        sent.add(text);
        body = _msg('m22', 'passenger', text);
      } else if (req.url.path == '/chats') {
        body = [];
      }
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });

    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const ChatScreen(reportId: 'r7k2m9q4x1z0')));
    await tester.pumpAndSettle();
    expect(find.text('Hello, is my phone there?'), findsOneWidget);
    expect(find.text('Maria Ionescu'), findsOneWidget);
    expect(AppData.instance.openChat, 'r7k2m9q4x1z0');

    await tester.enterText(find.byType(TextField), '  It has a gold case  ');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(sent, ['It has a gold case']);
    expect(find.text('It has a gold case'), findsOneWidget);

    // A staff reply arrives over the WebSocket: it appears without reloading by hand.
    AppData.instance.live.add({'type': 'chat', 'message': _msg('m333', 'staff', 'Yes, it is at the desk.', name: 'Maria Ionescu')});
    // Messages about other reports are ignored.
    AppData.instance.live.add({'type': 'chat', 'message': {..._msg('m4444', 'staff', 'Other case'), 'reportId': 'h3p8w2d6t5n1'}});
    await tester.pumpAndSettle();
    expect(find.text('Yes, it is at the desk.'), findsOneWidget);
    expect(find.text('Other case'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    expect(AppData.instance.openChat, isNull);
  });
}
