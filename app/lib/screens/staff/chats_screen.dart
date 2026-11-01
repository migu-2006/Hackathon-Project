import 'dart:async';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../i18n.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../widgets.dart';
import '../chat_screen.dart';

/// Staff: conversations with passengers at this airport (reports with a possible match, or
/// any report a passenger wrote about). Updates live.
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  late Future<List<ChatThread>> _threads = _fetch();
  StreamSubscription? _sub;

  Future<List<ChatThread>> _fetch() => Api.instance.chats(airport: AppData.instance.airport.code);

  @override
  void initState() {
    super.initState();
    _sub = AppData.instance.live.stream.listen((e) {
      if (e['type'] == 'chat' && mounted) setState(() => _threads = _fetch());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _open(ChatThread t) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(reportId: t.report.id)));
    if (mounted) setState(() => _threads = _fetch());
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Passenger chats · {airport}'.trf({'airport': AppData.instance.airport.code})),
        actions: [RefreshButton(onRefresh: () async => setState(() => _threads = _fetch())), const SizedBox(width: 8)],
      ),
      body: FutureBuilder<List<ChatThread>>(
        future: _threads,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}', style: TextStyle(color: p.muted)));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final threads = snap.data!;
          if (threads.isEmpty) {
            return const EmptyState(
              icon: Icons.forum_outlined,
              message: 'No conversations yet. They start when a report gets a possible match or a passenger writes.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: threads.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 76),
            itemBuilder: (_, i) {
              final t = threads[i];
              final last = t.last;
              return ListTile(
                onTap: () => _open(t),
                leading: ItemImage(url: t.item?.imageUrl ?? t.report.imageUrl, category: t.report.category, size: 48),
                title: Row(children: [
                  Expanded(
                    child: Text(t.passengerName ?? 'Passenger'.tr,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: t.unread > 0 ? FontWeight.w700 : FontWeight.w600)),
                  ),
                  if (last != null) Text(fmtUpdated(last.timestamp), style: TextStyle(color: p.muted, fontSize: 11.5)),
                ]),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    '{item} · Report {ref}'.trf({'item': itemTitle(t.report.color, t.report.category), 'ref': AppData.instance.reportRef(t.report)}),
                    style: TextStyle(color: p.primary, fontSize: 12),
                  ),
                  Row(children: [
                    Expanded(
                      child: Text(
                        last == null ? 'Possible match. No messages yet.'.tr : '${last.fromStaff ? '${'You'.tr}: ' : ''}${last.text}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.unread > 0 ? p.text : p.muted, fontWeight: t.unread > 0 ? FontWeight.w600 : null),
                      ),
                    ),
                    if (t.unread > 0) Badge(label: Text('${t.unread}'), backgroundColor: p.primary),
                  ]),
                ]),
              );
            },
          );
        },
      ),
    );
  }
}
