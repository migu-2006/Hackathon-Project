import 'package:flutter/material.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../i18n.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../widgets.dart';
import 'map_screen.dart';
import 'photo_search_screen.dart';
import 'shell.dart';

class ItemDetailsScreen extends StatelessWidget {
  final FoundItem item;
  const ItemDetailsScreen({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    final potential = data.potentialItemIds.contains(item.id);
    final existingClaim = data.claimForItem(item.id);
    final airport = data.airportByCode(item.airport);
    final description = [
      itemTitle(item.color, item.label.isEmpty || item.label == 'other' ? item.category : item.label),
      if (item.notes?.isNotEmpty == true) item.notes!,
      'Unique details are kept private.'.tr,
    ].join('. ').replaceAll('..', '.');

    return Scaffold(
      appBar: rAppBar(context, 'Item details'),
      body: PageBody(
        children: [
          Container(
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.border),
            ),
            padding: const EdgeInsets.all(8),
            child: ItemImage(
              url: data.photoOf(item),
              category: item.category,
              size: double.infinity,
              height: 220,
              radius: 10,
              hidden: data.photoHidden(item),
            ),
          ),
          if (data.photoHidden(item)) const _HiddenPhotoHint(),
          const SizedBox(height: 14),
          Eyebrow('Found item · {ref}'.trf({'ref': data.itemRef(item)})),
          const SizedBox(height: 8),
          if (potential) ...[
            const PotentialMatchBadge(label: 'Potential match to your report'),
            const SizedBox(height: 8),
          ],
          Text(
            itemTitle(item.color, item.category),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 26),
          ),
          const SizedBox(height: 6),
          Text(description, style: TextStyle(color: p.muted, fontSize: 13.5, height: 1.4)),
          const SizedBox(height: 12),
          SurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              children: [
                InfoRow(icon: Icons.calendar_today_outlined, label: 'Date found', value: fmtDate(item.timestamp)),
                InfoRow(icon: Icons.place_outlined, label: 'Found near', value: '${airport.short} · ${item.location}'),
                InfoRow(
                  icon: Icons.inventory_2_outlined,
                  label: 'Safely held by',
                  value: '{airport} {team}'.trf({'airport': airport.short, 'team': airport.team.tr}),
                ),
                if (item.zoneId != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AirportMapScreen(airport: item.airport, focusZoneId: item.zoneId),
                        ),
                      ),
                      icon: const Icon(Icons.map_outlined, size: 16),
                      label: Text('View on map'.tr, style: const TextStyle(fontSize: 12.5)),
                    ),
                  ),
              ],
            ),
          ),
          if (item.status != 'available')
            const NoteCard(icon: Icons.check_circle_outline, title: 'This item has already been returned to its owner.')
          else if (existingClaim != null && (existingClaim.status == 'rejected' || existingClaim.status == 'locked'))
            const NoteCard(
              icon: Icons.block,
              title: "This item can't be claimed again",
              body: 'The airport team did not approve your claim, and each item can only be claimed once. '
                  'If you think this is a mistake, contact the airport team.',
            )
          else if (existingClaim != null && existingClaim.status != 'awaiting_answer') ...[
            const NoteCard(
              icon: Icons.hourglass_top,
              title: 'You already claimed this item',
              body: 'Follow its progress in My reports.',
            ),
            const SizedBox(height: 12),
            PrimaryButton(label: 'View claim status', onPressed: () => AppShell.goTo(ShellTab.reports, reset: true)),
          ] else ...[
            const NoteCard(
              icon: Icons.shield_outlined,
              title: "Looks familiar? Let's check securely.",
              body: 'Share a unique detail or proof of purchase in a private form. Only the airport team sees it.',
            ),
            const SizedBox(height: 12),
            PrimaryButton(
              label: 'Verify ownership & claim',
              icon: Icons.verified_user_outlined,
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => VerifyClaimScreen(item: item))),
            ),
          ],
          const SizedBox(height: 10),
          Center(
            child: Text(
              'This is a possible match, not confirmed ownership.\nThe airport team reviews every claim.'.tr,
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Private ownership check: answer the verification question; staff review it before pickup.
class VerifyClaimScreen extends StatefulWidget {
  final FoundItem item;
  const VerifyClaimScreen({super.key, required this.item});

  @override
  State<VerifyClaimScreen> createState() => _VerifyClaimScreenState();
}

class _VerifyClaimScreenState extends State<VerifyClaimScreen> {
  final _answer = TextEditingController();
  String? _claimId;
  String? _question;
  bool _busy = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  /// A claim always belongs to a report: reuse the matching one or file one for this item.
  Future<void> _start() async {
    final data = AppData.instance;
    try {
      var report = data.reportForItem(widget.item);
      report ??= (await Api.instance.createLostReport(
        userId: data.userId,
        airport: widget.item.airport,
        description: 'Claimed from found items',
        category: widget.item.category,
        color: widget.item.color,
        lastSeenLocation: widget.item.location,
      )).report;
      final c = await Api.instance.createClaim(report.id, widget.item.id);
      setState(() {
        _claimId = c.id;
        _question = c.question;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (_answer.text.trim().length < 3) {
      showError(context, 'Please share a bit more detail');
      return;
    }
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Send your claim?'.tr),
        content: Text(
          'You can claim this item only once. After you send it you can\'t change your description '
                  'or claim this item again, even if the airport team doesn\'t approve it.'
              .tr,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Keep editing'.tr)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Send'.tr)),
        ],
      ),
    );
    if (send != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await Api.instance.answerClaim(_claimId!, _answer.text.trim());
      await AppData.instance.refresh();
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      AppShell.goTo(ShellTab.reports, reset: true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final item = widget.item;
    return Scaffold(
      appBar: rAppBar(context, 'Verify ownership'),
      body: PageBody(
        children: [
          const PageHeader(
            title: "Let's check securely.",
            subtitle: 'Answer privately. Only the airport team sees your answer.',
          ),
          SurfaceCard(
            child: Row(
              children: [
                ItemImage(
                  url: AppData.instance.photoOf(item),
                  category: item.category,
                  size: 52,
                  hidden: AppData.instance.photoHidden(item),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(itemTitle(item.color, item.category), style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        'Found item {ref}'.trf({'ref': AppData.instance.itemRef(item)}),
                        style: TextStyle(color: p.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (_error != null)
            NoteCard(icon: Icons.error_outline, title: "We couldn't start the claim", body: '$_error')
          else if (_question == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            Eyebrow('Security question', color: p.primary),
            const SizedBox(height: 6),
            Text(_question!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, height: 1.35)),
            const SizedBox(height: 8),
            TextField(
              controller: _answer,
              maxLines: 4,
              maxLength: 500,
              decoration: InputDecoration(hintText: 'E.g. a sticker, scratch, engraving, what was inside…'.tr),
            ),
            const NoteCard(
              icon: Icons.lock_outline,
              title: 'One claim per item',
              body: 'The airport team reviews your description and decides, then issues a pickup pass. '
                  'You can send a claim for this item only once.',
            ),
            const SizedBox(height: 14),
            PrimaryButton(label: 'Send claim', icon: Icons.send_outlined, busy: _busy, onPressed: _submit),
          ],
          const SizedBox(height: 6),
          const HelpLink(),
        ],
      ),
    );
  }
}

/// Under a blurred photo: why it's blurred and how to see it clearly.
class _HiddenPhotoHint extends StatelessWidget {
  const _HiddenPhotoHint();

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Icon(Icons.shield_outlined, size: 16, color: p.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            "Photo blurred to protect the owner. Search with a photo of your own item to see a clear picture if it's a match.".tr,
            style: TextStyle(color: p.muted, fontSize: 12, height: 1.35),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PhotoSearchScreen())),
          child: Text('Search by photo'.tr, style: const TextStyle(fontSize: 12.5)),
        ),
      ]),
    );
  }
}
