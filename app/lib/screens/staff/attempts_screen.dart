import 'package:flutter/material.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../widgets.dart';

/// Verification log: every answer passengers typed for an item's security question,
/// grouped per passenger + item, so staff can spot someone guessing before they approve a claim.
class AttemptsScreen extends StatefulWidget {
  const AttemptsScreen({super.key});

  @override
  State<AttemptsScreen> createState() => AttemptsScreenState();
}

class AttemptsScreenState extends State<AttemptsScreen> {
  late Future<List<Map<String, dynamic>>> _log = _fetch();

  Future<List<Map<String, dynamic>>> _fetch() => Api.instance.claimAttempts(airport: AppData.instance.airport.code);

  Future<void> refresh() {
    setState(() {
      _log = _fetch();
    });
    return _log;
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
        return PageBody(
          onRefresh: () async => refresh(),
          children: [
            PageHeader(
              title: 'Claim log',
              subtitle: groups.isEmpty
                  ? 'No claims yet. What passengers send for an item is logged here.'
                  : '${groups.length} claim(s) sent',
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
    final attempts = [for (final a in g['attempts'] as List) Map<String, dynamic>.from(a)];
    return SurfaceCard(
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
          if (item.secretDetail?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text('Hidden detail: ${item.secretDetail}', style: TextStyle(color: p.warning, fontSize: 12.5)),
          ],
          const SizedBox(height: 6),
          for (final a in attempts) _attemptRow(p, a),
        ],
      ),
    );
  }

  Widget _attemptRow(Palette p, Map<String, dynamic> a) {
    final (icon, color, label) = switch (a['result']) {
      // 'correct' / 'wrong' come from the old automatic check, before every claim went to staff.
      'correct' => (Icons.check_circle, p.success, 'Matched'),
      'wrong' => (Icons.cancel, const Color(0xFFE5484D), 'Wrong'),
      _ => (Icons.send_outlined, p.primary, 'Sent to review'),
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
