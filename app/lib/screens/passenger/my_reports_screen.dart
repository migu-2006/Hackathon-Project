import 'package:flutter/material.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../glass.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import 'item_details_screen.dart';
import 'report_screen.dart';

class StageBadge extends StatelessWidget {
  final ReportStage stage;
  const StageBadge(this.stage, {super.key});

  @override
  Widget build(BuildContext context) => switch (stage) {
        ReportStage.searching => const RBadge('Searching', kind: BadgeKind.neutral),
        ReportStage.actionNeeded => const RBadge('Action needed', kind: BadgeKind.warning),
        ReportStage.underReview => const RBadge('Claim under review', kind: BadgeKind.warning),
        ReportStage.readyForPickup => const RBadge('Ready for pickup', icon: Icons.check, kind: BadgeKind.success),
        ReportStage.recovered => const RBadge('Recovered', icon: Icons.check, kind: BadgeKind.success),
      };
}

/// "We're on the case." — follow each report from lost to reunited.
class MyReportsScreen extends StatefulWidget {
  const MyReportsScreen({super.key});

  @override
  State<MyReportsScreen> createState() => _MyReportsScreenState();
}

class _MyReportsScreenState extends State<MyReportsScreen> {
  bool _closed = false;

  @override
  Widget build(BuildContext context) {
    final data = AppData.instance;
    return Scaffold(
      appBar: rAppBar(context, 'My reports', actions: [
        RefreshButton(onRefresh: data.refresh),
        IconButton(
          style: glassIconStyle(context),
          icon: const Icon(Icons.add),
          tooltip: 'New report',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReportScreen())),
        ),
      ]),
      body: ListenableBuilder(
        listenable: data,
        builder: (context, _) {
          final reports = _closed ? data.closedReports : data.activeReports;
          return PageBody(onRefresh: data.refresh, children: [
            const PageHeader(title: "We're on the case.", subtitle: 'Follow your report from lost to reunited.'),
            _Tabs(
              active: data.activeReports.length,
              closed: data.closedReports.length,
              showClosed: _closed,
              onChanged: (v) => setState(() => _closed = v),
            ),
            const SizedBox(height: 10),
            if (!data.loaded) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            if (data.loaded && reports.isEmpty) ...[
              NoteCard(
                icon: _closed ? Icons.inventory_2_outlined : Icons.assignment_outlined,
                title: _closed ? 'No closed reports yet' : 'No active reports',
                body: _closed ? 'Recovered items will show up here.' : "Lost something? Report it and we'll keep looking.",
              ),
              if (!_closed) ...[
                const SizedBox(height: 12),
                PrimaryButton(
                  label: 'Report a lost item',
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReportScreen())),
                ),
              ],
            ],
            for (final r in reports) _ReportCase(report: r),
            const SizedBox(height: 6),
            const HelpLink(),
          ]);
        },
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  final int active;
  final int closed;
  final bool showClosed;
  final ValueChanged<bool> onChanged;
  const _Tabs({required this.active, required this.closed, required this.showClosed, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget tab(String label, bool selected, VoidCallback onTap) => Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: selected ? p.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: selected ? Border.all(color: p.border) : null,
              ),
              alignment: Alignment.center,
              child: Text(label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? p.primary : p.muted,
                  )),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.border.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        tab('Active ($active)', !showClosed, () => onChanged(false)),
        tab('Closed ($closed)', showClosed, () => onChanged(true)),
      ]),
    );
  }
}

/// One report: header, progress timeline, next-step note and the main action.
class _ReportCase extends StatelessWidget {
  final LostReport report;
  const _ReportCase({required this.report});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    final stage = data.stageOf(report);
    final claim = data.claimFor(report.id);
    final item = claim != null ? data.itemCache[claim.itemId] : null;
    final matches = data.potentialMatches(report.id);
    final matchItem = item ?? (matches.isNotEmpty ? matches.first.item : null);
    final updated = [report.timestamp, claim?.timestamp, claim?.reviewedAt].whereType<DateTime>().reduce((a, b) => a.isAfter(b) ? a : b);

