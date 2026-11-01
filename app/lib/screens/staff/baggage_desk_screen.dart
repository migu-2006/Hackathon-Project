import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../baggage_ui.dart';
import '../../i18n.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../widgets.dart';
import '../chat_screen.dart';

/// Staff: the baggage service desk. Files = passengers' missing / damaged checked bags;
/// On hand = unclaimed bags the desk registered (left on the belt, rush bags from other airports).
class BaggageDeskScreen extends StatefulWidget {
  const BaggageDeskScreen({super.key});

  @override
  State<BaggageDeskScreen> createState() => BaggageDeskScreenState();
}

class BaggageDeskScreenState extends State<BaggageDeskScreen> {
  bool _bags = false;
  bool _closed = false;
  late Future<(List<BaggageReport>, List<OnHandBag>)> _data = _fetch();

  Future<(List<BaggageReport>, List<OnHandBag>)> _fetch() async {
    final code = AppData.instance.airport.code;
    final r = await Future.wait([Api.instance.baggageReports(airport: code), Api.instance.onHandBags(code)]);
    return (r[0] as List<BaggageReport>, r[1] as List<OnHandBag>);
  }

  void refresh() {
    if (mounted) {
      setState(() {
        _data = _fetch();
      });
    }
  }

  Future<void> _open(BaggageReport r) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BagFileScreen(reportId: r.id)));
    refresh();
  }

  Future<void> _register() async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const RegisterBagScreen()));
    if (saved == true) refresh();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _register,
        icon: const Icon(Icons.add),
        label: Text('Register bag'.tr),
      ),
      body: FutureBuilder<(List<BaggageReport>, List<OnHandBag>)>(
        future: _data,
        builder: (context, snap) {
          final files = snap.data?.$1 ?? const <BaggageReport>[];
          final bags = snap.data?.$2 ?? const <OnHandBag>[];
          final open = files.where((f) => !f.closed).toList();
          final shown = files.where((f) => f.closed == _closed).toList();
          return RefreshIndicator(
            onRefresh: () async => refresh(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: false,
                      icon: const Icon(Icons.folder_open),
                      label: Text('Files ({n})'.trf({'n': open.length})),
                    ),
                    ButtonSegment(
                      value: true,
                      icon: const Icon(Icons.luggage),
                      label: Text('On hand ({n})'.trf({'n': bags.length})),
                    ),
                  ],
                  selected: {_bags},
                  onSelectionChanged: (s) => setState(() => _bags = s.first),
                ),
                const SizedBox(height: 12),
                if (snap.hasError) EmptyState(icon: Icons.cloud_off, message: '${snap.error}'),
                if (!snap.hasData && !snap.hasError)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (snap.hasData && !_bags) ...[
                  Row(
                    children: [
                      FilterChip(
                        label: Text('Open'.tr),
                        selected: !_closed,
                        onSelected: (_) => setState(() => _closed = false),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: Text('Closed'.tr),
                        selected: _closed,
                        onSelected: (_) => setState(() => _closed = true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (shown.isEmpty)
                    EmptyState(
                      icon: Icons.luggage_outlined,
                      message: _closed ? 'No closed files yet.' : 'No missing bags reported. Enjoy the quiet!',
                    ),
                  for (final f in shown) _FileCard(report: f, onTap: () => _open(f)),
                ],
                if (snap.hasData && _bags) ...[
                  Text(
                    'Unclaimed bags waiting at the desk. Registering one matches it against every open file.'.tr,
                    style: TextStyle(color: p.muted, fontSize: 12.5),
                  ),
                  const SizedBox(height: 8),
                  if (bags.isEmpty) const EmptyState(icon: Icons.luggage_outlined, message: 'No unclaimed bags.'),
                  for (final b in bags) BagCard(bag: b),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  final BaggageReport report;
  final VoidCallback onTap;
  const _FileCard({required this.report, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final age = DateTime.now().difference(report.timestamp);
    // Over a day with nothing found: needs attention.
    final late = !report.closed && report.status == 'reported' && age.inHours >= 24;
    return SurfaceCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: late ? p.warningFill : p.tint, borderRadius: BorderRadius.circular(12)),
            child: Icon(bagTypeIcon(report.bagType), color: late ? p.warning : p.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(report.ref, style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    BagStatusBadge(report.status),
                  ],
                ),
                Text(
                  '{bag} · {flight}'.trf({'bag': bagTitle(report.bagType, report.color), 'flight': report.flight}),
                  style: TextStyle(color: p.text, fontSize: 13),
                ),
                Text(
                  [
                    if (report.tagNumbers.isNotEmpty) report.tagNumbers.join(', '),
                    if (report.kind == 'damaged') 'Damaged'.tr,
                    fmtUpdated(report.timestamp),
                  ].join(' · '),
                  style: TextStyle(color: late ? p.warning : p.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class BagCard extends StatelessWidget {
  final OnHandBag bag;
  final Widget? trailing;
  const BagCard({super.key, required this.bag, this.trailing});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SurfaceCard(
      child: Row(
        children: [
          bag.imageUrl.isEmpty
              ? Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(12)),
                  child: Icon(bagTypeIcon(bag.bagType), color: p.primary),
                )
              : ItemImage(url: bag.imageUrl, category: 'suitcase', size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(bagTitle(bag.bagType, bag.color), style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  [
                    bag.tagNumber != null ? 'Tag {tag}'.trf({'tag': bag.tagNumber!}) : 'No tag'.tr,
                    if (bag.flight != null) bag.flight!,
                    if (bag.nameOnTag?.isNotEmpty == true) bag.nameOnTag!,
                  ].join(' · '),
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
                Text(
                  [if (bag.location != null) bag.location!, fmtUpdated(bag.timestamp)].join(' · '),
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// One baggage file: passenger details, timeline, the matched bag or likely ones, and the desk actions.
class BagFileScreen extends StatefulWidget {
  final String reportId;
  const BagFileScreen({super.key, required this.reportId});

  @override
  State<BagFileScreen> createState() => _BagFileScreenState();
}

class _BagFileScreenState extends State<BagFileScreen> {
  BaggageReport? _report;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.instance.baggageReport(widget.reportId);
      if (mounted) {
        setState(() {
          _report = r;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _run(Future<BaggageReport> Function() action) async {
    setState(() => _busy = true);
    try {
      final r = await action();
      if (mounted) setState(() => _report = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks for the details an update needs (station, flight, ETA, note), then sends it.
  Future<void> _event(String kind) async {
    final station = TextEditingController();
    final flight = TextEditingController();
    final eta = TextEditingController();
    final note = TextEditingController();
    final fields = <Widget>[
      if (kind == 'located')
        TextField(
          controller: station,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: 'Airport where it is (IATA code)'.tr, hintText: 'e.g. OTP'),
        ),
      if (kind == 'forwarded') ...[
        TextField(
          controller: flight,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: 'Flight'.tr, hintText: 'e.g. RO 644'),
        ),
        TextField(
          controller: eta,
          decoration: InputDecoration(labelText: 'Arrives'.tr, hintText: 'e.g. 18:40'),
        ),
      ],
      TextField(
        controller: note,
        maxLines: 2,
        decoration: InputDecoration(labelText: (kind == 'note' ? 'Note' : 'Note (optional)').tr),
      ),
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(bagEventLabel(kind).$1.tr),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in fields) Padding(padding: const EdgeInsets.only(bottom: 8), child: f),
            if (kind == 'declared_lost')
              Text('The passenger will be told to claim compensation from the airline. This closes the file.'.tr),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel'.tr)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Save'.tr)),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      () => Api.instance.addBagEvent(
        widget.reportId,
        kind,
        station: station.text.trim(),
        flight: flight.text.trim(),
        eta: eta.text.trim(),
        note: note.text.trim(),
      ),
    );
  }

  /// The updates that make sense from the current status.
  List<(String, IconData)> _actions(BaggageReport r) {
    if (r.closed) return const [];
    final deliver = r.deliveryMethod == 'deliver';
    return [
      if (r.status == 'reported') ('located', Icons.travel_explore),
      if (r.status == 'reported' || r.status == 'located') ('forwarded', Icons.flight_land),
      if (r.status == 'located' || r.status == 'forwarded' || r.status == 'reported') ('arrived', Icons.local_airport),
      if (r.status == 'arrived' && deliver) ('out_for_delivery', Icons.local_shipping_outlined),
      if (r.status == 'arrived') ('ready_for_pickup', Icons.storefront_outlined),
      ('note', Icons.sticky_note_2_outlined),
      if (!r.handover) ('declared_lost', Icons.report_outlined),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final r = _report;
    return Scaffold(
      appBar: AppBar(
        title: Text(r?.ref ?? 'Baggage file'.tr),
        actions: [
          if (r != null)
            IconButton(
              tooltip: 'Chat with the passenger'.tr,
              icon: const Icon(Icons.chat_bubble_outline),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(reportId: r.id))),
            ),
          RefreshButton(onRefresh: _load),
          const SizedBox(width: 8),
        ],
      ),
      body: r == null
          ? (_error != null
                ? EmptyState(icon: Icons.error_outline, message: '$_error')
                : const Center(child: CircularProgressIndicator()))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(bagTypeIcon(r.bagType), color: p.primary, size: 28),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              bagTitle(r.bagType, r.color),
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                            ),
                          ),
                          BagStatusBadge(r.status),
                        ],
                      ),
                      const SizedBox(height: 8),
                      InfoRow(
                        icon: Icons.person_outline,
                        label: 'Passenger',
                        value: [r.passengerName, r.passengerEmail].whereType<String>().join(' · '),
                      ),
                      InfoRow(icon: Icons.flight, label: 'Flight', value: '${r.flight} · ${r.flightDate ?? ''}'),
                      InfoRow(
                        icon: Icons.confirmation_number_outlined,
                        label: 'Bag tags',
                        value: r.tagNumbers.isEmpty ? '—' : r.tagNumbers.join(', '),
                      ),
                      if (r.kind == 'damaged')
                        const InfoRow(icon: Icons.broken_image_outlined, label: 'Report', value: 'Damaged bag'),
                      if (r.brand?.isNotEmpty == true)
                        InfoRow(icon: Icons.sell_outlined, label: 'Brand', value: r.brand!),
                      if (r.nameOnTag?.isNotEmpty == true)
                        InfoRow(icon: Icons.badge_outlined, label: 'Name on the bag', value: r.nameOnTag!),
                      if (r.marks?.isNotEmpty == true)
                        InfoRow(icon: Icons.brush_outlined, label: 'Distinctive marks', value: r.marks!),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: p.warningFill, borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Eyebrow('Private · staff only', color: p.warning),
                      const SizedBox(height: 4),
                      Text('Contents: {text}'.trf({'text': r.contents?.isNotEmpty == true ? r.contents : '—'})),
                      Text(
                        r.deliveryMethod == 'deliver'
                            ? 'Deliver to: {address}'.trf({'address': r.deliveryAddress ?? '—'})
                            : 'Passenger picks it up at the desk'.tr,
                      ),
                      if (r.deliveryWindow?.isNotEmpty == true)
                        Text('When: {window}'.trf({'window': r.deliveryWindow})),
                      if (r.deliveryPhone?.isNotEmpty == true) Text('Phone: {phone}'.trf({'phone': r.deliveryPhone})),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (r.bag != null) ...[
                  Eyebrow('Matched bag', color: p.primary),
                  const SizedBox(height: 6),
                  BagCard(
                    bag: r.bag!,
                    trailing: const Icon(Icons.verified, color: Colors.green),
                  ),
                ] else if (r.suggestions.isNotEmpty) ...[
                  Eyebrow('Unclaimed bags that may be this one', color: p.primary),
                  const SizedBox(height: 6),
                  for (final s in r.suggestions)
                    BagCard(
                      bag: s.bag,
                      trailing: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ScoreBadge(s.score),
                          TextButton(
                            onPressed: _busy ? null : () => _run(() => Api.instance.linkBag(r.id, s.bag.id)),
                            child: Text('This is it'.tr),
                          ),
                        ],
                      ),
                    ),
                ],
                const SizedBox(height: 8),
                Eyebrow('Timeline', color: p.primary),
                const SizedBox(height: 8),
                BagTimeline(report: r, staff: true),
                if (_actions(r).isNotEmpty) ...[
                  Eyebrow('Update the file', color: p.primary),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (kind, icon) in _actions(r))
                        (kind == 'note' || kind == 'declared_lost' ? OutlinedButton.icon : FilledButton.tonalIcon)(
                          onPressed: _busy ? null : () => _event(kind),
                          icon: Icon(icon, size: 18),
                          label: Text(bagEventLabel(kind).$1.tr),
                        ),
                    ],
                  ),
                ],
                if (r.handover)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: NoteCard(
                      icon: Icons.qr_code_2,
                      title: 'Waiting for handover',
                      body: 'Scan the passenger\'s delivery code on the Pick-up tab (or type code {code}) to hand the bag over.'
                          .trf({'code': r.handoverCode ?? ''}),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Register an unclaimed bag: photo (AI fills type and colour), tag number, flight, where it's kept.
class RegisterBagScreen extends StatefulWidget {
  const RegisterBagScreen({super.key});

  @override
  State<RegisterBagScreen> createState() => _RegisterBagScreenState();
}

class _RegisterBagScreenState extends State<RegisterBagScreen> {
  final _tag = TextEditingController();
  final _flight = TextEditingController();
  final _name = TextEditingController();
  final _brand = TextEditingController();
  final _notes = TextEditingController();
  XFile? _photo;
  String? _bagType;
  String? _color;
  String? _zone;
  bool _saving = false;

  Future<void> _scan() async {
    final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const TagScannerPage()));
    if (code != null) setState(() => _tag.text = code);
  }

  Future<void> _save() async {
    if (_tag.text.trim().isEmpty && _photo == null && (_bagType == null || _color == null)) {
      showError(context, 'Add the tag number, a photo, or the bag type and colour');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await Api.instance.registerOnHandBag(
        airport: AppData.instance.airport.code,
        tagNumber: _tag.text.trim(),
        flight: _flight.text.trim(),
        bagType: _bagType,
        color: _color,
        brand: _brand.text.trim(),
        nameOnTag: _name.text.trim(),
        location: _zone,
        notes: _notes.text.trim(),
        image: _photo,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(r.matchedRef != null ? Icons.verified : Icons.luggage, size: 36),
          title: Text((r.matchedRef != null ? 'Matched!' : 'Bag registered').tr),
          content: Text(
            r.matchedRef != null
                ? 'The tag number matches file {ref}. The passenger has been told their bag is here.'.trf({
                    'ref': r.matchedRef!,
                  })
                : r.candidates > 0
                ? trn(
                    r.candidates,
                    '{n} open file looks similar. Check it in Files.',
                    '{n} open files look similar. Check them in Files.',
                  )
                : 'No open file matches yet. It will be matched as soon as the owner reports it.'.tr,
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text('OK'.tr))],
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final zones = AppData.instance.zones;
    return Scaffold(
      appBar: AppBar(title: Text('Register unclaimed bag'.tr)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SurfaceCard(
            onTap: () async {
              final f = await pickPhoto(context);
              if (f != null) setState(() => _photo = f);
            },
            child: _photo == null
                ? SizedBox(
                    height: 110,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.add_a_photo_outlined, size: 32),
                        const SizedBox(height: 6),
                        Text('Photo of the bag (AI fills type and colour)'.tr),
                      ],
                    ),
                  )
                : PhotoPreview(_photo!, height: 180),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tag,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'Bag tag number'.tr,
              hintText: 'e.g. 0281 123456'.tr,
              suffixIcon: isDesktop ? null : IconButton(icon: const Icon(Icons.barcode_reader), onPressed: _scan),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _flight,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(labelText: 'Flight'.tr, hintText: 'e.g. RO 644'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _name,
                  decoration: InputDecoration(labelText: 'Name on the bag'.tr),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text('Bag type'.tr, style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          BagTypeGrid(selected: _bagType, onChanged: (t) => setState(() => _bagType = t)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SelectField(
                  label: 'Colour',
                  icon: Icons.palette_outlined,
                  value: _color == null ? null : colorName(_color!),
                  hint: 'AI decides',
                  onTap: () async {
                    final c = await pickFromList(context, 'Colour', [
                      for (final c in colors) (c, colorName(c)),
                    ], selected: _color);
                    if (c != null) setState(() => _color = c);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: TextField(
                    controller: _brand,
                    decoration: InputDecoration(labelText: 'Brand'.tr),
                  ),
                ),
              ),
            ],
          ),
          SelectField(
            label: 'Kept at',
            icon: Icons.place_outlined,
            value: zones.where((z) => z.id == _zone).firstOrNull?.label,
            hint: 'Baggage service desk',
            onTap: () async {
              final z = await pickFromList(context, 'Kept at', [
                for (final z in zones) (z.id, z.label),
              ], selected: _zone);
              if (z != null) setState(() => _zone = z);
            },
          ),
          TextField(
            controller: _notes,
            maxLines: 2,
            decoration: InputDecoration(labelText: 'Notes'.tr),
          ),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Register and match', icon: Icons.luggage, busy: _saving, onPressed: _save),
        ],
      ),
    );
  }
}

/// After scanning a passenger's delivery code: check the bag and hand it over.
class BagHandoverScreen extends StatefulWidget {
  final String code;
  const BagHandoverScreen({super.key, required this.code});

  @override
  State<BagHandoverScreen> createState() => _BagHandoverScreenState();
}

class _BagHandoverScreenState extends State<BagHandoverScreen> {
  late final Future<BaggageReport> _report = Api.instance.scanBagHandover(widget.code);
  bool _busy = false;

  Future<void> _handOver() async {
    setState(() => _busy = true);
    try {
      await Api.instance.confirmBagHandover(widget.code);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bag handed over ✔ File closed'.tr)));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Hand over bag'.tr)),
      body: FutureBuilder<BaggageReport>(
        future: _report,
        builder: (context, snap) {
          if (snap.hasError) return EmptyState(icon: Icons.error_outline, message: '${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final r = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(r.ref, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  BagStatusBadge(r.status),
                ],
              ),
              const SizedBox(height: 8),
              if (r.bag != null) BagCard(bag: r.bag!),
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InfoRow(
                      icon: Icons.person_outline,
                      label: 'Passenger',
                      value: r.passengerName ?? r.passengerEmail ?? '—',
                    ),
                    InfoRow(icon: Icons.luggage, label: 'Bag', value: bagTitle(r.bagType, r.color)),
                    InfoRow(
                      icon: Icons.confirmation_number_outlined,
                      label: 'Bag tags',
                      value: r.tagNumbers.isEmpty ? '—' : r.tagNumbers.join(', '),
                    ),
                    if (r.nameOnTag?.isNotEmpty == true)
                      InfoRow(icon: Icons.badge_outlined, label: 'Name on the bag', value: r.nameOnTag!),
                  ],
                ),
              ),
              NoteCard(
                icon: Icons.verified_user_outlined,
                title: 'Check before handing over',
                body: "The name on the passenger's ID matches the file, and the tag on the bag matches the tag numbers above.",
              ),
              const SizedBox(height: 16),
              if (r.handover)
                FilledButton.icon(
                  onPressed: _busy ? null : _handOver,
                  icon: const Icon(Icons.check),
                  label: Text('Hand over bag'.tr),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: p.success),
                )
              else
                Text('This file is {status}.'.trf({'status': bagStatusLabel(r.status)}), textAlign: TextAlign.center),
            ],
          );
        },
      ),
    );
  }
}
