import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../i18n.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../widgets.dart';
import 'route_editor.dart';

/// "I found an item": a passenger hands in something someone else lost. It goes straight into
/// the airport's inventory, is matched against open lost reports, and the staff desk gets an alert.
class HandInScreen extends StatefulWidget {
  const HandInScreen({super.key});

  @override
  State<HandInScreen> createState() => _HandInScreenState();
}

class _HandInScreenState extends State<HandInScreen> {
  final _description = TextEditingController();
  final _secret = TextEditingController();
  XFile? _photo;
  Place? _place;
  List<Place> _places = [];
  late String _airport = AppData.instance.airport.code;
  bool _saving = false;
  late Future<List<FoundItem>> _mine = _loadMine();

  // The list is a bonus under the form: if it can't load, the form still works.
  Future<List<FoundItem>> _loadMine() => Api.instance.myHandedIn().catchError((_) => <FoundItem>[]);

  @override
  void initState() {
    super.initState();
    AppData.instance.addListener(_onDataChanged);
    _loadPlaces();
  }

  @override
  void dispose() {
    AppData.instance.removeListener(_onDataChanged);
    _description.dispose();
    _secret.dispose();
    super.dispose();
  }

  /// Places differ per airport: switching airport clears the chosen one.
  void _onDataChanged() {
    if (!mounted || AppData.instance.airport.code == _airport) return;
    setState(() {
      _airport = AppData.instance.airport.code;
      _place = null;
      _places = [];
    });
    _loadPlaces();
  }

  Future<void> _loadPlaces() async {
    final code = _airport;
    try {
      final places = await AppData.instance.placesFor(code);
      if (mounted && code == _airport) setState(() => _places = places);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _pickPlace() async {
    if (_places.isEmpty) return;
    final pl = await pickPlace(context, _places, title: 'Where did you find it?');
    if (pl != null) setState(() => _place = pl);
  }

  Future<void> _submit() async {
    if (_photo == null) {
      showError(context, 'Take a photo of the item');
      return;
    }
    if (_place == null) {
      showError(context, 'Mark where you found the item');
      return;
    }
    if (_description.text.trim().length < 3) {
      showError(context, 'Describe the item');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await Api.instance.handInItem(
        image: _photo!,
        airport: _airport,
        place: _place!.id,
        description: _description.text.trim(),
        secretDetail: _secret.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _photo = null;
        _place = null;
        _description.clear();
        _secret.clear();
        _mine = _loadMine();
      });
      await _thanks(r.item);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _thanks(FoundItem item) {
    final airport = AppData.instance.airportByCode(item.airport);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.volunteer_activism, size: 36),
        title: Text('Thank you!'.tr),
        content: Text(
          '{item} is now in the inventory of {airport}, and the airport team has been alerted. Please leave the item at the {desk} or with any staff member.'
              .trf({'item': itemTitle(item.color, item.category), 'airport': airport.name, 'desk': airport.desk}),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text('OK'.tr))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    return Scaffold(
      appBar: rAppBar(context, 'I found an item'),
      body: PageBody(
        onRefresh: () async => setState(() => _mine = _loadMine()),
        children: [
          const PageHeader(
            title: 'Found something?',
            subtitle: "Help it get home. Send it to the airport's lost & found and we'll find its owner.",
          ),
          SelectField(
            label: 'Airport',
            icon: Icons.flight,
            value: '${data.airport.code} · ${data.airport.name}',
            onTap: () => pickAirport(context),
          ),
          Text('Photo of the item'.tr, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          _PhotoCard(photo: _photo, onChanged: (f) => setState(() => _photo = f)),
          const SizedBox(height: 12),
          SelectField(
            label: 'Where did you find it?',
            icon: _place == null ? Icons.place_outlined : placeIcon(_place!),
            value: _place == null ? null : [_place!.displayName, _place!.where].where((s) => s.isNotEmpty).join(' · '),
            hint: 'Pick an area, shop or café',
            onTap: _places.isEmpty ? null : _pickPlace,
          ),
          Text('Item description'.tr, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          TextField(
            controller: _description,
            maxLines: 3,
            maxLength: 500,
            decoration: InputDecoration(hintText: 'What is it? Colour, brand, size.\nE.g. Blue umbrella with a wooden handle.'.tr),
          ),
          Text('Hidden detail (optional)'.tr, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          TextField(
            controller: _secret,
            maxLength: 200,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.lock_outline, size: 18),
              hintText: 'Something only the owner would know'.tr,
            ),
          ),
          const NoteCard(
            icon: Icons.visibility_off_outlined,
            title: 'Only staff see the hidden detail',
            body: 'The owner has to describe it before staff hand the item over. Other passengers never see it, nor who found the item.',
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: 'Send to lost & found',
            icon: Icons.send_outlined,
            busy: _saving,
            onPressed: _submit,
          ),
          const SizedBox(height: 22),
          FutureBuilder<List<FoundItem>>(
            future: _mine,
            builder: (context, snap) {
              final items = snap.data ?? const <FoundItem>[];
              if (items.isEmpty) return const SizedBox.shrink();
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Eyebrow('Items you handed in', color: p.primary),
                const SizedBox(height: 8),
                for (final i in items)
                  ItemCard(
                    item: i,
                    footer: Align(
                      alignment: Alignment.centerLeft,
                      child: i.status == 'available'
                          ? const RBadge('Waiting for owner', icon: Icons.hourglass_empty, kind: BadgeKind.neutral)
                          : const RBadge('Returned', icon: Icons.check_circle, kind: BadgeKind.success),
                    ),
                  ),
              ]);
            },
          ),
        ],
      ),
    );
  }
}

class _PhotoCard extends StatelessWidget {
  final XFile? photo;
  final ValueChanged<XFile?> onChanged;
  const _PhotoCard({required this.photo, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Future<void> pick() async {
      final f = await pickPhoto(context);
      if (f != null) onChanged(f);
    }

    if (photo != null) {
      return Stack(children: [
        ClipRRect(borderRadius: BorderRadius.circular(14), child: PhotoPreview(photo!, height: 200)),
        Positioned(
          top: 8,
          right: 8,
          child: IconButton.filledTonal(
            tooltip: 'Retake photo'.tr,
            icon: const Icon(Icons.refresh),
            onPressed: pick,
          ),
        ),
      ]);
    }
    return SurfaceCard(
      onTap: pick,
      child: SizedBox(
        height: 140,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: p.tint,
            child: Icon(Icons.add_a_photo_outlined, color: p.primary, size: 26),
          ),
          const SizedBox(height: 10),
          Text('Take a photo of the item'.tr, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text('Our AI recognises the type and colour.'.tr, style: TextStyle(color: p.muted, fontSize: 12)),
        ]),
      ),
    );
  }
}