    final steps = <_Step>[
      _Step('Lost-item report received', fmtDayTime(report.timestamp), _StepState.done),
      _Step(
        stage == ReportStage.searching ? 'Looking for a match' : 'Potential match found',
        stage == ReportStage.searching
            ? "We'll notify you as soon as a similar item is handed in"
            : matchItem != null
                ? '${fmtDayTime(matchItem.timestamp)} · Not yet confirmed as yours'
                : 'Not yet confirmed as yours',
        stage == ReportStage.searching ? _StepState.current : _StepState.done,
      ),
      _Step(
        'Ownership review in progress',
        stage.index >= ReportStage.underReview.index ? 'Your private claim was sent to the team.' : 'Verify ownership privately to start',
        switch (stage) {
          ReportStage.underReview => _StepState.current,
          ReportStage.readyForPickup || ReportStage.recovered => _StepState.done,
          _ => stage == ReportStage.actionNeeded ? _StepState.current : _StepState.locked,
        },
      ),
      _Step(
        stage == ReportStage.recovered ? 'Collected. Reunited!' : 'Choose how to get it back',
        stage.index >= ReportStage.readyForPickup.index ? 'Pick up at the ${data.airport.desk}' : 'Available if ownership is confirmed.',
        switch (stage) {
          ReportStage.readyForPickup => _StepState.current,
          ReportStage.recovered => _StepState.done,
          _ => _StepState.locked,
        },
      ),
    ];

    final (nextTitle, nextBody) = switch (stage) {
      ReportStage.searching => ("Your next step: we're looking", "We check every item handed in. We'll notify you if there's a potential match."),
      ReportStage.actionNeeded => ('Your next step: review the match', 'Have a look and verify ownership privately if it looks like yours.'),
      ReportStage.underReview => ('Your next step: sit tight', "The team is checking your ownership details. We'll notify you with a decision or if we need more information."),
      ReportStage.readyForPickup => ('Your next step: collect it', 'Show your pickup pass at the desk. Identity check required.'),
      ReportStage.recovered => ('All done', 'Thanks for using SkyFindr. Safe travels!'),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                ItemImage(
                  url: matchItem != null ? AppData.instance.photoOf(matchItem) : report.imageUrl,
                  category: report.category,
                  size: 52,
                  hidden: matchItem != null && AppData.instance.photoHidden(matchItem),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(itemTitle(report.color, report.category), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                    Text('Report ${data.reportRef(report)} · ${fmtDay(report.timestamp)}', style: TextStyle(color: p.muted, fontSize: 12)),
                    const SizedBox(height: 4),
                    StageBadge(stage),
                  ]),
                ),
              ]),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Column(children: [
                for (var i = 0; i < steps.length; i++) _StepTile(step: steps[i], last: i == steps.length - 1),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Row(children: [
                Icon(Icons.update, size: 13, color: p.muted),
                const SizedBox(width: 6),
                Text('Last updated ${fmtUpdated(updated)}', style: TextStyle(color: p.muted, fontSize: 11)),
              ]),
            ),
          ]),
        ),
        NoteCard(icon: Icons.mail_outline, title: nextTitle, body: nextBody),
        const SizedBox(height: 6),
        if (stage == ReportStage.readyForPickup && claim != null)
          PrimaryButton(
            label: 'Open pickup pass',
            icon: Icons.qr_code_2,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PickupPassScreen(report: report, claim: claim, item: item),
            )),
          )
        else if (stage == ReportStage.underReview && claim != null)
          OutlinedButton(
            onPressed: () => _showClaimDetails(context, claim),
            child: const Row(children: [Expanded(child: Text('View private claim details')), Icon(Icons.north_east, size: 18)]),
          )
        else if (stage == ReportStage.actionNeeded)
          OutlinedButton(
            onPressed: () => _openMatch(context, claim, matches),
            child: const Row(children: [Expanded(child: Text('Review potential match')), Icon(Icons.north_east, size: 18)]),
          ),
      ]),
    );
  }

  void _openMatch(BuildContext context, Claim? claim, List<Match> matches) {
    final item = claim != null ? AppData.instance.itemCache[claim.itemId] : null;
    if (claim?.status == 'awaiting_answer' && item != null) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => VerifyClaimScreen(item: item)));
    } else if (matches.length == 1) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ItemDetailsScreen(item: matches.first.item)));
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => _MatchesScreen(matches: matches)));
    }
  }

  void _showClaimDetails(BuildContext context, Claim claim) {
    final p = Palette.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Private claim details', style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 12),
          InfoRow(icon: Icons.receipt_long_outlined, label: 'Claim', value: claim.id.toUpperCase()),
          InfoRow(icon: Icons.schedule, label: 'Sent', value: fmtDayTime(claim.timestamp)),
          InfoRow(icon: Icons.help_outline, label: 'Security question', value: claim.question),
          const SizedBox(height: 8),
          Text('Your answer is only visible to the airport team.', style: TextStyle(color: p.muted, fontSize: 12)),
        ]),
      ),
    );
  }
}

