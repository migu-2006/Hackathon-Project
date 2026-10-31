import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../models.dart';
import '../../ui.dart';
import '../../widgets.dart';

/// Modul A: the operator photographs a found item; the AI pre-fills type, color and text.
class IntakeScreen extends StatefulWidget {
  final VoidCallback? onSaved;
  const IntakeScreen({super.key, this.onSaved});

  @override
  State<IntakeScreen> createState() => _IntakeScreenState();
}

class _IntakeScreenState extends State<IntakeScreen> {
  XFile? _photo;
  AiAnalysis? _ai;
  bool _analyzing = false;
  bool _saving = false;
  late String _airport = AppData.instance.airport.code;

  String? _category;
  String? _color;
  String? _zone;
  final _notes = TextEditingController();
  final _secret = TextEditingController();

  @override
  void initState() {
    super.initState();
    AppData.instance.addListener(_onDataChanged);
    if (AppData.instance.zones.isEmpty) AppData.instance.refresh();
  }

  @override
  void dispose() {
    AppData.instance.removeListener(_onDataChanged);
    super.dispose();
  }

  /// Zones come from the selected airport; switching airport clears the chosen zone.
  void _onDataChanged() {
    if (!mounted) return;
    setState(() {
      if (AppData.instance.airport.code != _airport) {
        _airport = AppData.instance.airport.code;
        _zone = null;
      }
    });
  }

  Future<void> _pickZone() async {
    final zones = AppData.instance.zones;
    final z = await pickFromList(context, 'Found at (${AppData.instance.airport.code})',
        [for (final z in zones) (z.id, z.label)], selected: _zone);
    if (z != null) setState(() => _zone = z);
  }

  Future<void> _takePhoto() async {
    final photo = await pickPhoto(context);
    if (photo == null) return;
    setState(() {
      _photo = photo;
      _ai = null;
      _analyzing = true;
    });
    try {
      final ai = await Api.instance.analyze(photo);
      setState(() {
        _ai = ai;
        _category = categories.contains(ai.category) ? ai.category : 'other';
        _color = colors.contains(ai.color) ? ai.color : null;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _save() async {
    if (_photo == null || _zone == null) {
      showError(context, 'A photo and a zone are required');
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await Api.instance.createFoundItem(
        image: _photo!,
        airport: _airport,
        location: _zone!,
        category: _category,
        color: _color,
        notes: _notes.text.trim(),
        secretDetail: _secret.text.trim(),
      );
      if (!mounted) return;
      widget.onSaved?.call();
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
          title: const Text('Item registered'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            ItemCard(item: r.item),
            const SizedBox(height: 8),
            Text(r.notified > 0
                ? '${r.notified} passenger(s) with a matching report were notified.'
                : 'No matching lost reports yet. Passengers will be matched automatically.'),
          ]),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Next item'))],
        ),
      );
      _reset();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _reset() => setState(() {
        _photo = null;
        _ai = null;
        _category = null;
        _color = null;
        _notes.clear();
        _secret.clear();
        // Keep the zone: operators usually register several items from the same area.
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (_photo == null)
            PhotoPlaceholder(onTap: _takePhoto, label: 'Photograph the found item')
          else
            Stack(children: [
              PhotoPreview(_photo!, height: 260),
              Positioned(
                right: 8,
                top: 8,
                child: IconButton.filledTonal(icon: const Icon(Icons.refresh), onPressed: _takePhoto),
              ),
            ]),
          const SizedBox(height: 16),
          if (_analyzing)
            const Card(
              child: ListTile(
                leading: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                title: Text('AI is analyzing the photo…'),
                subtitle: Text('Detecting object type, color and visible text'),
              ),
            ),
          if (_ai != null)
            Card(
              color: theme.colorScheme.primaryContainer,
              child: ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: Text('AI: ${_ai!.color} ${_ai!.label}'),
                subtitle: Text([
                  'Category: ${_ai!.category} (${(_ai!.confidence * 100).round()}%)',
                  if (_ai!.text.isNotEmpty) 'Text: "${_ai!.text}"',
                ].join('\n')),
                trailing: ColorDot(colorFromHex(_ai!.colorHex)),
              ),
            ),
          if (_photo != null && !_analyzing) ...[
            const SizedBox(height: 16),
            categoryDropdown(_category, (v) => setState(() => _category = v)),
            const SizedBox(height: 12),
            colorDropdown(_color, (v) => setState(() => _color = v)),
          ],
          const SizedBox(height: 12),
          SelectField(
            label: 'Found at (zone / gate) · ${AppData.instance.airport.short}',
            icon: Icons.place_outlined,
            value: _zone == null ? null : AppData.instance.zoneByName(_zone!)?.label,
            hint: 'Select a zone or gate',
            onTap: _pickZone,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Public notes (optional)', prefixIcon: Icon(Icons.notes)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _secret,
            decoration: const InputDecoration(
              labelText: 'Hidden verification detail (optional)',
              helperText: 'Not shown to passengers. E.g. contents, sticker, engraving.',
              prefixIcon: Icon(Icons.lock),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving || _analyzing || _photo == null ? null : _save,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: const Text('Register found item'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
        ]),
      ),
    );
  }
}
