import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../api.dart';
import '../../models.dart';
import '../../widgets.dart';

/// Modul C: the operator scans the passenger's QR, checks the verification answer and hands over.
class PickupScreen extends StatefulWidget {
  const PickupScreen({super.key});

  @override
  State<PickupScreen> createState() => _PickupScreenState();
}

class _PickupScreenState extends State<PickupScreen> {
  final _token = TextEditingController();

  Future<void> _scan() async {
    final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const _ScannerPage()));
    if (code != null) _open(code);
  }

  void _open(String token) {
    if (token.trim().isEmpty) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => ClaimReviewScreen(token: token.trim())));
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: ListView(padding: const EdgeInsets.all(24), shrinkWrap: true, children: [
          Icon(Icons.qr_code_2, size: 96, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            isDesktop ? 'Enter the code shown under the passenger\'s QR' : 'Scan the passenger\'s pick-up QR code',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          // The QR scanner plugin has no Windows/Linux support; desks on PC type (or USB-scan) the code.
          if (!isDesktop) ...[
            FilledButton.icon(
              onPressed: _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR code'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
            const SizedBox(height: 24),
            const Row(children: [Expanded(child: Divider()), Text('  or enter code  '), Expanded(child: Divider())]),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _token,
            decoration: InputDecoration(
              labelText: 'Claim code',
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: () => _open(_token.text)),
            ),
            onSubmitted: _open,
          ),
        ]),
      ),
    );
  }
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan pick-up code')),
        body: MobileScanner(
          onDetect: (capture) {
            final value = capture.barcodes.firstOrNull?.rawValue;
            if (_done || value == null || !value.startsWith('lostfound:claim:')) return;
            _done = true;
            Navigator.pop(context, value);
          },
        ),
      );
}

class ClaimReviewScreen extends StatefulWidget {
  final String token;
  const ClaimReviewScreen({super.key, required this.token});

  @override
  State<ClaimReviewScreen> createState() => _ClaimReviewScreenState();
}

class _ClaimReviewScreenState extends State<ClaimReviewScreen> {
  late final Future<Map<String, dynamic>> _data =Api.instance.scanClaim(widget.token);
  bool _busy = false;

  Future<void> _decide(bool approved) async {
    setState(() => _busy = true);
    try {
      final status = await Api.instance.decideClaim(widget.token, approved);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(status == 'recovered' ? 'Item handed over ✔ Status: Recovered' : 'Claim rejected'),
      ));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Verify claim')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) return EmptyState(icon: Icons.error_outline, message: '${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final claim = snap.data!['claim'] as Map<String, dynamic>;
          final item = FoundItem.fromJson(snap.data!['item']);
          final report = snap.data!['report'] as Map<String, dynamic>;
          final pending = claim['status'] == 'ready_for_pickup';
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Chip(
                  avatar: Icon(pending ? Icons.hourglass_top : Icons.info_outline, size: 18),
                  label: Text('Status: ${claim['status']}'),
                ),
                ItemCard(item: item),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Verification', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text('Q: ${claim['question']}', style: theme.textTheme.bodySmall),
                      const SizedBox(height: 4),
                      Text('Passenger answer:', style: theme.textTheme.labelLarge),
                      Text('"${claim['answer'] ?? '—'}"', style: theme.textTheme.bodyLarge),
                      const Divider(height: 24),
                      Text('Compare with (staff only):', style: theme.textTheme.labelLarge),
                      Text('Hidden detail: ${item.secretDetail?.isNotEmpty == true ? item.secretDetail : '—'}'),
                      if (item.text.isNotEmpty) Text('Text on item: "${item.text}"'),
                      if (item.notes?.isNotEmpty == true) Text('Notes: ${item.notes}'),
                      const Divider(height: 24),
                      Text('Original report:', style: theme.textTheme.labelLarge),
                      Text('${report['description']}'),
                      Text('Passenger: ${claim['userId']}', style: theme.textTheme.bodySmall),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                if (pending)
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _decide(false),
                        icon: const Icon(Icons.close),
                        label: const Text('Reject'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _decide(true),
                        icon: const Icon(Icons.check),
                        label: const Text('Hand over'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          backgroundColor: Colors.green,
                        ),
                      ),
                    ),
                  ]),
              ]),
            ),
          );
        },
      ),
    );
  }
}
