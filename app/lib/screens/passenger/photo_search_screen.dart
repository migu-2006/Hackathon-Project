import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api.dart';
import '../../app_state.dart';
import '../../models.dart';
import '../../theme.dart';
import '../../ui.dart';
import '../../widgets.dart';
import 'item_details_screen.dart';

const _disclaimer = NoteCard(
  icon: Icons.shield_outlined,
  title: 'Similarity is not proof of ownership.',
  body: 'The airport team reviews every claim. Only approved claims get a pickup QR. '
      'Staff verify security-question answers before release.',
);

/// Reverse image search: the passenger uploads a photo of the lost item.
class PhotoSearchScreen extends StatefulWidget {
  const PhotoSearchScreen({super.key});

  @override
  State<PhotoSearchScreen> createState() => _PhotoSearchScreenState();
}

class _PhotoSearchScreenState extends State<PhotoSearchScreen> {
  XFile? _photo;
  bool _busy = false;

  Future<void> _choose() async {
    final f = await pickPhoto(context);
    if (f != null) setState(() => _photo = f);
  }

  Future<void> _search() async {
    if (_photo == null) {
      await _choose();
      if (_photo == null) return;
    }
    setState(() => _busy = true);
    try {
      final r = await Api.instance.visualSearch(_photo!, airport: AppData.instance.airport.code);
      if (!mounted) return;
      final changed = await Navigator.of(context).push<XFile>(
        MaterialPageRoute(builder: (_) => PhotoResultsScreen(photo: _photo!, query: r.query, matches: r.matches)),
      );
      if (changed != null) setState(() => _photo = changed);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final airport = AppData.instance.airport;
    return Scaffold(
      appBar: rAppBar(context, 'Search by photo'),
      body: PageBody(children: [
        const PageHeader(
          title: 'A familiar starting point.',
          subtitle: 'Use a photo you already have to look for visually similar found items.',
        ),
        SurfaceCard(
          padding: const EdgeInsets.all(8),
          child: Column(children: [
            _photo == null
                ? InkWell(
                    onTap: _choose,
                    child: Container(
                      height: 170,
                      decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(10)),
                      alignment: Alignment.center,
                      child: Icon(Icons.add_photo_alternate_outlined, size: 44, color: p.primary),
                    ),
                  )
                : ClipRRect(borderRadius: BorderRadius.circular(10), child: PhotoPreview(_photo!, height: 170)),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 10, 0, 2),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Your photo', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    Text(
                      _photo == null ? 'No photo selected' : '${_photo!.name} · Ready to search',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 11.5),
                    ),
                  ]),
                ),
                TextButton.icon(
                  onPressed: _choose,
                  icon: const Icon(Icons.photo_library_outlined, size: 16),
                  label: const Text('Choose photo', style: TextStyle(fontSize: 12.5)),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        const Text('For a clearer search', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 4),
        Text(
          'Choose a clear photo with one item in view. Show its shape and colour; avoid faces and personal documents. JPG or PNG, up to 10 MB.',
          style: TextStyle(color: p.muted, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Search airport', style: TextStyle(color: p.muted, fontSize: 11.5)),
              Text('${airport.short} Lost Property', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ]),
          ),
          FilterPill(label: airport.code, active: true),
        ]),
        const SizedBox(height: 14),
        PrimaryButton(label: 'Search similar items', icon: Icons.center_focus_strong, busy: _busy, onPressed: _search),
        Center(
          child: TextButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.search, size: 16),
            label: const Text('Use text search instead', style: TextStyle(fontSize: 12.5)),
          ),
        ),
        _disclaimer,
      ]),
    );
  }
}

class PhotoResultsScreen extends StatelessWidget {
  final XFile photo;
  final AiAnalysis query;
  final List<Match> matches;
  const PhotoResultsScreen({super.key, required this.photo, required this.query, required this.matches});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    final potential = data.potentialItemIds;
    return Scaffold(
      appBar: rAppBar(context, 'Photo search results'),
      body: PageBody(children: [
        const PageHeader(
          title: 'A closer look.',
          subtitle: 'Visually similar items safely held by the airport. These are possible matches only.',
        ),
        SurfaceCard(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            SizedBox(width: 48, height: 48, child: PhotoPreview(photo, height: 48)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Your photo', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                Text('${data.airport.short} · ${data.airport.code}', style: TextStyle(color: p.muted, fontSize: 11.5)),
              ]),
            ),
            TextButton(
              onPressed: () async {
                final f = await pickPhoto(context);
                if (f != null && context.mounted) Navigator.of(context).pop(f);
              },
              child: const Text('Change'),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilterPill(label: data.airport.code, active: true),
          FilterPill(label: capitalize(query.category), trailingIcon: null),
          FilterPill(label: capitalize(query.color), trailingIcon: null),
        ]),
        const SizedBox(height: 8),
        SectionTitle(
          '${matches.length} visually similar item${matches.length == 1 ? '' : 's'}',
          trailing: 'Most similar first',
        ),
        if (matches.isEmpty)
          const NoteCard(
            icon: Icons.search_off,
            title: 'Nothing similar yet',
            body: "Report your item and we'll notify you as soon as something similar is handed in.",
          ),
        for (final m in matches)
          FoundItemTile(
            item: m.item,
            potential: potential.contains(m.item.id) || m.score >= AppData.matchThreshold,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ItemDetailsScreen(item: m.item))),
          ),
        const SizedBox(height: 6),
        _disclaimer,
        Center(
          child: TextButton.icon(
            onPressed: () => Navigator.of(context)
              ..pop()
              ..pop(),
            icon: const Icon(Icons.search, size: 16),
            label: const Text('Use text search instead', style: TextStyle(fontSize: 12.5)),
          ),
        ),
      ]),
    );
  }
}
