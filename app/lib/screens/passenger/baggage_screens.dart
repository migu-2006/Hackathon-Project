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

/// "My checked bag didn't arrive": the passenger opens a file at the arrival airport
/// (the digital version of the property irregularity report filled in at the baggage desk).
class BaggageReportScreen extends StatefulWidget {
  const BaggageReportScreen({super.key});

  @override
  State<BaggageReportScreen> createState() => _BaggageReportScreenState();
}

class _BaggageReportScreenState extends State<BaggageReportScreen> {
  final _flight = TextEditingController();
  final _tag = TextEditingController();
  final _brand = TextEditingController();
  late final _name = TextEditingController(text: AppData.instance.user?.name ?? '');
  final _marks = TextEditingController();
  final _contents = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _window = TextEditingController();
  DateTime _flightDate = DateTime.now();
  final List<String> _tags = [];
  String _kind = 'delayed';
  String _delivery = 'deliver';
  String? _bagType;
  String? _color;
  XFile? _photo;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_flight, _tag, _brand, _name, _marks, _contents, _address, _phone, _window]) {
      c.dispose();
    }
    super.dispose();
  }

  void _addTag([String? value]) {
    final tag = (value ?? _tag.text).toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (tag.isEmpty) return;
    if (tag.length < 6 || tag.length > 10) {
      showError(context, 'A bag tag number has 6 to 10 letters or digits');
      return;
    }
    setState(() {
      if (!_tags.contains(tag)) _tags.add(tag);
      _tag.clear();
    });
  }

  Future<void> _scanTag() async {
    final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const TagScannerPage()));
    if (code != null) _addTag(code);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _flightDate,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now,
    );
    if (d != null) setState(() => _flightDate = d);
  }

  Future<void> _pickColor() async {
    final c = await pickFromList(context, 'Colour', [for (final c in colors) (c, colorName(c))], selected: _color);
    if (c != null) setState(() => _color = c);
  }

  Future<void> _submit() async {
    if (_tag.text.trim().isNotEmpty) _addTag();
    String? error;
    if (_flight.text.trim().length < 3) {
      error = 'Enter your flight number';
    } else if (_tags.isEmpty && (_bagType == null || _color == null)) {
      error = 'Add the bag tag number, or at least the bag type and colour';
    } else if (_delivery == 'deliver' && (_address.text.trim().isEmpty || _phone.text.trim().isEmpty)) {
      error = 'Add the delivery address and a phone number';
    }
    if (error != null) {
      showError(context, error);
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await Api.instance.createBaggageReport(
        airport: AppData.instance.airport.code,
        flight: _flight.text.trim(),
        flightDate: _flightDate,
        tagNumbers: _tags,
        kind: _kind,
        deliveryMethod: _delivery,
        bagType: _bagType,
        color: _color,
        brand: _brand.text.trim(),
        nameOnTag: _name.text.trim(),
        marks: _marks.text.trim(),
        contents: _contents.text.trim(),
        deliveryAddress: _delivery == 'deliver' ? _address.text.trim() : null,
        deliveryPhone: _phone.text.trim(),
        deliveryWindow: _window.text.trim(),
        image: _photo,
      );
      await AppData.instance.refreshBaggage();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(r.matchedBagId != null
            ? 'Good news: your bag is already at the baggage desk!'.tr
            : 'File {ref} opened. We will keep you posted on every step.'.trf({'ref': r.ref})),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text.tr, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
      );

  Widget _field(TextEditingController c, String hint, {IconData? icon, TextInputType? type, int lines = 1, bool caps = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          keyboardType: type,
          maxLines: lines,
          textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.sentences,
          decoration: InputDecoration(hintText: hint.tr, prefixIcon: icon == null ? null : Icon(icon, size: 18)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    return Scaffold(
      appBar: rAppBar(context, 'Checked bag report'),
      body: PageBody(children: [
        const PageHeader(
          title: "Your bag didn't arrive?",
          subtitle: "Most delayed bags are back with their owner within a day or two. Tell us about yours and we'll follow it for you.",
        ),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'delayed', icon: const Icon(Icons.schedule), label: Text('Missing'.tr)),
            ButtonSegment(value: 'damaged', icon: const Icon(Icons.broken_image_outlined), label: Text('Damaged'.tr)),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() => _kind = s.first),
        ),
        const SizedBox(height: 16),
        Eyebrow('Flight', color: p.primary),
        const SizedBox(height: 8),
        SelectField(
          label: 'Arrival airport',
          icon: Icons.flight_land,
          value: '${data.airport.code} · ${data.airport.name}',
          onTap: () => pickAirport(context).then((_) => setState(() {})),
        ),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _label('Flight number'),
              _field(_flight, 'e.g. RO 642', icon: Icons.flight, caps: true),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectField(label: 'Flight date', icon: Icons.calendar_today_outlined, value: fmtDay(_flightDate), onTap: _pickDate),
          ),
        ]),
        Eyebrow('Your bag', color: p.primary),
        const SizedBox(height: 8),
        _label('Bag tag number'),
        Text('The 10-digit number on the sticker the check-in desk stuck to your boarding pass.'.tr,
            style: TextStyle(color: p.muted, fontSize: 11.5)),
        const SizedBox(height: 6),
        TextField(
          controller: _tag,
          textCapitalization: TextCapitalization.characters,
          onSubmitted: (_) => _addTag(),
          decoration: InputDecoration(
            hintText: 'e.g. 0281 123456'.tr,
            prefixIcon: const Icon(Icons.confirmation_number_outlined, size: 18),
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              if (!isDesktop) IconButton(tooltip: 'Scan the bag tag'.tr, icon: const Icon(Icons.barcode_reader), onPressed: _scanTag),
              IconButton(tooltip: 'Add'.tr, icon: const Icon(Icons.add_circle_outline), onPressed: _addTag),
            ]),
          ),
        ),
        if (_tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in _tags)
                InputChip(
                  avatar: const Icon(Icons.luggage, size: 16),
                  label: Text(t, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                  onDeleted: () => setState(() => _tags.remove(t)),
                ),
            ]),
          ),
        const SizedBox(height: 14),
        _label('Bag type'),
        BagTypeGrid(selected: _bagType, onChanged: (t) => setState(() => _bagType = t)),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: SelectField(
              label: 'Colour',
              icon: Icons.palette_outlined,
              value: _color == null ? null : colorName(_color!),
              hint: 'Select',
              onTap: _pickColor,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_label('Brand'), _field(_brand, 'e.g. Samsonite')])),
        ]),
        _label('Name on the bag'),
        _field(_name, 'As written on the luggage label', icon: Icons.badge_outlined),
        _label('Distinctive marks'),
        _field(_marks, 'Ribbon on the handle, stickers, scratches…', lines: 2),
        _label('What is inside (private)'),
        _field(_contents, 'A few items, e.g. grey suit, camera charger. Only the baggage team sees this.', icon: Icons.lock_outline, lines: 2),
        _PhotoTile(
          photo: _photo,
          title: _kind == 'damaged' ? 'Photo of the damage' : 'Photo of your bag (optional)',
          onChanged: (f) => setState(() => _photo = f),
        ),
        const SizedBox(height: 16),
        Eyebrow('Getting it back', color: p.primary),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'deliver', icon: const Icon(Icons.local_shipping_outlined), label: Text('Deliver to me'.tr)),
            ButtonSegment(value: 'pickup', icon: const Icon(Icons.storefront_outlined), label: Text('Pick up at desk'.tr)),
          ],
          selected: {_delivery},
          onSelectionChanged: (s) => setState(() => _delivery = s.first),
        ),
        const SizedBox(height: 12),
        if (_delivery == 'deliver') ...[
          _label('Delivery address'),
          _field(_address, 'Hotel or home address, with the room number', icon: Icons.home_outlined, lines: 2),
          _label('When can we deliver?'),
          _field(_window, 'e.g. after 18:00, or any time', icon: Icons.schedule),
        ],
        _label('Phone number'),
        _field(_phone, 'So the driver or the desk can call you', icon: Icons.phone_outlined, type: TextInputType.phone),
        const NoteCard(
          icon: Icons.shield_outlined,
          title: 'Your address stays private',
          body: 'Only the baggage team and the driver who brings your bag see your address, phone and the contents of your bag.',
        ),
        const SizedBox(height: 14),
        PrimaryButton(label: 'Open baggage file', icon: Icons.luggage, busy: _saving, onPressed: _submit),
      ]),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  final XFile? photo;
  final String title;
  final ValueChanged<XFile?> onChanged;
  const _PhotoTile({required this.photo, required this.title, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SurfaceCard(
      padding: const EdgeInsets.all(10),
      onTap: () async {
        final f = await pickPhoto(context);
        if (f != null) onChanged(f);
      },
      child: Row(children: [
        photo == null
            ? Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.add_a_photo_outlined, color: p.primary, size: 20),
              )
            : SizedBox(width: 44, height: 44, child: PhotoPreview(photo!, height: 44)),
        const SizedBox(width: 12),
        Expanded(child: Text((photo == null ? title : 'Photo added').tr, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
        if (photo != null) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => onChanged(null)),
      ]),
    );
  }
}

