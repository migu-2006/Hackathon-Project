import 'package:flutter/material.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../widgets.dart';

/// Verification log: every answer passengers typed for an item's security question,
/// grouped per passenger + item. After too many wrong answers the passenger is locked out
/// of that item; staff can lift the lock once they've checked the person at the desk.
class AttemptsScreen extends StatefulWidget {
  const AttemptsScreen({super.key});

  @override
  State<AttemptsScreen> createState() => AttemptsScreenState();
}

class AttemptsScreenState extends State<AttemptsScreen> {
  bool _lockedOnly = false;
  late Future<List<Map<String, dynamic>>> _log = _fetch();
  final _busy = <String>{};

  Future<List<Map<String, dynamic>>> _fetch() =>
      Api.instance.claimAttempts(airport: AppData.instance.airport.code, lockedOnly: _lockedOnly);

  void refresh() => setState(() {
        _log = _fetch();
      });

  Future<void> _unlock(String userId, String itemId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlock this passenger?'),
        content: const Text(
          'Only do this after checking their ID and boarding pass. '
          'Their wrong answers stay in the log but stop counting, and they can answer again.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unlock')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy.add('$userId/$itemId'));
    try {
      await Api.instance.unlockClaims(userId, itemId);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Unlocked: the passenger can try again.')));
      refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove('$userId/$itemId'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _log,
      builder: (context, snap) {
        if (snap.hasError) return EmptyState(icon: Icons.cloud_off, message: '${snap.error}');
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final groups = snap.data!;
        final locked = groups.where((g) => g['locked'] == true).length;
        return PageBody(
          onRefresh: () async => refresh(),
          children: [
            PageHeader(
              title: 'Verification log',
              subtitle: groups.isEmpty
                  ? (_lockedOnly
                        ? 'No passengers are locked out.'
                        : 'No answers yet. Every ownership answer is logged here.')
                  : '${groups.length} passenger/item pair(s)${locked > 0 ? ' · $locked locked out' : ''}',
            ),
            Row(
              children: [
                FilterPill(
                  label: 'All',
              trailingIcon: null,
                  active: !_lockedOnly,
                  onTap: () {
                    _lockedOnly = false;
                    refresh();
                  },
                ),
                const SizedBox(width: 8),
                FilterPill(
                  label: 'Locked only',
              trailingIcon: null,
                  active: _lockedOnly,
                  onTap: () {
                    _lockedOnly = true;
                    refresh();
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final g in groups) _card(p, g),
          ],
        );
      },
    );
  }

  Widget _card(Palette p, Map<String, dynamic> g) {
    final item = FoundItem.fromJson(g['item']);
    final userId = g['userId'] as String;
    final failed = g['failed'] as int;
    final max = g['maxAttempts'] as int;
    final isLocked = g['locked'] == true;
    final attempts = [for (final a in g['attempts'] as List) Map<String, dynamic>.from(a)];
    return SurfaceCard(
      highlighted: isLocked,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ItemImage(url: item.imageUrl, category: item.category, size: 52),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(itemTitle(item.color, item.category), style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      '${AppData.instance.itemRef(item)} · ${item.location}',
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                    Text('Passenger $userId', style: TextStyle(color: p.muted, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (isLocked)
                const RBadge('Locked out', icon: Icons.lock, kind: BadgeKind.warning)
              else
                RBadge(
                  '$failed / $max wrong',
                  icon: Icons.shield_outlined,
                  kind: failed > 0 ? BadgeKind.warning : BadgeKind.neutral,
                ),
              RBadge('${attempts.length} attempt${attempts.length == 1 ? '' : 's'}', kind: BadgeKind.neutral),
            ],
          ),
          if (item.secretDetail?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text('Hidden detail: ${item.secretDetail}', style: TextStyle(color: p.warning, fontSize: 12.5)),
          ],
          const SizedBox(height: 6),
          for (final a in attempts) _attemptRow(p, a),
          if (isLocked) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy.contains('$userId/${item.id}') ? null : () => _unlock(userId, item.id),
                icon: const Icon(Icons.lock_open),
                label: const Text('Unlock after ID check'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _attemptRow(Palette p, Map<String, dynamic> a) {
    final (icon, color, label) = switch (a['result']) {
      'correct' => (Icons.check_circle, p.success, 'Matched'),
      'wrong' => (Icons.cancel, const Color(0xFFE5484D), a['cleared'] == true ? 'Wrong · cleared' : 'Wrong'),
      _ => (Icons.help, p.muted, 'Sent to review'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('"${a['answer']}"', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
                Text(
                  '$label · ${fmtDayTime(DateTime.parse(a['timestamp']).toLocal())}',
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
