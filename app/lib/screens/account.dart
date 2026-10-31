import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';

/// Round avatar with the account's initials, coloured by role.
class UserAvatar extends StatelessWidget {
  final AppUser user;
  final double radius;
  const UserAvatar(this.user, {super.key, this.radius = 18});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = switch (user.role) { 'admin' => const Color(0xFF8E4EC6), 'staff' => p.success, _ => p.primary };
    return CircleAvatar(
      radius: radius,
      backgroundColor: color.withValues(alpha: user.disabled ? 0.08 : 0.16),
      child: Text(user.initials,
          style: TextStyle(color: user.disabled ? p.muted : color, fontWeight: FontWeight.w700, fontSize: radius * 0.75)),
    );
  }
}

/// App bar button for staff and administrators: who is signed in, change password, sign out.
class AccountButton extends StatelessWidget {
  const AccountButton({super.key});

  @override
  Widget build(BuildContext context) {
    final user = AppData.instance.user;
    if (user == null) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: 'Account',
      position: PopupMenuPosition.under,
      icon: UserAvatar(user, radius: 15),
      onSelected: (v) => v == 'password' ? changePasswordDialog(context) : confirmSignOut(context),
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(user.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('${user.email} · ${user.roleLabel}', style: const TextStyle(fontSize: 12)),
          ]),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'password', child: ListTile(leading: Icon(Icons.key_outlined), title: Text('Change password'))),
        const PopupMenuItem(value: 'signout', child: ListTile(leading: Icon(Icons.logout), title: Text('Sign out'))),
      ],
    );
  }
}

Future<void> confirmSignOut(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Sign out?'),
      content: const Text('You can sign in again with your email and password.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
      ],
    ),
  );
  if (ok == true) await AppData.instance.signOut();
}

Future<void> changePasswordDialog(BuildContext context) async {
  final current = TextEditingController();
  final next = TextEditingController();
  final form = GlobalKey<FormState>();
  final done = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Change password'),
      content: Form(
        key: form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            controller: current,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Current password'),
            validator: (v) => (v ?? '').isEmpty ? 'Required' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: next,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'New password', helperText: 'At least 6 characters'),
            validator: (v) => (v ?? '').length < 6 ? 'At least 6 characters' : null,
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            if (!form.currentState!.validate()) return;
            try {
              await Api.instance.changePassword(current.text, next.text);
              if (ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) {
              if (ctx.mounted) showError(ctx, e);
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (done == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password changed.')));
  }
}
