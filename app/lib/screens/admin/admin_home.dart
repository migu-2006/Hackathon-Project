import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../i18n.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../widgets.dart';
import '../account.dart';
import '../developer_screen.dart';
import '../staff/staff_home.dart';

/// Administrator: manage every account (create staff, change roles, reset passwords, disable)
/// and jump into the staff desk or the developer tools.
class AdminHome extends StatefulWidget {
  const AdminHome({super.key});

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  late Future<List<AppUser>> _users = Api.instance.users();
  String? _role; // null = everyone
  String _query = '';

  @override
  void initState() {
    super.initState();
    AppData.instance.refresh(); // airports for the staff "home airport" picker
  }

  Future<void> _reload() {
    setState(() {
      _users = Api.instance.users();
    });
    return _users;
  }

  Future<void> _create() async {
    final created = await showDialog<(AppUser, String)>(context: context, builder: (_) => const _NewAccountDialog());
    if (created == null || !mounted) return;
    _reload();
    await _showCredentials(context, created.$1, created.$2);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Administrator'.tr),
        actions: [RefreshButton(onRefresh: _reload), const AccountButton(), const SizedBox(width: 8)],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.person_add_alt_1),
        label: Text('Add staff account'.tr),
      ),
      body: FutureBuilder<List<AppUser>>(
        future: _users,
        builder: (context, snap) {
          if (snap.hasError) return EmptyState(icon: Icons.cloud_off, message: '${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final all = snap.data!;
          int count(String r) => all.where((u) => u.role == r).length;
          final q = _query.toLowerCase();
          final shown = all
              .where((u) => _role == null || u.role == _role)
              .where((u) => q.isEmpty || u.name.toLowerCase().contains(q) || u.email.contains(q))
              .toList();
          return PageBody(onRefresh: _reload, children: [
            const PageHeader(title: 'Accounts', subtitle: 'Passengers sign up in the app. Staff accounts are created here.'),
            Row(children: [
              Expanded(
                child: _ShortcutCard(
                  icon: Icons.badge_outlined,
                  title: 'Staff desk',
                  subtitle: 'Intake, review, pick-up',
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StaffHome())),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ShortcutCard(
                  icon: Icons.developer_mode,
                  title: 'Developer tools',
                  subtitle: 'Reset demo data',
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DeveloperScreen())),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(hintText: 'Search by name or email'.tr, prefixIcon: const Icon(Icons.search)),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (role, label) in [
                (null, 'All · {n}'.trf({'n': all.length})),
                ('passenger', 'Passengers · {n}'.trf({'n': count('passenger')})),
                ('staff', 'Staff · {n}'.trf({'n': count('staff')})),
                ('admin', 'Admins · {n}'.trf({'n': count('admin')})),
              ])
                FilterPill(label: label, trailingIcon: null, active: _role == role, onTap: () => setState(() => _role = role)),
            ]),
            const SizedBox(height: 8),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('No accounts here yet.'.tr, textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
              ),
            for (final u in shown)
              SurfaceCard(
                onTap: () async {
                  final changed = await showModalBottomSheet<bool>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (_) => _UserSheet(user: u),
                  );
                  if (changed == true) _reload();
                },
                child: Row(children: [
                  UserAvatar(u),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(u.name + (u.id == AppData.instance.user?.id ? ' ${'(you)'.tr}' : ''),
                          style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                      Text(u.email, style: TextStyle(color: p.muted, fontSize: 12), overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    RBadge(u.roleLabel,
                        kind: switch (u.role) { 'admin' => BadgeKind.warning, 'staff' => BadgeKind.success, _ => BadgeKind.info }),
                    if (u.disabled) ...[
                      const SizedBox(height: 4),
                      const RBadge('Disabled', icon: Icons.block, kind: BadgeKind.neutral),
                    ] else if (u.airport != null) ...[
                      const SizedBox(height: 4),
                      RBadge(u.airport!, icon: Icons.flight, kind: BadgeKind.neutral),
                    ],
                  ]),
                ]),
              ),
            const SizedBox(height: 72), // room for the button
          ]);
        },
      ),
    );
  }
}

class _ShortcutCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ShortcutCard({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SurfaceCard(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: p.primary),
        const SizedBox(height: 8),
        Text(title.tr, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(subtitle.tr, style: TextStyle(color: p.muted, fontSize: 12)),
      ]),
    );
  }
}

/// Easy to read out and type: no 0/O or 1/l/I.
String _newPassword() {
  const chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  return List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
}

Widget _airportField(String? value, ValueChanged<String?> onChanged) => DropdownButtonFormField<String?>(
      // Airports may not be loaded yet: an unknown code shows as "Any" rather than crashing the dropdown.
      initialValue: AppData.instance.airports.any((a) => a.code == value) ? value : null,
      decoration: InputDecoration(labelText: 'Home airport'.tr, prefixIcon: const Icon(Icons.flight_outlined)),
      items: [
        DropdownMenuItem(value: null, child: Text('Any airport'.tr)),
        for (final a in AppData.instance.airports) DropdownMenuItem(value: a.code, child: Text('${a.code} · ${a.short}')),
      ],
      onChanged: onChanged,
    );

