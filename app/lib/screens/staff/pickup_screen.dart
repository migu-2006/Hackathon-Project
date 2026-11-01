import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../api.dart';
import '../../i18n.dart';
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
    // Phones scan on-device; the desk PC sends webcam frames to the backend's QR decoder.
    final code = await Navigator.push<String>(context,
        MaterialPageRoute(builder: (_) => isDesktop ? const _WebcamScannerPage() : const _ScannerPage()));
    if (code != null) _open(code);
  }

  /// A screenshot or photo of the pass (e.g. the passenger sent it by message).
  Future<void> _scanImage() async {
    final file = await pickPhoto(context);
    if (file == null) return;
    try {
      final code = await Api.instance.scanQrImage(file);
      if (mounted) _open(code);
    } catch (e) {
      if (mounted) showError(context, e);
    }
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
          Text('Scan the passenger\'s pick-up QR code'.tr, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text((isDesktop ? 'Scan with webcam' : 'Scan QR code').tr),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _scanImage,
            icon: const Icon(Icons.image_search),
            label: Text('Read QR from a screenshot'.tr),
          ),
          const SizedBox(height: 24),
          Row(children: [const Expanded(child: Divider()), Text('  ${'or type the pickup code'.tr}  '), const Expanded(child: Divider())]),
          const SizedBox(height: 16),
          TextField(
            controller: _token,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'Pickup code'.tr,
              hintText: 'e.g. K7Q-M4X'.tr,
              helperText: 'The 6 characters under the passenger\'s QR'.tr,
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
        appBar: AppBar(title: Text('Scan pick-up code'.tr)),
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

/// Desk PCs: mobile_scanner has no Windows support, so take webcam stills and let the backend decode them.
class _WebcamScannerPage extends StatefulWidget {
  const _WebcamScannerPage();

  @override
  State<_WebcamScannerPage> createState() => _WebcamScannerPageState();
}

class _WebcamScannerPageState extends State<_WebcamScannerPage> {
  CameraController? _camera;
  String? _error;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      // Skip IR cameras (Windows Hello): they can't see a phone screen.
      final usable = cameras.where((c) => !c.name.toLowerCase().contains(' ir ')).toList();
      if (usable.isEmpty) throw CameraException('none', 'No webcam found on this PC.');
      final camera = CameraController(usable.first, ResolutionPreset.high, enableAudio: false);
      await camera.initialize();
      if (!mounted) return await camera.dispose();
      setState(() => _camera = camera);
      unawaited(_loop());
    } on CameraException catch (e) {
      if (mounted) setState(() => _error = e.description ?? e.code);
    }
  }

  Future<void> _loop() async {
    while (_running && mounted) {
      try {
        final code = await Api.instance.scanQrImage(await _camera!.takePicture());
        if (_running && mounted) {
          _running = false;
          Navigator.pop(context, code);
        }
        return;
      } on ApiException {
        // No QR in this frame yet; keep looking.
      } catch (e) {
        if (mounted) setState(() => _error = '$e');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  @override
  void dispose() {
    _running = false;
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Scan pick-up code'.tr)),
        body: _error != null
            ? EmptyState(icon: Icons.videocam_off, message: _error!)
            : _camera == null
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    Expanded(child: Center(child: CameraPreview(_camera!))),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Hold the passenger\'s QR code up to the webcam.'.tr, textAlign: TextAlign.center),
                    ),
                  ]),
      );
}

/// Claim status from the server (ready_for_pickup...) as a readable, translated label.
String _statusLabel(String s) => switch (s) {
      'awaiting_answer' => 'Awaiting answer',
      'under_review' => 'Claim under review',
      'ready_for_pickup' => 'Ready for pickup',
      'recovered' => 'Recovered',
      'rejected' => 'Rejected',
      'locked' => 'Locked out',
      _ => s,
    }.tr;

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
        content: Text((status == 'recovered' ? 'Item handed over ✔ Status: Recovered' : 'Claim rejected').tr),
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
      appBar: AppBar(title: Text('Verify claim'.tr)),
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
                  label: Text('Status: {status}'.trf({'status': _statusLabel('${claim['status']}')})),
                ),
                ItemCard(item: item),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Verification'.tr, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text('Q: {question}'.trf({'question': claim['question']}), style: theme.textTheme.bodySmall),
                      const SizedBox(height: 4),
                      Text('Passenger answer:'.tr, style: theme.textTheme.labelLarge),
                      Text('"${claim['answer'] ?? '—'}"', style: theme.textTheme.bodyLarge),
                      const Divider(height: 24),
                      Text('Compare with (staff only):'.tr, style: theme.textTheme.labelLarge),
                      Text('Hidden detail: {detail}'.trf({'detail': item.secretDetail?.isNotEmpty == true ? item.secretDetail : '—'})),
                      if (item.text.isNotEmpty) Text('Text on item: "{text}"'.trf({'text': item.text})),
                      if (item.notes?.isNotEmpty == true) Text('Notes: {notes}'.trf({'notes': item.notes})),
                      const Divider(height: 24),
                      Text('Original report:'.tr, style: theme.textTheme.labelLarge),
                      Text('${report['description']}'),
                      Text('Passenger: {id}'.trf({'id': claim['userId']}), style: theme.textTheme.bodySmall),
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
                        label: Text('Reject'.tr),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _decide(true),
                        icon: const Icon(Icons.check),
                        label: Text('Hand over'.tr),
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
