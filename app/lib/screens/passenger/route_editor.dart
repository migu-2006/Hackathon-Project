import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../models.dart';
import '../../poi.dart';
import '../../theme.dart';

/// The passenger's route through the airport for a lost report: one bubble per area or shop
/// they passed, in order, and a "+" bubble to add the next one. Staff only look for the item
/// in these areas, and Find items only lists what was found along the route.
class RouteEditor extends StatelessWidget {
  final List<Place> stops;
  final List<Place> places; // everything the passenger can pick at this airport (empty while loading)
  final ValueChanged<List<Place>> onChanged;
  const RouteEditor({super.key, required this.stops, required this.places, required this.onChanged});

  Future<void> _add(BuildContext context) async {
    final picked = await pickPlace(context, places, exclude: {for (final s in stops) s.id});
    if (picked != null) onChanged([...stops, picked]);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Your route in the airport'.tr, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text(
          'Add every area, shop or café you went through, in order. We only look for your item along this route.'.tr,
          style: TextStyle(color: p.muted, fontSize: 11.5, height: 1.35),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final (i, s) in stops.indexed) ...[
              _StopBubble(
                place: s,
                step: i + 1,
                onRemove: () => onChanged([...stops]..removeAt(i)),
              ),
              Icon(Icons.arrow_forward, size: 16, color: p.muted),
            ],
            _AddBubble(
              label: stops.isEmpty ? 'Add the first place' : 'Add a place',
              onTap: places.isEmpty ? null : () => _add(context),
            ),
          ],
        ),
      ]),
    );
  }
}

IconData placeIcon(Place place) =>
    place.kind == 'area' ? Icons.place_outlined : poiStyle(place.type, place.poiKind ?? '').icon;

class _StopBubble extends StatelessWidget {
  final Place place;
  final int step;
  final VoidCallback onRemove;
  const _StopBubble({required this.place, required this.step, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.fromLTRB(6, 5, 4, 5),
      decoration: BoxDecoration(
        color: p.tint,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.primary.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        CircleAvatar(
          radius: 11,
          backgroundColor: p.primary,
          child: Text('$step', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 6),
        Icon(placeIcon(place), size: 16, color: p.primary),
        const SizedBox(width: 4),
        Flexible(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(place.displayName, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: p.text)),
            Text(place.where, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, color: p.muted)),
          ]),
        ),
        InkWell(
          onTap: onRemove,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.close, size: 16, color: p.muted, semanticLabel: 'Remove'.tr),
          ),
        ),
      ]),
    );
  }
}

class _AddBubble extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _AddBubble({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Material(
      color: p.surface,
      shape: StadiumBorder(side: BorderSide(color: p.primary)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add, size: 18, color: onTap == null ? p.muted : p.primary),
            const SizedBox(width: 4),
            Text(label.tr, style: TextStyle(color: onTap == null ? p.muted : p.primary, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

/// Searchable list of the airport's areas and shops / services.
Future<Place?> pickPlace(BuildContext context, List<Place> places,
    {Set<String> exclude = const {}, String title = 'Where did you go?'}) {
  return showModalBottomSheet<Place>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => _PlacePicker(title: title, places: [for (final pl in places) if (!exclude.contains(pl.id)) pl]),
  );
}

class _PlacePicker extends StatefulWidget {
  final String title;
  final List<Place> places;
  const _PlacePicker({required this.title, required this.places});

  @override
  State<_PlacePicker> createState() => _PlacePickerState();
}

class _PlacePickerState extends State<_PlacePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final words = _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    bool hit(Place pl) {
      final hay = '${pl.label} ${pl.displayName} ${pl.where} ${pl.type}'.toLowerCase();
      return words.every(hay.contains);
    }

    final areas = widget.places.where((pl) => pl.kind == 'area' && hit(pl)).toList();
    final pois = widget.places.where((pl) => pl.kind != 'area' && hit(pl)).toList();
    Widget tile(Place pl) => ListTile(
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: p.tint,
            child: Icon(placeIcon(pl), size: 18, color: p.primary),
          ),
          title: Text(pl.displayName),
          subtitle: Text(pl.where, style: TextStyle(color: p.muted, fontSize: 12)),
          onTap: () => Navigator.pop(context, pl),
        );
    Widget header(String text, int n) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Text('${text.tr} · $n', style: TextStyle(color: p.primary, fontWeight: FontWeight.w700, fontSize: 12)),
        );

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title.tr, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              autofocus: false,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Search gates, areas, shops, cafés…'.tr),
            ),
          ]),
        ),
        Expanded(
          child: ListView(children: [
            if (areas.isNotEmpty) header('Areas', areas.length),
            for (final pl in areas) tile(pl),
            if (pois.isNotEmpty) header('Shops, cafés & services', pois.length),
            for (final pl in pois) tile(pl),
            if (areas.isEmpty && pois.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('No place matches your search.'.tr, textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
              ),
            const SizedBox(height: 16),
          ]),
        ),
      ]),
    );
  }
}