/// Shown once after creating an account or resetting a password, so the admin can pass it on.
Future<void> _showCredentials(BuildContext context, AppUser user, String password) => showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 40),
        title: Text('{role} account ready'.trf({'role': user.roleLabel.tr})),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Give these details to the account owner. The password is not shown again.'.tr),
          const SizedBox(height: 12),
          SelectableText('${'Email'.tr}: ${user.email}\n${'Password'.tr}: $password',
              style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
        ]),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: 'SkyFindr ${user.roleLabel.toLowerCase()} sign-in\n'
                'Email: ${user.email}\nPassword: $password')),
            icon: const Icon(Icons.copy, size: 18),
            label: Text('Copy'.tr),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text('Done'.tr)),
        ],
      ),
    );

class _NewAccountDialog extends StatefulWidget {
  const _NewAccountDialog();

  @override
  State<_NewAccountDialog> createState() => _NewAccountDialogState();
}

class _NewAccountDialogState extends State<_NewAccountDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController(text: _newPassword());
  String _role = 'staff';
  String? _airport = AppData.instance.airport.code;
  bool _busy = false;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final user = await Api.instance.createUser(
          name: _name.text.trim(), email: _email.text.trim(), password: _password.text, role: _role, airport: _airport);
      if (mounted) Navigator.pop(context, (user, _password.text));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('New account'.tr),
        content: SizedBox(
          width: 400,
          child: Form(
            key: _form,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: 'staff', label: Text('Staff'.tr), icon: const Icon(Icons.badge_outlined)),
                    ButtonSegment(value: 'admin', label: Text('Admin'.tr), icon: const Icon(Icons.admin_panel_settings_outlined)),
                  ],
                  selected: {_role},
                  onSelectionChanged: (s) => setState(() => _role = s.first),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: 'Full name'.tr, prefixIcon: const Icon(Icons.person_outline)),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name'.tr : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(labelText: 'Email'.tr, prefixIcon: const Icon(Icons.mail_outline)),
                  validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : 'Enter a valid email'.tr,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  decoration: InputDecoration(
                    labelText: 'Password'.tr,
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: 'Generate another'.tr,
                      icon: const Icon(Icons.refresh),
                      onPressed: () => setState(() => _password.text = _newPassword()),
                    ),
                  ),
                  validator: (v) => (v ?? '').length < 6 ? 'At least 6 characters'.tr : null,
                ),
                if (_role == 'staff') ...[
                  const SizedBox(height: 12),
                  _airportField(_airport, (v) => setState(() => _airport = v)),
                ],
              ]),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
          FilledButton(onPressed: _busy ? null : _save, child: Text('Create account'.tr)),
        ],
      );
}

/// One account: role, home airport, password reset, disable / enable, delete.
class _UserSheet extends StatefulWidget {
  final AppUser user;
  const _UserSheet({required this.user});

  @override
  State<_UserSheet> createState() => _UserSheetState();
}

class _UserSheetState extends State<_UserSheet> {
  late AppUser _user = widget.user;
  bool _changed = false;
  bool _busy = false;

  bool get _isMe => _user.id == AppData.instance.user?.id;

  Future<void> _update({String? role, String? airport, bool? disabled, String? password}) async {
    setState(() => _busy = true);
    try {
      final u = await Api.instance.updateUser(_user.id, role: role, airport: airport, disabled: disabled, password: password);
      if (!mounted) return;
      setState(() {
        _user = u;
        _changed = true;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPassword() async {
    final password = _newPassword();
    await _update(password: password);
    if (mounted) await _showCredentials(context, _user, password);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete {name}?'.trf({'name': _user.name})),
        content: Text('The account is removed and signed out. Reports and claims it made stay in the records.'.tr),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel'.tr)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete'.tr),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.deleteUser(_user.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              UserAvatar(_user, radius: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_user.name, style: Theme.of(context).textTheme.titleMedium),
                  Text(_user.email, style: TextStyle(color: p.muted)),
                ]),
              ),
              if (_busy) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
            const SizedBox(height: 20),
            Text('Role'.tr, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: 'passenger', label: Text('Passenger'.tr)),
                ButtonSegment(value: 'staff', label: Text('Staff'.tr)),
                ButtonSegment(value: 'admin', label: Text('Admin'.tr)),
              ],
              selected: {_user.role},
              onSelectionChanged: _isMe || _busy ? null : (s) => _update(role: s.first),
            ),
            if (_isMe) Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('You can\'t change your own role.'.tr, style: TextStyle(color: p.muted, fontSize: 12)),
            ),
            if (_user.role == 'staff') ...[
              const SizedBox(height: 16),
              _airportField(_user.airport, (v) => _update(airport: v ?? '')),
            ],
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.key_outlined),
              title: Text('Reset password'.tr),
              subtitle: Text('Creates a new password and signs the account out'.tr),
              onTap: _busy ? null : _resetPassword,
            ),
            if (!_isMe) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(_user.disabled ? Icons.check_circle_outline : Icons.block),
                title: Text((_user.disabled ? 'Enable account' : 'Disable account').tr),
                subtitle: Text((_user.disabled ? 'Lets the account sign in again' : 'Signs the account out and blocks sign-in').tr),
                onTap: _busy ? null : () => _update(disabled: !_user.disabled),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.delete_outline, color: Color(0xFFE5484D)),
                title: Text('Delete account'.tr, style: const TextStyle(color: Color(0xFFE5484D))),
                onTap: _busy ? null : _delete,
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
