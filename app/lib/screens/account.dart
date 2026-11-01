import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../glass.dart';
import '../i18n.dart';
import '../models.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';
import 'terms_screen.dart';

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
      tooltip: 'Account'.tr,
      style: glassIconStyle(context),
      position: PopupMenuPosition.under,
      icon: UserAvatar(user, radius: 15),
      onSelected: (v) => switch (v) {
        'password' => changePasswordDialog(context),
        'language' => pickLanguage(context),
        'terms' => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const TermsScreen())),
        _ => confirmSignOut(context),
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(user.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('${user.email} · ${user.roleLabel.tr}', style: const TextStyle(fontSize: 12)),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'language',
          child: ListTile(
            leading: const Icon(Icons.translate),
            title: Text('Language'.tr),
            subtitle: Text(I18n.current.nativeName),
          ),
        ),
        PopupMenuItem(value: 'password', child: ListTile(leading: const Icon(Icons.key_outlined), title: Text('Change password'.tr))),
        PopupMenuItem(value: 'terms', child: ListTile(leading: const Icon(Icons.description_outlined), title: Text('Terms & conditions'.tr))),
        PopupMenuItem(value: 'signout', child: ListTile(leading: const Icon(Icons.logout), title: Text('Sign out'.tr))),
      ],
    );
  }
}

/// Language for the whole app, saved on this device. Open screens switch right away.
Future<void> pickLanguage(BuildContext context) async {
  final lang = await pickFromList<AppLanguage>(
    context,
    'Language',
    [for (final l in AppLanguage.values) (l, l.nativeName)],
    selected: I18n.current,
  );
  if (lang != null) await I18n.set(lang);
}

Future<void> confirmSignOut(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Sign out?'.tr),
      content: Text('You can sign in again with your email and password.'.tr),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel'.tr)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Sign out'.tr)),
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
      title: Text('Change password'.tr),
      content: Form(
        key: form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            controller: current,
            obscureText: true,
            decoration: InputDecoration(labelText: 'Current password'.tr),
            validator: (v) => (v ?? '').isEmpty ? 'Required'.tr : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: next,
            obscureText: true,
            decoration: InputDecoration(labelText: 'New password'.tr, helperText: 'At least 6 characters'.tr),
            validator: (v) => (v ?? '').length < 6 ? 'At least 6 characters'.tr : null,
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel'.tr)),
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
          child: Text('Save'.tr),
        ),
      ],
    ),
  );
  if (done == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Password changed.'.tr)));
  }
}
