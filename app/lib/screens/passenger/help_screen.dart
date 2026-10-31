import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../account.dart';
import '../developer_screen.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    const steps = [
      (Icons.assignment_outlined, 'Report', 'Tell us what you lost, where and when.'),
      (Icons.auto_awesome, 'Match', 'Our AI compares your report with every item handed in.'),
      (Icons.verified_user_outlined, 'Verify', 'Answer a private security question about your item.'),
      (Icons.qr_code_2, 'Pick up', 'Show your pickup pass and ID at the desk.'),
    ];
    const faq = [
      ('How long do you keep found items?', 'Items are held for 90 days. Valuables are logged and stored securely.'),
      ('Can someone else collect my item?', 'Yes, with a signed authorisation and a copy of your ID. Ask the desk first.'),
      ("I've already left the airport.", 'Once your claim is approved, ask the desk about courier delivery.'),
      ('Why was my claim not approved?', "We couldn't confirm ownership. Your report stays active and we keep looking."),
    ];
    return Scaffold(
      appBar: rAppBar(context, 'Help'),
      body: PageBody(children: [
        const PageHeader(title: "We're here to help.", subtitle: 'Everything you need to get your item back.'),
        SurfaceCard(
          child: Column(children: [
            InfoRow(icon: Icons.storefront_outlined, label: 'Lost Property desk', value: '${data.airport.name} · ${data.airport.desk}'),
            const InfoRow(icon: Icons.schedule, label: 'Opening hours', value: 'Every day, 07:00 – 22:00'),
            const InfoRow(icon: Icons.call_outlined, label: 'Phone', value: '+44 20 0000 0000'),
          ]),
        ),
        const SizedBox(height: 6),
        const SectionTitle('How it works'),
        SurfaceCard(
          child: Column(children: [
            for (final (icon, title, body) in steps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(9)),
                    child: Icon(icon, size: 18, color: p.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      Text(body, style: TextStyle(color: p.muted, fontSize: 12)),
                    ]),
                  ),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 6),
        const SectionTitle('Questions'),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (final (q, a) in faq)
              ExpansionTile(
                shape: const Border(),
                title: Text(q, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                expandedAlignment: Alignment.centerLeft,
                children: [Text(a, style: TextStyle(color: p.muted, fontSize: 12.5))],
              ),
          ]),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => showAccountSheet(context),
          icon: const Icon(Icons.settings_outlined, size: 18),
          label: const Text('Settings'),
        ),
      ]),
    );
  }
}

/// Account & settings: who is signed in, appearance, backend address, sign out.
Future<void> showAccountSheet(BuildContext context) {
  final data = AppData.instance;
  var devTaps = 0;
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Account & settings', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 4),
            // Hidden: tap the account row 7 times to unlock the developer tools.
            if (data.user != null)
              GestureDetector(
                onTap: () {
                  if (++devTaps == 7 && data.devKey == null) unlockDeveloperTools(ctx);
                },
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    UserAvatar(data.user!),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(data.user!.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(data.user!.email, style: TextStyle(color: p.muted, fontSize: 12)),
                      ]),
                    ),
                  ]),
                ),
              ),
            const SizedBox(height: 16),
            const Text('Appearance', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            ValueListenableBuilder<ThemeMode>(
              valueListenable: data.themeMode,
              builder: (_, mode, _) => SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
                ],
                selected: {mode},
                onSelectionChanged: (s) => data.setThemeMode(s.first),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Server address'),
              subtitle: Text(Api.instance.baseUrl),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () async {
                if (await editServerAddress(ctx) && ctx.mounted) Navigator.pop(ctx);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.key_outlined),
              title: const Text('Change password'),
              onTap: () => changePasswordDialog(ctx),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () async {
                Navigator.pop(ctx);
                await confirmSignOut(context);
              },
            ),
            ListenableBuilder(
              listenable: data,
              builder: (_, _) => data.devKey == null
                  ? const SizedBox.shrink()
                  : ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.developer_mode, color: Color(0xFFE5484D)),
                      title: const Text('Developer tools'),
                      subtitle: const Text('Reset demo data'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(ctx);
                        Navigator.of(context, rootNavigator: true)
                            .push(MaterialPageRoute(builder: (_) => const DeveloperScreen()));
                      },
                    ),
            ),
          ]),
        ),
      );
    },
  );
}

/// Lets the user point the app at another backend (e.g. the laptop's new IP). True if changed.
Future<bool> editServerAddress(BuildContext context) async {
  final ctrl = TextEditingController(text: Api.instance.baseUrl);
  final url = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Server address'),
      content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'http://192.168.1.10:8000')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
      ],
    ),
  );
  if (url == null || url.isEmpty) return false;
  Api.instance.baseUrl = url.replaceAll(RegExp(r'/+$'), '');
  await (await SharedPreferences.getInstance()).setString('baseUrl', Api.instance.baseUrl);
  AppData.instance.zones = []; // reload airport info from the new server
  if (AppData.instance.user != null) await AppData.instance.refresh();
  return true;
}
