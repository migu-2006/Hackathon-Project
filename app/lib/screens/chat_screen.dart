import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../models.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';

/// Live chat about one lost report, between its passenger and the airport's Lost & Found team.
/// Both apps use this screen; new messages arrive over the WebSocket (AppData.live).
class ChatScreen extends StatefulWidget {
  final String reportId;
  const ChatScreen({super.key, required this.reportId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  ChatThread? _thread;
  List<ChatMessage> _messages = [];
  Object? _error;
  bool _sending = false;
  StreamSubscription? _sub;

  bool get _staff => AppData.instance.user?.isStaff == true;

  @override
  void initState() {
    super.initState();
    AppData.instance.openChat = widget.reportId;
    _sub = AppData.instance.live.stream.listen(_onEvent);
    _load();
  }

  @override
  void dispose() {
    if (AppData.instance.openChat == widget.reportId) AppData.instance.openChat = null;
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    if (!_staff) AppData.instance.refreshChats(); // unread counts on My reports
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await Api.instance.chat(widget.reportId);
      if (!mounted) return;
      setState(() {
        _thread = t;
        // Keep messages that arrived live while this request was on its way.
        final ids = {for (final m in t.messages) m.id};
        _messages = [...t.messages, ..._messages.where((m) => !ids.contains(m.id))]
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _error = null;
      });
      _toBottom();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    if (event['type'] != 'chat') return;
    final m = ChatMessage.fromJson(event['message']);
    if (m.reportId != widget.reportId || _messages.any((x) => x.id == m.id)) return;
    setState(() => _messages = [..._messages, m]);
    _toBottom();
    // From the other side: reload to mark it read (and pick up who is answering).
    if (m.fromStaff != _staff) _load();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final m = await Api.instance.sendChat(widget.reportId, text);
      _input.clear();
      if (mounted && !_messages.any((x) => x.id == m.id)) setState(() => _messages = [..._messages, m]);
      _toBottom();
      if (_staff && _thread?.staffName == null) _load(); // we are now the passenger's contact
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String get _title {
    final t = _thread;
    if (t == null) return 'Chat'.tr;
    if (_staff) return t.passengerName ?? 'Passenger'.tr;
    return t.staffName ?? 'Lost & Found team'.tr;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: p.tint,
            child: Icon(_staff ? Icons.person_outline : Icons.support_agent, color: p.primary, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: p.success, shape: BoxShape.circle)),
                const SizedBox(width: 5),
                Text(
                  _staff ? 'Passenger'.tr : 'Lost & Found team · {airport}'.trf({'airport': AppData.instance.airportByCode(_thread?.report.airport ?? AppData.instance.airport.code).short}),
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
              ]),
            ]),
          ),
        ]),
      ),
      body: Column(children: [
        if (_thread != null) _CaseHeader(thread: _thread!, staff: _staff),
        Expanded(
          child: _error != null && _thread == null
              ? Center(child: Text('$_error', style: TextStyle(color: p.muted)))
              : _thread == null
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                      ? EmptyState(
                          icon: Icons.forum_outlined,
                          message: _staff
                              ? 'No messages yet. Say hello to the passenger.'
                              : 'Ask the Lost & Found team anything about your item. They usually answer within minutes.',
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                          itemCount: _messages.length,
                          itemBuilder: (_, i) {
                            final m = _messages[i];
                            final prev = i > 0 ? _messages[i - 1] : null;
                            final newDay = prev == null || fmtDay(prev.timestamp) != fmtDay(m.timestamp);
                            return Column(children: [
                              if (newDay) _DayChip(fmtDay(m.timestamp)),
                              _Bubble(
                                message: m,
                                mine: m.fromStaff == _staff,
                                // Staff names on the first message of each run, except your own.
                                showName: m.fromStaff && prev?.senderId != m.senderId && m.senderId != AppData.instance.user?.id,
                              ),
                            ]);
                          },
                        ),
        ),
        _Composer(controller: _input, sending: _sending, onSend: _send),
      ]),
    );
  }
}

/// What the conversation is about: the report and the item it matched.
class _CaseHeader extends StatelessWidget {
  final ChatThread thread;
  final bool staff;
  const _CaseHeader({required this.thread, required this.staff});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final r = thread.report;
    final item = thread.item;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(color: p.surface, border: Border(bottom: BorderSide(color: p.border))),
      child: Row(children: [
        ItemImage(
          url: item == null ? r.imageUrl : (staff ? item.imageUrl : AppData.instance.photoOf(item)),
          category: r.category,
          size: 40,
          hidden: item != null && !staff && AppData.instance.photoHidden(item),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(itemTitle(r.color, r.category), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            Text(
              'Report {ref} · {date}'.trf({'ref': AppData.instance.reportRef(r), 'date': fmtDay(r.timestamp)}),
              style: TextStyle(color: p.muted, fontSize: 11.5),
            ),
          ]),
        ),
        if (item != null) const RBadge('Match', icon: Icons.auto_awesome, kind: BadgeKind.info),
      ]),
    );
  }
}

class _DayChip extends StatelessWidget {
  final String day;
  const _DayChip(this.day);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(10)),
        child: Text(day, style: TextStyle(color: p.muted, fontSize: 11)),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;
  final bool showName;
  const _Bubble({required this.message, required this.mine, required this.showName});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final fg = mine ? Colors.white : p.text;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: mine ? p.primary : p.surface,
            border: mine ? null : Border.all(color: p.border),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(mine ? 16 : 4),
              bottomRight: Radius.circular(mine ? 4 : 16),
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (showName && message.senderName != null)
              Text(message.senderName!, style: TextStyle(color: mine ? Colors.white70 : p.primary, fontSize: 11, fontWeight: FontWeight.w700)),
            Text(message.text, style: TextStyle(color: fg, fontSize: 14, height: 1.3)),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.bottomRight,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(fmtTime(message.timestamp), style: TextStyle(color: mine ? Colors.white70 : p.muted, fontSize: 10.5)),
                if (mine) ...[
                  const SizedBox(width: 4),
                  Icon(message.read ? Icons.done_all : Icons.done, size: 13, color: Colors.white70),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  const _Composer({required this.controller, required this.sending, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(color: p.surface, border: Border(top: BorderSide(color: p.border))),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(hintText: 'Write a message…'.tr, counterText: '', isDense: true),
            ),
          ),
          const SizedBox(width: 6),
          IconButton.filled(
            tooltip: 'Send'.tr,
            onPressed: sending ? null : onSend,
            icon: sending
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send),
          ),
        ]),
      ),
    );
  }
}
