import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'models.dart';

Color colorFromHex(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x888888;
  return Color(0xFF000000 | v);
}

const _namedColors = {
  'black': Color(0xFF202020), 'white': Color(0xFFF0F0F0), 'gray': Color(0xFF808080),
  'red': Color(0xFFC81E1E), 'orange': Color(0xFFF08C14), 'yellow': Color(0xFFF0DC28),
  'green': Color(0xFF28A03C), 'blue': Color(0xFF1E46C8), 'navy': Color(0xFF141E5A),
  'purple': Color(0xFF7832A0), 'pink': Color(0xFFF082B4), 'brown': Color(0xFF784B28),
  'beige': Color(0xFFD7C3A0),
};

Color namedColor(String? name) => _namedColors[name] ?? Colors.grey;

const categoryIcons = {
  'backpack': Icons.backpack, 'handbag': Icons.shopping_bag, 'suitcase': Icons.luggage,
  'wallet': Icons.account_balance_wallet, 'phone': Icons.smartphone, 'laptop': Icons.laptop,
  'electronics': Icons.devices_other, 'headphones': Icons.headphones, 'camera': Icons.photo_camera,
  'glasses': Icons.visibility, 'watch': Icons.watch, 'jewelry': Icons.diamond, 'keys': Icons.key,
  'clothing': Icons.checkroom, 'shoes': Icons.directions_walk, 'umbrella': Icons.beach_access,
  'bottle': Icons.water_drop, 'cup': Icons.coffee, 'book': Icons.menu_book, 'toy': Icons.toys,
  'sports': Icons.sports_tennis,
};

IconData categoryIcon(String category) => categoryIcons[category] ?? Icons.help_outline;

String capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('$error'),
    backgroundColor: Theme.of(context).colorScheme.error,
  ));
}

/// Phones have a camera + QR scanner; desktop (Windows/macOS/Linux) works with files and typed codes.
bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Lets the user choose camera or gallery (web: browser file picker / webcam; desktop: file dialog).
Future<XFile?> pickPhoto(BuildContext context) async {
  if (isDesktop) {
    return ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
  }
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Wrap(children: [
        ListTile(
          leading: const Icon(Icons.photo_camera),
          title: const Text('Take a photo'),
          onTap: () => Navigator.pop(ctx, ImageSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library),
          title: Text(kIsWeb ? 'Upload a file' : 'Choose from gallery'),
          onTap: () => Navigator.pop(ctx, ImageSource.gallery),
        ),
      ]),
    ),
  );
  if (source == null) return null;
  return ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 85);
}

/// Shows a picked photo; works on web (bytes) and mobile.
class PhotoPreview extends StatelessWidget {
  final XFile file;
  final double height;
  const PhotoPreview(this.file, {super.key, this.height = 220});

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
        future: file.readAsBytes(),
        builder: (_, snap) => ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: snap.hasData
                ? Image.memory(snap.data!, fit: BoxFit.cover)
                : const ColoredBox(color: Colors.black12),
          ),
        ),
      );
}

class PhotoPlaceholder extends StatelessWidget {
  final VoidCallback onTap;
  final String label;
  const PhotoPlaceholder({super.key, required this.onTap, this.label = 'Add a photo'});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 180,
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.4), width: 2),
        ),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add_a_photo, size: 48, color: scheme.primary),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class ItemThumb extends StatelessWidget {
  final FoundItem item;
  final double size;
  const ItemThumb(this.item, {super.key, this.size = 64});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: size,
          height: size,
          child: item.imageUrl.isEmpty
              ? Icon(categoryIcon(item.category))
              : Image.network(Api.instance.imageUrl(item.imageUrl), fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Icon(categoryIcon(item.category))),
        ),
      );
}

class ColorDot extends StatelessWidget {
  final Color color;
  const ColorDot(this.color, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.black26)),
      );
}

class ItemCard extends StatelessWidget {
  final FoundItem item;
  final double? score;
  final Widget? trailing;
  final VoidCallback? onTap;
  const ItemCard({super.key, required this.item, this.score, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            ItemThumb(item),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(categoryIcon(item.category), size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(capitalize(item.category),
                        style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  ColorDot(namedColor(item.color)),
                  const SizedBox(width: 4),
                  Flexible(child: Text(item.color, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.place, size: 14),
                  const SizedBox(width: 2),
                  Flexible(child: Text(item.location, overflow: TextOverflow.ellipsis)),
                  Flexible(
                    child: Text('  •  ${timeAgo(item.timestamp)}',
                        style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                  ),
                ]),
                if (item.text.isNotEmpty)
                  Text('Text: "${item.text}"', style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (score != null) ScoreBadge(score!),
            ?trailing,
          ]),
        ),
      ),
    );
  }
}

class ScoreBadge extends StatelessWidget {
  final double score;
  const ScoreBadge(this.score, {super.key});

  @override
  Widget build(BuildContext context) {
    final color = score >= 0.75 ? Colors.green : score >= 0.5 ? Colors.orange : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
      child: Text('${(score * 100).round()}%', style: TextStyle(color: color.shade800, fontWeight: FontWeight.bold)),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const EmptyState({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 64, color: Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).disabledColor)),
          ]),
        ),
      );
}

DropdownButtonFormField<String> categoryDropdown(String? value, ValueChanged<String?> onChanged, {String label = 'Category'}) =>
    DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.category)),
      items: [
        for (final c in categories)
          DropdownMenuItem(value: c, child: Row(children: [Icon(categoryIcon(c), size: 18), const SizedBox(width: 8), Text(capitalize(c))])),
      ],
      onChanged: onChanged,
    );

DropdownButtonFormField<String> colorDropdown(String? value, ValueChanged<String?> onChanged) =>
    DropdownButtonFormField<String>(
      initialValue: value,
      decoration: const InputDecoration(labelText: 'Color', prefixIcon: Icon(Icons.palette)),
      items: [
        for (final c in colors)
          DropdownMenuItem(value: c, child: Row(children: [ColorDot(namedColor(c)), const SizedBox(width: 8), Text(capitalize(c))])),
      ],
      onChanged: onChanged,
    );

DropdownButtonFormField<String> zoneDropdown(List<Zone> zones, String? value, ValueChanged<String?> onChanged,
        {String label = 'Zone / Gate'}) =>
    DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.place)),
      items: [for (final z in zones) DropdownMenuItem(value: z.id, child: Text(z.label))],
      onChanged: onChanged,
    );
