import 'package:flutter/material.dart';

import '../app_state.dart';
import '../glass.dart';
import '../i18n.dart';
import '../theme.dart';
import '../ui.dart';

/// Terms & conditions for the lost property service, opened from Account & settings.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static final lastUpdated = DateTime(2026, 11, 1);

  /// English text = translation key (i18n_strings.dart); {airport} is filled in when shown.
  static const sections = [
    ('1. The service',
        'SkyFindr helps passengers at {airport} report lost items and get back items handed in to the Lost Property desk. '
            'Using the app means you accept these terms.'),
    ('2. Your account',
        'Keep your sign-in details private. You are responsible for what is done with your account. '
            'Give accurate details so we can contact you about your items.'),
    ('3. Reports and matching',
        'Item matches are suggested automatically and may be wrong. A match is not a promise that we have your item. '
            'Staff review every claim before an item is released.'),
    ('4. Proving ownership',
        'To collect an item you must answer the security question about it and show photo ID at the desk. '
            'We may refuse a claim if ownership cannot be confirmed. Giving false information to claim an item is not allowed.'),
    ('5. How long we keep items',
        'Found items are kept for 90 days. After that they may be donated, recycled or disposed of. '
            'Perishables, and items that are unsafe or not allowed in the airport, may be disposed of sooner.'),
    ('6. Collection and delivery',
        'Items are collected in person at the desk during opening hours, or by someone you authorise in writing. '
            'Courier delivery, where offered, is at your cost and risk.'),
    ('7. Your data',
        'We use your name, email, reports and photos only to run the lost property service. '
            'They are kept no longer than needed and are not sold. You can ask the desk to delete your account.'),
    ('8. Liability',
        'We take reasonable care of items in our custody, but we are not responsible for items lost or damaged '
            'before they were handed in, or for items that are never found.'),
    ('9. Changes',
        'We may update these terms. The date at the top shows the latest version. '
            'If you keep using the app after a change, you accept the new terms.'),
  ];

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final airport = AppData.instance.airport.name;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          style: glassIconStyle(context),
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Text('Terms & conditions'.tr),
      ),
      body: PageBody(children: [
        PageHeader(title: 'Terms & conditions', subtitle: 'Last updated {date}'.trf({'date': fmtDate(lastUpdated)})),
        SurfaceCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (title, body) in sections)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title.tr, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                  const SizedBox(height: 4),
                  Text(body.trf({'airport': airport}), style: TextStyle(color: p.muted, fontSize: 12.5, height: 1.4)),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}
