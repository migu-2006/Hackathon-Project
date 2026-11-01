import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../theme.dart';
import '../ui.dart';
import 'account.dart';
import 'passenger/help_screen.dart';
import 'verify_email_screen.dart';

/// First screen without a session: one sign-in for every account. The account's role decides
/// where it lands (passenger app, staff desk or administrator). Passengers can create an account
/// here; staff and administrators get theirs from an administrator.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _hidden = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = _register
          ? await Api.instance.register(_name.text.trim(), _email.text.trim(), _password.text)
          : await Api.instance.login(_email.text.trim(), _password.text);
      if (s.needsCode) {
        // New (or never verified) passenger: enter the 6-digit code from the email first.
        if (mounted) {
          await Navigator.push(context, MaterialPageRoute(
              builder: (_) => VerifyEmailScreen(email: s.pendingEmail!, resendSeconds: s.resendSeconds)));
        }
        return;
      }
      await AppData.instance.signIn(s.token!, s.user!); // the app switches to the right home screen
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Can\'t reach the server. Check your connection and try again.'.tr);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (title, subtitle) = _register
        ? ('Create your account', 'Report lost items and follow your claims.')
        : ('Welcome back', 'Sign in with your email and password.');
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: AutofillGroup(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      // Hidden for the administrator: long-press the logo to point the app at another server.
                      GestureDetector(
                        onLongPress: () async {
                          if (await editServerAddress(context, showCurrent: false) && mounted) setState(() => _error = null);
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.asset('assets/icon/icon.png', width: 44, height: 44, cacheWidth: 132),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('SkyFindr',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 28, color: p.text, letterSpacing: -0.8)),
                    ]),
                    const SizedBox(height: 4),
                    Text('Airport Lost & Found'.tr, textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
                    const SizedBox(height: 36),
                    Text(title.tr, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: p.text)),
                    const SizedBox(height: 4),
                    Text(subtitle.tr, style: TextStyle(color: p.muted)),
                    const SizedBox(height: 20),
                    if (_register) ...[
                      TextFormField(
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        autofillHints: const [AutofillHints.name],
                        decoration: InputDecoration(labelText: 'Full name'.tr, prefixIcon: const Icon(Icons.person_outline)),
                        validator: (v) => (v ?? '').trim().isEmpty ? 'Enter your name'.tr : null,
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(labelText: 'Email'.tr, prefixIcon: const Icon(Icons.mail_outline)),
                      validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid email'.tr,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: _hidden,
                      autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password'.tr,
                        prefixIcon: const Icon(Icons.lock_outline),
                        helperText: _register ? 'At least 6 characters'.tr : null,
                        suffixIcon: IconButton(
                          tooltip: (_hidden ? 'Show password' : 'Hide password').tr,
                          icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _hidden = !_hidden),
                        ),
                      ),
                      validator: (v) => (v ?? '').length < (_register ? 6 : 1)
                          ? (_register ? 'At least 6 characters' : 'Enter your password').tr
                          : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(children: [
                          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.onErrorContainer, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
                          ),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 20),
                    PrimaryButton(
                      label: _register ? 'Create account' : 'Sign in',
                      icon: _register ? Icons.person_add_alt_1 : Icons.login,
                      busy: _busy,
                      onPressed: _submit,
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => setState(() {
                        _register = !_register;
                        _error = null;
                      }),
                      child: Text((_register ? 'Already have an account? Sign in' : 'New here? Create an account').tr),
                    ),
                    if (!_register)
                      Text('Airport staff: use the account your administrator gave you.'.tr,
                          textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: 12)),
                    const SizedBox(height: 24),
                    TextButton.icon(
                      onPressed: () => pickLanguage(context),
                      icon: Icon(Icons.translate, size: 16, color: p.muted),
                      label: Text(I18n.current.nativeName, style: TextStyle(color: p.muted, fontSize: 12)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
