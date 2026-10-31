import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';
import 'passenger/shell.dart';

/// Asks for the server's developer key (printed in the backend console, stored in
/// backend/data/dev_key.txt) and unlocks the developer tools on this device.
Future<void> unlockDeveloperTools(BuildContext context) async {
  final ctrl = TextEditingController();
  final key = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Developer tools'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Enter the developer key shown in the backend console when the server starts.'),
        const SizedBox(height: 12),
        TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'Developer key')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Unlock')),
      ],
    ),
  );
  if (key == null || key.isEmpty || !context.mounted) return;
  try {
    await Api.instance.devCheck(key);
    await AppData.instance.setDevKey(key);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Developer tools unlocked.')));
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class DeveloperScreen extends StatefulWidget {
  const DeveloperScreen({super.key});

  @override
  State<DeveloperScreen> createState() => _DeveloperScreenState();
}

class _DeveloperScreenState extends State<DeveloperScreen> {
  bool _includeItems = false;
  bool _busy = false;
  Map<String, dynamic>? _last;

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded),
        title: const Text('Reset all passenger data?'),
        content: Text(
          'This permanently deletes every lost report, claim, verification attempt and notification '
          'for all passengers, on every device.'
          '${_includeItems ? '\n\nThe found-items inventory and its photos are deleted too.' : '\n\nFound items stay in the inventory and go back on the shelf.'}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final deleted = await Api.instance.devReset(AppData.instance.devKey!, includeItems: _includeItems);
      await AppShell.resetAll(); // this device; others are told by the server
      if (!mounted) return;
      setState(() => _last = deleted);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.message.contains('developer key')) {
        await AppData.instance.setDevKey(null); // server key changed: lock again
        if (mounted) Navigator.pop(context);
      }
      if (mounted) showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Developer tools')),
      body: PageBody(children: [
        const PageHeader(title: 'Demo reset', subtitle: 'Start a demo from a clean slate.'),
        InfoRow(icon: Icons.dns_outlined, label: 'Server', value: Api.instance.baseUrl),
        const SizedBox(height: 8),
        SurfaceCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Deletes for all passengers', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final t in ['Lost-item reports', 'Claims and pickup passes', 'Verification attempts and lockouts', 'Notifications'])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Icon(Icons.remove_circle_outline, size: 16, color: p.muted),
                  const SizedBox(width: 8),
                  Expanded(child: Text(t, style: const TextStyle(fontSize: 13))),
                ]),
              ),
            const SizedBox(height: 4),
            Text('Every open app clears its screens right away.', style: TextStyle(color: p.muted, fontSize: 12)),
          ]),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _includeItems,
          onChanged: (v) => setState(() => _includeItems = v),
          title: const Text('Also delete found items'),
          subtitle: const Text('Empty the staff inventory and its photos too'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D), minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : _reset,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.delete_forever),
          label: const Text('Reset passenger data'),
        ),
        if (_last != null) ...[
          const SizedBox(height: 12),
          NoteCard(
            icon: Icons.check_circle_outline,
            title: 'Reset done',
            body: [
              for (final e in _last!.entries) '${e.key}: ${e.value}',
            ].join(' · '),
          ),
        ],
        const SizedBox(height: 20),
        Center(
          child: TextButton.icon(
            onPressed: () async {
              await AppData.instance.setDevKey(null);
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.lock_outline, size: 16),
            label: const Text('Lock developer tools on this device'),
          ),
        ),
      ]),
    );
  }
}
