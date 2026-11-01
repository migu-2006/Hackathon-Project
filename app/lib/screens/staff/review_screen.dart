import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../widgets.dart';

/// Ownership review: compare the passenger's private answer with the hidden detail, then
/// approve (passenger gets a pickup pass) or reject (report goes back to searching).
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => ReviewScreenState();
}

class ReviewScreenState extends State<ReviewScreen> {
  late Future<List<Map<String, dynamic>>> _claims = Api.instance.staffClaims();
  final _busy = <String>{};

  Future<void> refresh() {
    setState(() {
      _claims = Api.instance.staffClaims();
    });
    return _claims;
  }

  Future<void> _decide(String claimId, bool approved) async {
    setState(() => _busy.add(claimId));
    try {
      await Api.instance.reviewClaim(claimId, approved);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(approved ? 'Approved: the passenger received a pickup pass.' : 'Claim rejected.'),
      ));
      refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(claimId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _claims,
      builder: (context, snap) {
        if (snap.hasError) return EmptyState(icon: Icons.cloud_off, message: '${snap.error}');
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final claims = snap.data!;
        return PageBody(onRefresh: () async => refresh(), children: [
          PageHeader(
            title: 'Ownership review',
            subtitle: claims.isEmpty
                ? 'No claims waiting. New claims appear here after passengers answer.'
                : '${claims.length} claim(s) waiting for a decision.',
          ),
          for (final c in claims) _card(context, p, c),
        ]);
      },
    );
  }

  Widget _card(BuildContext context, Palette p, Map<String, dynamic> data) {
    final claim = data['claim'] as Map<String, dynamic>;
    final item = FoundItem.fromJson(data['item']);
    final report = LostReport.fromJson(data['report']);
    final id = claim['id'] as String;
    final busy = _busy.contains(id);
    return SurfaceCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ItemImage(url: item.imageUrl, category: item.category, size: 56),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(itemTitle(item.color, item.category), style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${item.location} · found ${fmtDay(item.timestamp)}', style: TextStyle(color: p.muted, fontSize: 12)),
              Text('Claim ${id.toUpperCase()} · ${fmtDayTime(DateTime.parse(claim['timestamp']).toLocal())}',
                  style: TextStyle(color: p.muted, fontSize: 12)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Eyebrow('Question', color: p.primary),
        Text('${claim['question']}', style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 8),
        Eyebrow('Passenger answer', color: p.primary),
        Text('"${claim['answer'] ?? '—'}"', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: p.warningFill, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Eyebrow('Compare with · staff only', color: p.warning),
            const SizedBox(height: 4),
            Text('Hidden detail: ${item.secretDetail?.isNotEmpty == true ? item.secretDetail : '—'}', style: const TextStyle(fontSize: 13)),
            if (item.text.isNotEmpty) Text('Text on item: "${item.text}"', style: const TextStyle(fontSize: 13)),
            if (report.description.isNotEmpty) Text('Report: ${report.description}', style: const TextStyle(fontSize: 13)),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: busy ? null : () => _decide(id, false),
              icon: const Icon(Icons.close),
              label: const Text('Reject'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              onPressed: busy ? null : () => _decide(id, true),
              style: FilledButton.styleFrom(backgroundColor: p.success),
              icon: const Icon(Icons.check),
              label: const Text('Approve'),
            ),
          ),
        ]),
      ]),
    );
  }
}
