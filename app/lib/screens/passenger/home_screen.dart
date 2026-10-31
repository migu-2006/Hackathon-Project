import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import 'help_screen.dart';
import 'map_screen.dart';
import 'my_reports_screen.dart';
import 'report_screen.dart';
import 'shell.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const _Logo(),
        actions: [
          IconButton(
            icon: Icon(Icons.account_circle_outlined, color: p.primary),
            tooltip: 'Account & settings',
            onPressed: () => showAccountSheet(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListenableBuilder(
        listenable: data,
        builder: (context, _) => PageBody(
          onRefresh: data.refresh,
          children: [
            const SizedBox(height: 8),
            const PageHeader(
              eyebrow: 'Airport lost & found',
              title: "Let's get you\nreunited.",
              subtitle: "Left something behind? We'll help you find your next step.",
            ),
            _AirportCard(airport: data.airport),
            const SizedBox(height: 14),
            _ActionCard(
              primary: true,
              icon: Icons.add_box_outlined,
              title: 'Report a lost item',
              subtitle: "Tell us what's missing. We'll keep looking.",
              onTap: () => AppShell.goTo(ShellTab.reports, reset: true, push: const ReportScreen()),
            ),
            _ActionCard(
              icon: Icons.search,
              title: 'Browse found items',
              subtitle: 'Search items handed in at the airport.',
              onTap: () => AppShell.goTo(ShellTab.find, reset: true),
            ),
            const SizedBox(height: 10),
            SectionTitle(
              'Your latest report',
              trailing: 'View all',
              onTrailing: () => AppShell.goTo(ShellTab.reports, reset: true),
            ),
            if (!data.loaded)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
            else if (data.error != null && data.reports.isEmpty)
              NoteCard(icon: Icons.cloud_off, title: "Can't reach the airport service", body: '${data.error}')
            else if (data.latestReport == null)
              SurfaceCard(
                child: Text('No reports yet. Lost something? Report it and we\'ll keep looking for you.',
                    style: TextStyle(color: p.muted, fontSize: 13)),
              )
            else
              LatestReportCard(report: data.latestReport!),
            const SizedBox(height: 8),
            const HelpLink(text: "You're not on your own. Get help"),
          ],
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Image.asset('assets/icon/icon.png', width: 28, height: 28, cacheWidth: 96, filterQuality: FilterQuality.medium),
      ),
      const SizedBox(width: 8),
      Text('SkyFindr', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20, color: p.text, letterSpacing: -0.5)),
    ]);
  }
}

class _AirportCard extends StatelessWidget {
  final Airport airport;
  const _AirportCard({required this.airport});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        // Real terminal outline from OpenStreetMap; tap to open the interactive map.
        InkWell(
          onTap: () => AppShell.goTo(ShellTab.find, reset: true, push: const AirportMapScreen()),
          child: SizedBox(
            height: 130,
            width: double.infinity,
            child: Stack(children: [
              Positioned.fill(child: AirportMiniMap(key: ValueKey(airport.code), airport: airport.code)),
              Positioned(
                right: 10,
                top: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: p.surface.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.map_outlined, size: 13, color: p.primary),
                    const SizedBox(width: 4),
                    Text('Open map', style: TextStyle(fontSize: 11, color: p.primary, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        InkWell(
          onTap: () => pickAirport(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
            child: Row(children: [
              Text(airport.code, style: TextStyle(color: p.primary, fontWeight: FontWeight.w800, fontSize: 17)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(airport.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  Text('All terminals · ${airport.country}', style: TextStyle(color: p.muted, fontSize: 11.5)),
                ]),
              ),
              Icon(Icons.keyboard_arrow_down, color: p.muted),
            ]),
          ),
        ),
      ]),
    );
  }
}
class _ActionCard extends StatelessWidget {
  final bool primary;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ActionCard({this.primary = false, required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final fg = primary ? Colors.white : p.text;
    final sub = primary ? Colors.white.withValues(alpha: 0.85) : p.muted;
    return SurfaceCard(
      color: primary ? p.primary : null,
      onTap: onTap,
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: primary ? Colors.white.withValues(alpha: 0.18) : p.tint,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, color: primary ? Colors.white : p.primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 14.5)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(color: sub, fontSize: 12)),
          ]),
        ),
        Icon(Icons.north_east, color: primary ? Colors.white : p.primary, size: 18),
      ]),
    );
  }
}

class LatestReportCard extends StatelessWidget {
  final LostReport report;
  const LatestReportCard({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final stage = AppData.instance.stageOf(report);
    final (message, icon) = switch (stage) {
      ReportStage.searching => ("We're looking. We'll notify you of any match.", Icons.search),
      ReportStage.actionNeeded => ('A potential match is ready to review.', Icons.auto_awesome),
      ReportStage.underReview => ('The team is checking your ownership details.', Icons.hourglass_top),
      ReportStage.readyForPickup => ('Your pickup pass is ready.', Icons.qr_code_2),
      ReportStage.recovered => ('Reunited. Have a safe trip!', Icons.check_circle),
    };
    return SurfaceCard(
      onTap: () => AppShell.goTo(ShellTab.reports, reset: true),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(itemTitle(report.color, report.category),
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          ),
          StageBadge(stage),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Icon(icon, size: 15, color: p.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(color: p.muted, fontSize: 12))),
          Icon(Icons.arrow_forward, size: 18, color: p.primary),
        ]),
      ]),
    );
  }
}
