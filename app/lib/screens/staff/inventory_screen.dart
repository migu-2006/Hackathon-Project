import 'package:flutter/material.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../i18n.dart';
import '../../models.dart';
import '../../ui.dart';
import '../../widgets.dart';
import '../passenger/map_screen.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => InventoryScreenState();
}

class InventoryScreenState extends State<InventoryScreen> {
  String _status = 'available';
  String? _category;
  late Future<List<FoundItem>> _items = _load();
  String? _highlight; // just registered: marked "New" at the top of the list

  Future<List<FoundItem>> _load() => Api.instance.foundItems(airport: AppData.instance.airport.code, status: _status, category: _category, staff: true);

  Future<void> refresh({String? highlight}) {
    setState(() {
      _highlight = highlight;
      if (highlight != null) _status = 'available';
      _items = _load();
    });
    return _items;
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 'available', label: Text('Available'.tr)),
              ButtonSegment(value: 'claimed', label: Text('Recovered'.tr)),
            ],
            selected: {_status},
            onSelectionChanged: (s) {
              _status = s.first;
              refresh();
            },
          ),
          const SizedBox(width: 12),
          Expanded(
            child: categoryDropdown(_category, (v) {
              _category = v;
              refresh();
            }, label: 'Filter'),
          ),
          if (_category != null)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _category = null;
                refresh();
              },
            ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async => refresh(),
          child: FutureBuilder<List<FoundItem>>(
            future: _items,
            builder: (context, snap) {
              if (snap.hasError) return EmptyState(icon: Icons.cloud_off, message: '${snap.error}');
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final items = snap.data!;
              if (items.isEmpty) return const EmptyState(icon: Icons.inventory_2, message: 'No items');
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                itemBuilder: (_, i) => ItemCard(
                  item: items[i],
                  trailing: items[i].id == _highlight
                      ? const RBadge('New', icon: Icons.check_circle, kind: BadgeKind.success)
                      : null,
                  footer: _MapButton(item: items[i]),
                ),
              );
            },
          ),
        ),
      ),
    ]);
  }
}

/// Opens the airport map zoomed on the zone where the item was found.
class _MapButton extends StatelessWidget {
  final FoundItem item;
  const _MapButton({required this.item});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          // Items registered with a free-text location have no zone to point at.
          onPressed: item.zoneId == null
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AirportMapScreen(airport: item.airport, focusZoneId: item.zoneId),
                  )),
          icon: const Icon(Icons.map_outlined, size: 18),
          label: Text((item.zoneId == null ? 'No map position for this location' : 'See location on map').tr),
        ),
      );
}