enum _StepState { done, current, locked }

class _Step {
  final String title;
  final String subtitle;
  final _StepState state;
  const _Step(this.title, this.subtitle, this.state);
}

class _StepTile extends StatelessWidget {
  final _Step step;
  final bool last;
  const _StepTile({required this.step, required this.last});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (icon, color) = switch (step.state) {
      _StepState.done => (Icons.check, p.success),
      _StepState.current => (Icons.radio_button_checked, p.primary),
      _StepState.locked => (Icons.lock_outline, p.muted),
    };
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: step.state == _StepState.current ? p.tint : Colors.transparent,
              border: Border.all(color: step.state == _StepState.locked ? p.border : color),
            ),
            child: Icon(icon, size: 13, color: color),
          ),
          if (!last) Expanded(child: Container(width: 1.5, color: p.border, margin: const EdgeInsets.symmetric(vertical: 2))),
        ]),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(step.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: step.state == _StepState.locked ? p.muted : p.text,
                  )),
              const SizedBox(height: 2),
              Text(step.subtitle, style: TextStyle(color: p.muted, fontSize: 11.5)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _MatchesScreen extends StatelessWidget {
  final List<Match> matches;
  const _MatchesScreen({required this.matches});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: rAppBar(context, 'Potential matches'),
        body: PageBody(children: [
          const PageHeader(title: 'Could it be yours?', subtitle: 'Items similar to your report, most similar first.'),
          for (final m in matches)
            FoundItemTile(
              item: m.item,
              potential: true,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ItemDetailsScreen(item: m.item))),
            ),
        ]),
      );
}

/// "Ready for pickup." — the QR pass shown at the Lost Property desk.
class PickupPassScreen extends StatelessWidget {
  final LostReport report;
  final Claim claim;
  final FoundItem? item;
  const PickupPassScreen({super.key, required this.report, required this.claim, this.item});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    final steps = [
      ('Show this QR to staff', 'At the ${data.airport.desk}.'),
      ('Answer the security question', 'Staff will ask you in person.'),
      ('Collect your ${report.category}', 'Only after staff confirm your identity.'),
    ];
    return Scaffold(
      appBar: rAppBar(context, 'Pickup pass'),
      body: PageBody(children: [
        const PageHeader(
          title: 'Ready for pickup.',
          subtitle: 'Your review is approved. Staff will confirm your identity when you arrive.',
        ),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                ItemImage(
                  url: item == null ? null : AppData.instance.photoOf(item!),
                  category: report.category,
                  size: 52,
                  hidden: item != null && AppData.instance.photoHidden(item!),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(itemTitle(item?.color ?? report.color, report.category),
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                    Text('Report ${data.reportRef(report)} · ${fmtDay(report.timestamp)}', style: TextStyle(color: p.muted, fontSize: 12)),
                    if (item != null) Text('Found item ${data.itemRef(item!)}', style: TextStyle(color: p.muted, fontSize: 12)),
                  ]),
                ),
              ]),
            ),
            const Divider(),
            const SizedBox(height: 12),
            const RBadge('Review approved', icon: Icons.check_circle, kind: BadgeKind.success),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
              child: Image.network(
                Api.instance.claimQrUrl(claim.id),
                width: 190,
                height: 190,
                filterQuality: FilterQuality.none,
                errorBuilder: (_, _, _) => const SizedBox(width: 190, height: 190, child: Icon(Icons.qr_code_2, size: 120)),
              ),
            ),
            const SizedBox(height: 8),
            Eyebrow('Pickup code', color: p.primary),
            const SizedBox(height: 2),
            SelectableText(
              formatPickupCode(claim.pickupCode),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 4, fontFamily: 'monospace'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
              child: Text('If the QR can\'t be scanned, staff can type this code · Claim ${claim.id.toUpperCase()}',
                  textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: 11)),
            ),
          ]),
        ),
        SurfaceCard(
          child: InfoRow(
            icon: Icons.place_outlined,
            label: 'Collection location',
            value: '${data.airportByCode(report.airport).short} · ${data.airportByCode(report.airport).desk}',
          ),
        ),
        SurfaceCard(
          color: p.tint,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('At pickup · identity check still required', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 10),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.surface, shape: BoxShape.circle, border: Border.all(color: p.border)),
                    child: Text('${i + 1}', style: TextStyle(fontSize: 11, color: p.primary, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(steps[i].$1, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
                      Text(steps[i].$2, style: TextStyle(color: p.muted, fontSize: 11.5)),
                    ]),
                  ),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 4),
        const HelpLink(),
      ]),
    );
  }
}
