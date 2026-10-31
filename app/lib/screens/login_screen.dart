import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';
import '../ui.dart';
import 'passenger/help_screen.dart';

enum Portal { passenger, staff, admin }

/// First screen without a session: one sign-in for the three kinds of account.
/// Passengers can create an account here; staff and administrators get theirs from an administrator.
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
  Portal _portal = Portal.passenger;
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
          : await Api.instance.login(_email.text.trim(), _password.text, role: _portal.name);
      await AppData.instance.signIn(s.token, s.user); // the app switches to the right home screen
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Can\'t reach the server at ${Api.instance.baseUrl}. Check the address below.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setPortal(Portal p) => setState(() {
        _portal = p;
        _register = false;
        _error = null;
      });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (title, subtitle) = switch (_portal) {
      Portal.passenger when _register => ('Create your account', 'Report lost items and follow your claims.'),
      Portal.passenger => ('Welcome back', 'Sign in to report and track lost items.'),
      Portal.staff => ('Staff sign-in', 'Register found items, review claims and hand items over.'),
      Portal.admin => ('Administrator', 'Manage staff and passenger accounts.'),
    };
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
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset('assets/icon/icon.png', width: 44, height: 44, cacheWidth: 132),
                      ),
                      const SizedBox(width: 10),
                      Text('SkyFindr',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 28, color: p.text, letterSpacing: -0.8)),
                    ]),
                    const SizedBox(height: 4),
                    Text('Airport Lost & Found', textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
                    const SizedBox(height: 28),
                    SegmentedButton<Portal>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: Portal.passenger, label: Text('Passenger')),
                        ButtonSegment(value: Portal.staff, label: Text('Staff')),
                        ButtonSegment(value: Portal.admin, label: Text('Admin')),
                      ],
                      selected: {_portal},
                      onSelectionChanged: (s) => _setPortal(s.first),
                    ),
                    const SizedBox(height: 24),
                    Text(title, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: p.text)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(color: p.muted)),
                    const SizedBox(height: 20),
                    if (_register) ...[
                      TextFormField(
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        autofillHints: const [AutofillHints.name],
                        decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_outline)),
                        validator: (v) => (v ?? '').trim().isEmpty ? 'Enter your name' : null,
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
                      validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid email',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _password,
                      obscureText: _hidden,
                      autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        helperText: _register ? 'At least 6 characters' : null,
                        suffixIcon: IconButton(
                          tooltip: _hidden ? 'Show password' : 'Hide password',
                          icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _hidden = !_hidden),
                        ),
                      ),
                      validator: (v) => (v ?? '').length < (_register ? 6 : 1)
                          ? (_register ? 'At least 6 characters' : 'Enter your password')
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
                    if (_portal == Portal.passenger)
                      TextButton(
                        onPressed: () => setState(() {
                          _register = !_register;
                          _error = null;
                        }),
                        child: Text(_register ? 'Already have an account? Sign in' : 'New here? Create an account'),
                      )
                    else
                      NoteCard(
                        icon: Icons.info_outline,
                        title: _portal == Portal.staff ? 'No account yet?' : 'Administrators only',
                        body: _portal == Portal.staff
                            ? 'Staff accounts are created by the administrator. Ask them for your email and password.'
                            : 'Staff and passenger accounts can\'t sign in here.',
                      ),
                    const SizedBox(height: 24),
                    TextButton.icon(
                      onPressed: () async {
                        await editServerAddress(context);
                        setState(() => _error = null);
                      },
                      icon: Icon(Icons.dns_outlined, size: 16, color: p.muted),
                      label: Text('Server · ${Api.instance.baseUrl}', style: TextStyle(color: p.muted, fontSize: 12)),
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
