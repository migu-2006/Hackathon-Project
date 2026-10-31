import 'package:flutter/material.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../glass.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../widgets.dart';
import 'item_details_screen.dart';
import 'map_screen.dart';
import 'photo_search_screen.dart';

/// "A place to start." — browse items held by the airport.
class FoundItemsScreen extends StatefulWidget {
  const FoundItemsScreen({super.key});

  @override
  State<FoundItemsScreen> createState() => _FoundItemsScreenState();
}

class _FoundItemsScreenState extends State<FoundItemsScreen> {
  final _search = TextEditingController();
  late String _airport = AppData.instance.airport.code;
  late Future<List<FoundItem>> _items = Api.instance.foundItems(airport: _airport);
  DateTimeRange? _dates;
  String? _category;
  String? _terminal;
  bool _newestFirst = true;

  @override
  void initState() {
    super.initState();
    AppData.instance.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    AppData.instance.removeListener(_onDataChanged);
    super.dispose();
  }

  /// Reload the list when the passenger switches airport.
  void _onDataChanged() {
    final code = AppData.instance.airport.code;
    if (code == _airport || !mounted) return;
    setState(() {
      _airport = code;
      _terminal = null;
      _items = Api.instance.foundItems(airport: code);
    });
  }

  Future<void> _reload() async {
    setState(() {
      _items = Api.instance.foundItems(airport: _airport);
    });
    await Future.wait([_items, AppData.instance.refresh()]);
  }

  List<FoundItem> _filter(List<FoundItem> items) {
    final data = AppData.instance;
    final q = _search.text.trim().toLowerCase();
    final out = items.where((i) {
      if (_category != null && i.category != _category) return false;
      if (_terminal != null && data.zoneByName(i.location)?.terminal != _terminal) return false;
      if (_dates != null) {
        final d = DateTime(i.timestamp.year, i.timestamp.month, i.timestamp.day);
        if (d.isBefore(_dates!.start) || d.isAfter(_dates!.end)) return false;
      }
      if (q.isNotEmpty) {
        final hay = '${i.category} ${i.label} ${i.color} ${i.text} ${i.notes ?? ''} ${data.zoneLabel(i.location)}'.toLowerCase();
        if (!q.split(RegExp(r'\s+')).every(hay.contains)) return false;
      }
      return true;
    }).toList();
    out.sort((a, b) => _newestFirst ? b.timestamp.compareTo(a.timestamp) : a.timestamp.compareTo(b.timestamp));
    return out;
  }

  int get _activeFilters => [_dates, _category, _terminal].where((f) => f != null).length;

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 90)),
      lastDate: now,
      initialDateRange: _dates,
    );
    setState(() => _dates = r);
  }

  Future<void> _pickCategory() async {
    final c = await pickFromList<String>(
      context,
      'Category',
      [('', 'All categories'), for (final c in categories) (c, capitalize(c))],
      selected: _category ?? '',
    );
    if (c != null) setState(() => _category = c.isEmpty ? null : c);
  }

  Future<void> _pickTerminal() async {
    final terminals = {for (final z in AppData.instance.zones) z.terminal}.toList()..sort();
    final t = await pickFromList<String>(
      context,
      'Terminal',
      [('', 'All terminals'), for (final t in terminals) (t, t)],
      selected: _terminal ?? '',
    );
    if (t != null) setState(() => _terminal = t.isEmpty ? null : t);
  }

  /// Reverse image search; matches it finds show their clear photo here afterwards.
  Future<void> _photoSearch() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PhotoSearchScreen()));
    if (mounted) setState(() {});
  }

  void _clearFilters() => setState(() {
        _dates = null;
        _category = null;
        _terminal = null;
      });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    return Scaffold(
      appBar: rAppBar(context, 'Found items', actions: [
        RefreshButton(onRefresh: _reload),
        IconButton(
          style: glassIconStyle(context),
          icon: const Icon(Icons.map_outlined),
          tooltip: 'Terminal map',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AirportMapScreen())),
        ),
      ]),
      body: FutureBuilder<List<FoundItem>>(
        future: _items,
        builder: (context, snap) {
          final items = snap.hasData ? _filter(snap.data!) : <FoundItem>[];
          final potential = data.potentialItemIds;
          return PageBody(onRefresh: _reload, children: [
            const PageHeader(title: 'A place to start.', subtitle: 'Browse items safely held by the airport.'),
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search by item or category',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: IconButton(
                  icon: Icon(Icons.photo_camera_outlined, color: p.primary),
                  tooltip: 'Search by photo',
                  onPressed: _photoSearch,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilterPill(label: data.airport.code, active: true, onTap: () => pickAirport(context)),
              FilterPill(
                label: _dates == null ? 'Any date' : '${fmtDay(_dates!.start)}–${fmtDay(_dates!.end)}',
                active: _dates != null,
                onTap: _pickDates,
              ),
              FilterPill(
                label: _activeFilters == 0 ? 'Filters' : 'Filters · $_activeFilters',
                trailingIcon: _activeFilters == 0 ? Icons.tune : Icons.close,
                active: _activeFilters > 0,
                onTap: _activeFilters == 0 ? _pickCategory : _clearFilters,
              ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilterPill(label: _category == null ? 'All categories' : capitalize(_category!), active: _category != null, onTap: _pickCategory),
              FilterPill(label: _terminal ?? 'All terminals', active: _terminal != null, onTap: _pickTerminal),
            ]),
            const SizedBox(height: 10),
            SectionTitle(
              snap.hasData ? '${items.length} items found' : 'Loading items…',
              trailingWidget: GestureDetector(
                onTap: () => setState(() => _newestFirst = !_newestFirst),
                child: Row(children: [
                  Text(_newestFirst ? 'Newest first ' : 'Oldest first ', style: TextStyle(color: p.muted, fontSize: 12)),
                  Icon(Icons.sort, size: 16, color: p.muted),
                ]),
              ),
            ),
            if (snap.hasError) NoteCard(icon: Icons.cloud_off, title: "Can't load items", body: '${snap.error}'),
            if (!snap.hasData && !snap.hasError)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            if (items.any(data.photoHidden))
              SurfaceCard(
                color: p.tint,
                onTap: _photoSearch,
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Icon(Icons.visibility_off_outlined, size: 18, color: p.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Photos are blurred to protect owners. Search with a photo of your item to see clear pictures of similar ones.',
                      style: TextStyle(fontSize: 12.5, height: 1.35),
                    ),
                  ),
                  Icon(Icons.photo_camera_outlined, size: 18, color: p.primary),
                ]),
              ),
            if (snap.hasData && items.isEmpty)
              const NoteCard(icon: Icons.search_off, title: 'No items match', body: 'Try fewer filters, or report your item so we can notify you.'),
            for (final item in items)
              FoundItemTile(
                item: item,
                potential: potential.contains(item.id),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ItemDetailsScreen(item: item)));
                  if (mounted) setState(() {});
                },
              ),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.verified_user_outlined, size: 15, color: p.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Identifying details are hidden. A potential match does not confirm ownership.',
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
              ),
            ]),
          ]);
        },
      ),
    );
  }
}