/// A baggage file on My reports: status, timeline, delivery code and chat.
class BaggageCase extends StatelessWidget {
  final BaggageReport report;
  const BaggageCase({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final thread = AppData.instance.chatFor(report.id);
    final unread = thread?.unread ?? 0;
    final (nextTitle, nextBody) = switch (report.status) {
      'reported' => ("We're tracing your bag", 'We check where your tag was last scanned and every unclaimed bag. We will notify you at each step.'),
      'located' || 'forwarded' => ('Your bag is on its way', 'It will be sent to you as soon as it lands here.'),
      'arrived' => ('Your bag is here', report.deliveryMethod == 'deliver' ? 'We are arranging the delivery to your address.' : 'The desk is getting it ready for you.'),
      'out_for_delivery' => ('Your next step: meet the driver', 'Show your delivery code to the driver. They scan it to hand the bag over.'),
      'ready_for_pickup' => ('Your next step: collect it', 'Show your delivery code at the baggage service desk. Identity check required.'),
      'delivered' => ('All done', 'Thanks for your patience. Enjoy your trip!'),
      _ => ('Your bag was declared lost', 'We are sorry. Contact your airline to claim compensation, quoting your file number.'),
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
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(12)),
                  child: Icon(bagTypeIcon(report.bagType), color: p.primary, size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(bagTitle(report.bagType, report.color), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                    Text('File {ref} · {flight}'.trf({'ref': report.ref, 'flight': report.flight}),
                        style: TextStyle(color: p.muted, fontSize: 12)),
                    const SizedBox(height: 4),
                    Wrap(spacing: 6, children: [
                      const RBadge('Checked bag', icon: Icons.luggage, kind: BadgeKind.neutral),
                      BagStatusBadge(report.status),
                    ]),
                  ]),
                ),
              ]),
            ),
            const Divider(),
            Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 0), child: BagTimeline(report: report)),
          ]),
        ),
        NoteCard(icon: Icons.luggage, title: nextTitle, body: nextBody),
        const SizedBox(height: 6),
        if (report.handover && report.handoverCode != null)
          PrimaryButton(
            label: 'Show delivery code',
            icon: Icons.qr_code_2,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => BagPassScreen(report: report))),
          ),
        if (report.handover) const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(reportId: report.id))),
          child: Row(children: [
            Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: Icon(Icons.chat_bubble_outline, size: 18, color: p.primary)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(thread?.staffName != null
                  ? 'Chat with {name}'.trf({'name': thread!.staffName!})
                  : 'Chat with the baggage team'.tr),
            ),
            const Icon(Icons.north_east, size: 18),
          ]),
        ),
      ]),
    );
  }
}

