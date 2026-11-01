import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'i18n.dart';
import 'models.dart';
import 'theme.dart';
import 'ui.dart';

/// Shared pieces of the lost-luggage screens (passenger and baggage desk).

const bagTypes = ['suitcase', 'soft_bag', 'backpack', 'stroller', 'sports', 'box', 'other'];

String bagTypeName(String? t) => switch (t) {
      'suitcase' => 'Suitcase',
      'soft_bag' => 'Soft bag / duffel',
      'backpack' => 'Backpack',
      'stroller' => 'Stroller / car seat',
      'sports' => 'Sports equipment',
      'box' => 'Box / parcel',
      _ => 'Other bag',
    }.tr;

IconData bagTypeIcon(String? t) => switch (t) {
      'suitcase' => Icons.luggage,
      'soft_bag' => Icons.work_outline,
      'backpack' => Icons.backpack_outlined,
      'stroller' => Icons.stroller_outlined,
      'sports' => Icons.sports_tennis,
      'box' => Icons.inventory_2_outlined,
      _ => Icons.shopping_bag_outlined,
    };

/// "Red suitcase" for the bag types the item names know; "Stroller / car seat · Red" otherwise.
String bagTitle(String? type, String? color) {
  final noun = {'suitcase': 'suitcase', 'backpack': 'backpack', 'soft_bag': 'handbag'}[type];
  if (noun != null) return itemTitle(color, noun);
  return [bagTypeName(type), if (color != null && color.isNotEmpty) colorName(color)].join(' · ');
}

String bagStatusLabel(String s) => switch (s) {
      'reported' => 'Searching',
      'located' => 'Located',
      'forwarded' => 'On its way',
      'arrived' => 'At the airport',
      'out_for_delivery' => 'Out for delivery',
      'ready_for_pickup' => 'Ready for pickup',
      'delivered' => 'Delivered',
      'declared_lost' => 'Declared lost',
      _ => s,
    }.tr;

BadgeKind bagStatusKind(String s) => switch (s) {
      'delivered' => BadgeKind.success,
      'declared_lost' => BadgeKind.neutral,
      'out_for_delivery' || 'ready_for_pickup' || 'arrived' => BadgeKind.success,
      'reported' => BadgeKind.warning,
      _ => BadgeKind.info,
    };

class BagStatusBadge extends StatelessWidget {
  final String status;
  const BagStatusBadge(this.status, {super.key});

  @override
  Widget build(BuildContext context) => RBadge(bagStatusLabel(status), kind: bagStatusKind(status));
}

/// Timeline title and icon of each desk event.
(String, IconData) bagEventLabel(String kind) => switch (kind) {
      'reported' => ('Report received', Icons.assignment_turned_in_outlined),
      'found_here' => ('Bag found at this airport', Icons.where_to_vote_outlined),
      'located' => ('Bag located', Icons.travel_explore),
      'forwarded' => ('On its way', Icons.flight_land),
      'arrived' => ('Arrived at the airport', Icons.local_airport),
      'out_for_delivery' => ('Out for delivery', Icons.local_shipping_outlined),
      'ready_for_pickup' => ('Ready for pickup at the desk', Icons.storefront_outlined),
      'delivered' => ('Delivered', Icons.check_circle_outline),
      'declared_lost' => ('Declared lost', Icons.report_outlined),
      'note' => ('Update from the desk', Icons.sticky_note_2_outlined),
      _ => (kind, Icons.circle_outlined),
    };

String bagEventDetail(BagEvent e) => [
      if (e.station != null && e.kind != 'found_here') 'At {station}'.trf({'station': e.station!}),
      if (e.flight != null) 'Flight {flight}'.trf({'flight': e.flight!}),
      if (e.eta != null) 'arriving {eta}'.trf({'eta': e.eta!}),
      if (e.note != null) e.note!,
    ].join(' · ');

/// The file's history, newest at the bottom, with what comes next greyed out.
class BagTimeline extends StatelessWidget {
  final BaggageReport report;
  final bool staff;
  const BagTimeline({super.key, required this.report, this.staff = false});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final events = report.events;
    final next = report.closed
        ? null
        : switch (report.status) {
            'out_for_delivery' || 'ready_for_pickup' => (report.deliveryMethod == 'deliver' ? 'Delivered to you' : 'Collected at the desk'),
            'arrived' => (report.deliveryMethod == 'deliver' ? 'Out for delivery' : 'Ready for pickup at the desk'),
            _ => 'Your bag reaches the airport',
          };
    return Column(children: [
      for (final (i, e) in events.indexed)
        _TimelineRow(
          icon: bagEventLabel(e.kind).$2,
          title: bagEventLabel(e.kind).$1.tr,
          detail: [bagEventDetail(e), if (staff && e.byName != null) e.byName!].where((s) => s.isNotEmpty).join(' · '),
          time: fmtDayTime(e.timestamp),
          color: e.kind == 'declared_lost' ? p.muted : (i == events.length - 1 && !report.closed ? p.primary : p.success),
          last: i == events.length - 1 && next == null,
        ),
      if (next != null) _TimelineRow(icon: Icons.more_horiz, title: next.tr, detail: '', time: '', color: p.border, last: true),
    ]);
  }
}

class _TimelineRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final String time;
  final Color color;
  final bool last;
  const _TimelineRow({required this.icon, required this.title, required this.detail, required this.time, required this.color, required this.last});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 1.6)),
            child: Icon(icon, size: 16, color: color),
          ),
          if (!last) Expanded(child: Container(width: 1.6, color: p.border)),
        ]),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14, top: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: color == p.border ? p.muted : p.text)),
              if (detail.isNotEmpty) Text(detail, style: TextStyle(color: p.muted, fontSize: 12)),
              if (time.isNotEmpty) Text(time, style: TextStyle(color: p.muted, fontSize: 11)),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Bag type grid: one tile per type with its icon.
class BagTypeGrid extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onChanged;
  const BagTypeGrid({super.key, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final t in bagTypes)
        ChoiceChip(
          avatar: Icon(bagTypeIcon(t), size: 18, color: t == selected ? p.primary : p.muted),
          label: Text(bagTypeName(t)),
          selected: t == selected,
          showCheckmark: false,
          onSelected: (_) => onChanged(t),
        ),
    ]);
  }
}

/// Phones: read the barcode on a bag tag (or the stub on the boarding pass).
class TagScannerPage extends StatefulWidget {
  const TagScannerPage({super.key});

  @override
  State<TagScannerPage> createState() => _TagScannerPageState();
}

class _TagScannerPageState extends State<TagScannerPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Scan the bag tag'.tr)),
        body: Stack(children: [
          MobileScanner(
            controller: MobileScannerController(formats: const [BarcodeFormat.itf2of5, BarcodeFormat.itf14, BarcodeFormat.code128]),
            onDetect: (capture) {
              final value = capture.barcodes.firstOrNull?.rawValue?.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
              if (_done || value == null || value.length < 6 || value.length > 10) return;
              _done = true;
              Navigator.pop(context, value.toUpperCase());
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
              child: Text('Point the camera at the barcode on the bag tag or on the stub stuck to your boarding pass.'.tr,
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            ),
          ),
        ]),
      );
}
