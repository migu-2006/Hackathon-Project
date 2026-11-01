import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../ui.dart';

/// Second step of sign-up: the 6-digit code emailed to the passenger. Submits by itself
/// once six digits are in; a correct code signs the passenger in.
class VerifyEmailScreen extends StatefulWidget {
  final String email;
  final int resendSeconds;
  const VerifyEmailScreen({super.key, required this.email, this.resendSeconds = 60});

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  static const _length = 6;
  final _code = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;
  String? _info;
  int _wait = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCooldown(widget.resendSeconds);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startCooldown(int seconds) {
    _timer?.cancel();
    setState(() => _wait = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _wait--);
      if (_wait <= 0) t.cancel();
    });
  }

  Future<void> _submit() async {
    if (_code.text.length != _length || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final s = await Api.instance.verifyEmail(widget.email, _code.text);
      await AppData.instance.signIn(s.token!, s.user!); // closes this screen and opens the passenger app
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      _code.clear();
      _focus.requestFocus();
    } catch (_) {
      if (mounted) setState(() => _error = 'Can\'t reach the server. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _error = null;
      _info = null;
    });
    try {
      await Api.instance.resendCode(widget.email);
      if (!mounted) return;
      _code.clear();
      setState(() => _info = 'A new code is on its way. Codes sent earlier no longer work.');
      _startCooldown(widget.resendSeconds);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Can\'t reach the server. Check your connection and try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('Verify your email'.tr)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Icon(Icons.mark_email_unread_outlined, size: 64, color: p.primary),
                const SizedBox(height: 16),
                Text('Check your email'.tr,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: p.text)),
                const SizedBox(height: 8),
                Text.rich(
                  TextSpan(children: [
                    TextSpan(text: 'We sent a 6-digit code to\n'.tr),
                    TextSpan(text: widget.email, style: TextStyle(fontWeight: FontWeight.w600, color: p.text)),
                    TextSpan(text: '\nEnter it below to activate your account.'.tr),
                  ]),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.muted, height: 1.5),
                ),
                const SizedBox(height: 28),
                _CodeBoxes(controller: _code, focus: _focus, length: _length, enabled: !_busy, onComplete: _submit),
                if (_error != null || _info != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _error != null ? scheme.errorContainer : p.tint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(children: [
                      Icon(_error != null ? Icons.error_outline : Icons.mark_email_read_outlined,
                          size: 20, color: _error != null ? scheme.onErrorContainer : p.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text((_error ?? _info!).tr,
                            style: TextStyle(color: _error != null ? scheme.onErrorContainer : p.text)),
                      ),
                    ]),
                  ),
                ],
                const SizedBox(height: 24),
                PrimaryButton(label: 'Verify', icon: Icons.verified_outlined, busy: _busy, onPressed: _submit),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _wait > 0 ? null : _resend,
                  child: Text(_wait > 0 ? 'Resend code in {n}s'.trf({'n': _wait}) : 'Didn\'t get it? Resend code'.tr),
                ),
                Text('Also check your spam folder. The code expires after 10 minutes.'.tr,
                    textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: 12)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Six boxes over one hidden text field, so paste and SMS/email autofill of the whole code work.
class _CodeBoxes extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final int length;
  final bool enabled;
  final VoidCallback onComplete;
  const _CodeBoxes({
    required this.controller,
    required this.focus,
    required this.length,
    required this.enabled,
    required this.onComplete,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: focus.requestFocus,
      child: Stack(children: [
        // The real input: invisible, but focused and receiving keystrokes / pasted codes.
        Opacity(
          opacity: 0,
          child: TextField(
            controller: controller,
            focusNode: focus,
            autofocus: true,
            enabled: enabled,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(length)],
            onChanged: (v) {
              if (v.length == length) onComplete();
            },
            decoration: const InputDecoration(counterText: ''),
          ),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([controller, focus]),
          builder: (context, _) {
            final text = controller.text;
            return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              for (var i = 0; i < length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 48,
                  height: 58,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: p.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: focus.hasFocus && i == text.length.clamp(0, length - 1) ? p.primary : p.border,
                      width: focus.hasFocus && i == text.length.clamp(0, length - 1) ? 2 : 1,
                    ),
                  ),
                  child: Text(i < text.length ? text[i] : '',
                      style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: p.text)),
                ),
            ]);
          },
        ),
      ]),
    );
  }
}
