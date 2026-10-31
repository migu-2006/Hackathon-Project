import 'package:flutter/material.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../models.dart';
import '../../widgets.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => InventoryScreenState();
}

class InventoryScreenState extends State<InventoryScreen> {
  String _status = 'available';
  String? _category;
  late Future<List<FoundItem>> _items = _load();

  Future<List<FoundItem>> _load() => Api.instance.foundItems(airport: AppData.instance.airport.code, status: _status, category: _category);

  void refresh() => setState(() => _items = _load());

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'available', label: Text('Available')),
              ButtonSegment(value: 'claimed', label: Text('Recovered')),
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
                itemBuilder: (_, i) => ItemCard(item: items[i]),
              );
            },
          ),
        ),
      ),
    ]);
  }
}
