import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../i18n.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../models.dart';
import '../../widgets.dart';
import 'route_editor.dart';

/// "What did you lose?" — the lost-item report. The backend auto-matches it immediately and
/// again whenever staff register a new item.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _description = TextEditingController();
  DateTime _travelDate = DateTime.now();
  List<Place> _route = [];
  List<Place> _places = [];
  String? _category;
  XFile? _photo;
  bool _saving = false;

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _travelDate,
      firstDate: now.subtract(const Duration(days: 90)),
      lastDate: now,
    );
    if (d != null) setState(() => _travelDate = d);
  }

  @override
  void initState() {
    super.initState();
    _loadPlaces();
  }

  Future<void> _loadPlaces() async {
    final code = AppData.instance.airport.code;
    try {
      final places = await AppData.instance.placesFor(code);
      if (mounted && AppData.instance.airport.code == code) setState(() => _places = places);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _pickCategory() async {
    final c = await pickFromList(
      context,
      'Item category',
      [for (final e in categoryGroups.entries) for (final c in e.value) (c, categoryLabel(c))],
      selected: _category,
    );
    if (c != null) setState(() => _category = c);
  }

  Future<void> _submit() async {
    if (_category == null) {
      showError(context, 'Choose an item category');
      return;
    }
    if (_route.isEmpty) {
      showError(context, 'Add at least one place you went through in the airport');
      return;
    }
    setState(() => _saving = true);
    try {
      final data = AppData.instance;
      final r = await Api.instance.createLostReport(
        userId: data.userId,
        airport: data.airport.code,
        description: _description.text.trim(),
        category: _category,
        route: [for (final s in _route) s.id],
        travelDate: _travelDate,
        image: _photo,
      );
      await data.refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(r.matches.isEmpty
            ? "Report submitted. We'll notify you when there's a potential match.".tr
            : trn(r.matches.length, 'Good news: {n} potential match already found!',
                'Good news: {n} potential matches already found!')),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    return Scaffold(
      appBar: rAppBar(context, 'Report a lost item'),
      body: PageBody(children: [
        const PageHeader(
          title: 'What did you lose?',
          subtitle: 'Share a few details so the airport team can look for your item.',
        ),
        Row(children: [
          Expanded(child: Eyebrow('Item & journey', color: p.primary)),
          Text('Category and route required'.tr, style: TextStyle(color: p.muted, fontSize: 11)),
        ]),
        const SizedBox(height: 10),
        SelectField(
          label: 'Airport',
          icon: Icons.flight,
          value: '${data.airport.code} · ${data.airport.name}',
          onTap: () async {
            final before = data.airport.code;
            await pickAirport(context);
            if (data.airport.code != before) {
              setState(() {
                _route = []; // places differ per airport
                _places = [];
              });
              _loadPlaces();
            }
          },
        ),
        SelectField(label: 'Travel date', icon: Icons.calendar_today_outlined, value: fmtDate(_travelDate), onTap: _pickDate),
        RouteEditor(stops: _route, places: _places, onChanged: (r) => setState(() => _route = r)),
        SelectField(
          label: 'Item category',
          icon: Icons.headphones_outlined,
          value: _category == null ? null : categoryLabel(_category!),
          hint: 'Select a category',
          onTap: _pickCategory,
        ),
        Text('Item description'.tr, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
        const SizedBox(height: 6),
        TextField(
          controller: _description,
          maxLines: 4,
          maxLength: 500,
          decoration: InputDecoration(
            hintText: 'Colour, brand, size, anything distinctive.\nE.g. Black over-ear wireless headphones.'.tr,
          ),
        ),
        _PhotoRow(photo: _photo, onChanged: (f) => setState(() => _photo = f)),
        const SizedBox(height: 6),
        const NoteCard(
          icon: Icons.shield_outlined,
          title: 'Your details stay private',
          body: "Don't add passport, payment or serial numbers here. Unique details are checked securely later.",
        ),
        const SizedBox(height: 14),
        PrimaryButton(label: 'Submit lost-item report', busy: _saving, onPressed: _submit),
        const SizedBox(height: 10),
        Center(
          child: Text("We'll notify you when there's a potential match.".tr, style: TextStyle(color: p.muted, fontSize: 12)),
        ),
      ]),
    );
  }
}

class _PhotoRow extends StatelessWidget {
  final XFile? photo;
  final ValueChanged<XFile?> onChanged;
  const _PhotoRow({required this.photo, required this.onChanged});

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
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((photo == null ? 'Add a photo (optional)' : 'Photo added').tr,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            Text('An older picture of the item improves matching.'.tr, style: TextStyle(color: p.muted, fontSize: 11.5)),
          ]),
        ),
        if (photo != null) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => onChanged(null)),
      ]),
    );
  }
}