/// The delivery code: the driver or the desk scans it to hand the bag over.
class BagPassScreen extends StatelessWidget {
  final BaggageReport report;
  const BagPassScreen({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final code = report.handoverCode ?? '';
    return Scaffold(
      appBar: rAppBar(context, 'Delivery code'),
      body: PageBody(children: [
        SurfaceCard(
          child: Column(children: [
            Text(bagTitle(report.bagType, report.color), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            Text('File {ref}'.trf({'ref': report.ref}), style: TextStyle(color: p.muted)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
              child: Image.network(
                Api.instance.bagQrUrl(report.id),
                width: 200,
                height: 200,
                errorBuilder: (_, _, _) => const SizedBox(width: 200, height: 200, child: Icon(Icons.qr_code_2, size: 120)),
              ),
            ),
            const SizedBox(height: 12),
            Text(code.length == 6 ? '${code.substring(0, 3)}-${code.substring(3)}' : code,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 4)),
            Text('Show this to the driver or at the desk'.tr, style: TextStyle(color: p.muted, fontSize: 12)),
          ]),
        ),
        const SizedBox(height: 12),
        SurfaceCard(
          child: Column(children: [
            InfoRow(
              icon: report.deliveryMethod == 'deliver' ? Icons.local_shipping_outlined : Icons.storefront_outlined,
              label: report.deliveryMethod == 'deliver' ? 'Delivery to' : 'Pick up at',
              value: report.deliveryMethod == 'deliver'
                  ? report.deliveryAddress ?? ''
                  : '${AppData.instance.airportByCode(report.airport).short} · ${'Baggage service desk'.tr}',
            ),
            if (report.deliveryWindow?.isNotEmpty == true)
              InfoRow(icon: Icons.schedule, label: 'When', value: report.deliveryWindow!),
            InfoRow(icon: Icons.confirmation_number_outlined, label: 'Bag tags', value: report.tagNumbers.join(', ')),
          ]),
        ),
      ]),
    );
  }
}
