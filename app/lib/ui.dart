import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'app_state.dart';
import 'glass.dart';
import 'i18n.dart';
import 'models.dart';
import 'screens/passenger/shell.dart';
import 'theme.dart';
import 'widgets.dart';

// ---------------------------------------------------------------- formatting

String fmtDate(DateTime d) => longDate(d);
String fmtDay(DateTime d) => shortDay(d);
String fmtDayYear(DateTime d) => '${shortDay(d)} ${d.year}';
String fmtTime(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String fmtDayTime(DateTime d) => '${fmtDay(d)} · ${fmtTime(d)}';

String fmtUpdated(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  if (day == today) return 'today, {time}'.trf({'time': fmtTime(d)});
  if (day == today.subtract(const Duration(days: 1))) return 'yesterday, {time}'.trf({'time': fmtTime(d)});
  return '${fmtDay(d)}, ${fmtTime(d)}';
}

/// "Black backpack", in the app language (the colour agrees with the noun in Romanian/Spanish).
String itemTitle(String? color, String category) => itemName(color, category);

const categoryGroups = {
  'Electronics': ['phone', 'laptop', 'headphones', 'camera', 'electronics'],
  'Bags & wallets': ['backpack', 'handbag', 'suitcase', 'wallet'],
  'Accessories': ['glasses', 'watch', 'jewelry', 'keys', 'umbrella'],
  'Clothing': ['clothing', 'shoes'],
  'Other': ['bottle', 'cup', 'book', 'toy', 'sports', 'other'],
};

String categoryLabel(String c) {
  for (final e in categoryGroups.entries) {
    if (e.value.contains(c)) return '${e.key.tr} · ${categoryName(c)}';
  }
  return categoryName(c);
}

// ---------------------------------------------------------------- app bar

/// App bar refresh: reloads the page's data and spins meanwhile (pull-to-refresh does the
/// same, but isn't discoverable with a mouse on the desk PC).
class RefreshButton extends StatefulWidget {
  final FutureOr<void> Function() onRefresh;
  const RefreshButton({super.key, required this.onRefresh});

  @override
  State<RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<RefreshButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      // Minimum spin so a fast reload still visibly happened.
      await Future.wait([Future.sync(widget.onRefresh), Future<void>.delayed(const Duration(milliseconds: 500))]);
    } catch (_) {
      // The page shows its own error state.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        // Breathing room before the next app bar button (account, map, new report...).
        padding: const EdgeInsets.only(right: 8),
        child: IconButton(
          style: glassIconStyle(context),
          tooltip: 'Refresh'.tr,
          onPressed: _busy ? null : _run,
          icon: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
        ),
      );
}

/// Back arrow (pops, or returns to Home on a tab root) + title + help.
PreferredSizeWidget rAppBar(BuildContext context, String title, {List<Widget> actions = const []}) {
  return AppBar(
    leading: IconButton(
      style: glassIconStyle(context),
      icon: const Icon(Icons.arrow_back),
      onPressed: () => Navigator.of(context).canPop() ? Navigator.of(context).pop() : AppShell.goTo(ShellTab.home),
    ),
    titleSpacing: 0,
    title: Text(title.tr),
    actions: [
      ...actions,
      if (actions.isNotEmpty) const SizedBox(width: 8),
      IconButton(
        style: glassIconStyle(context),
        icon: const Icon(Icons.help_outline),
        tooltip: 'Help'.tr,
        onPressed: () => AppShell.goTo(ShellTab.help),
      ),
      const SizedBox(width: 4),
    ],
  );
}

// ---------------------------------------------------------------- text blocks

class Eyebrow extends StatelessWidget {
  final String text;
  final Color? color;
  const Eyebrow(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) => Text(
        text.tr.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.1,
          color: color ?? Palette.of(context).muted,
        ),
      );
}

class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? eyebrow;
  const PageHeader({super.key, required this.title, this.subtitle, this.eyebrow});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (eyebrow != null) ...[Eyebrow(eyebrow!, color: p.primary), const SizedBox(height: 8)],
        Text(title.tr, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 26)),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle!.tr, style: TextStyle(color: p.muted, fontSize: 13.5, height: 1.4)),
        ],
      ]),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final String? trailing;
  final VoidCallback? onTrailing;
  final Widget? trailingWidget;
  const SectionTitle(this.text, {super.key, this.trailing, this.onTrailing, this.trailingWidget});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(children: [
        Expanded(child: Text(text.tr, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5))),
        ?trailingWidget,
        if (trailing != null)
          GestureDetector(
            onTap: onTrailing,
            child: Text(trailing!.tr, style: TextStyle(color: onTrailing == null ? p.muted : p.primary, fontSize: 12)),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- badges & cards

enum BadgeKind { info, warning, success, neutral }

class RBadge extends StatelessWidget {
  final String label;
  final IconData? icon;
  final BadgeKind kind;
  const RBadge(this.label, {super.key, this.icon, this.kind = BadgeKind.info});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (fg, bg) = switch (kind) {
      BadgeKind.info => (p.primary, p.tint),
      BadgeKind.warning => (p.warning, p.warningFill),
      BadgeKind.success => (p.success, p.success.withValues(alpha: 0.12)),
      BadgeKind.neutral => (p.muted, p.border.withValues(alpha: 0.5)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: fg), const SizedBox(width: 4)],
        Text(label.tr, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class PotentialMatchBadge extends StatelessWidget {
  final String label;
  const PotentialMatchBadge({super.key, this.label = 'Potential match'});

  @override
  Widget build(BuildContext context) => RBadge(label, icon: Icons.auto_awesome);
}

class SurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool highlighted;
  final Color? color;
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
    this.highlighted = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: color ?? p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: highlighted ? p.primary : p.border, width: highlighted ? 1.4 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      ),
    );
  }
}

/// Tinted note with an icon, e.g. "Your details stay private".
class NoteCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  const NoteCard({super.key, required this.icon, required this.title, this.body});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SurfaceCard(
      color: p.tint,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: p.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title.tr, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            if (body != null) ...[
              const SizedBox(height: 3),
              Text(body!.tr, style: TextStyle(color: p.muted, fontSize: 12, height: 1.4)),
            ],
          ]),
        ),
      ]),
    );
  }
}

class InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const InfoRow({super.key, required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: p.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label.tr, style: TextStyle(color: p.muted, fontSize: 11.5)),
            const SizedBox(height: 2),
            Text(value.tr, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13.5)),
          ]),
        ),
      ]),
    );
  }
}

class HelpLink extends StatelessWidget {
  final String text;
  const HelpLink({super.key, this.text = 'Need a hand? Contact the airport team'});

  @override
  Widget build(BuildContext context) => Center(
        child: TextButton.icon(
          onPressed: () => AppShell.goTo(ShellTab.help),
          icon: const Icon(Icons.support_agent, size: 16),
          label: Text(text.tr, style: const TextStyle(fontSize: 12.5)),
        ),
      );
}

/// Primary call-to-action with a trailing icon (arrow / shield / scan).
class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;
  const PrimaryButton({super.key, required this.label, this.icon = Icons.arrow_forward, this.onPressed, this.busy = false});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: busy ? null : onPressed,
          child: Row(children: [
            const SizedBox(width: 8),
            Expanded(child: Text(label.tr)),
            busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(icon, size: 20),
            const SizedBox(width: 4),
          ]),
        ),
      );
}

// ---------------------------------------------------------------- images & item tiles

class ItemImage extends StatelessWidget {
  final String? url;
  final String category;
  final double size;
  final double? height;
  final double radius;
  final bool hidden; // blurred preview: show a small "hidden" marker on top
  const ItemImage({
    super.key,
    this.url,
    required this.category,
    this.size = 64,
    this.height,
    this.radius = 10,
    this.hidden = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final fallback = Container(
      color: p.tint,
      alignment: Alignment.center,
      // size is infinite for full-width images (item details): scale the icon to the height then.
      child: Icon(categoryIcon(category), color: p.primary, size: (size.isFinite ? size : height ?? 64) * 0.4),
    );
    final image = url == null || url!.isEmpty
        ? fallback
        : Image.network(Api.instance.imageUrl(url!), fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
    final small = (height ?? size) < 100;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: height ?? size,
        child: !hidden
            ? image
            : Stack(fit: StackFit.expand, children: [
                image,
                Center(
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: small ? 5 : 10, vertical: small ? 5 : 6),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(20)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.visibility_off_outlined, color: Colors.white, size: small ? 14 : 16),
                      if (!small) ...[
                        const SizedBox(width: 6),
                        Text('Photo hidden'.tr, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ]),
                  ),
                ),
              ]),
      ),
    );
  }
}

/// Found-item row from the "Found items" / "Photo search results" screens.
class FoundItemTile extends StatelessWidget {
  final FoundItem item;
  final bool potential;
  final VoidCallback? onTap;
  const FoundItemTile({super.key, required this.item, this.potential = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final data = AppData.instance;
    return SurfaceCard(
      highlighted: potential,
      onTap: onTap,
      padding: const EdgeInsets.all(10),
      child: Row(children: [
        ItemImage(url: data.photoOf(item), category: item.category, size: 76, hidden: data.photoHidden(item)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            potential ? const PotentialMatchBadge() : const Eyebrow('Found item'),
            const SizedBox(height: 5),
            Text(itemTitle(item.color, item.category), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
            const SizedBox(height: 2),
            Text(data.zoneLabel(item.location), style: TextStyle(color: p.muted, fontSize: 12)),
            Text('Found {date}'.trf({'date': fmtDayYear(item.timestamp)}), style: TextStyle(color: p.muted, fontSize: 12)),
          ]),
        ),
        Align(alignment: Alignment.bottomRight, child: Icon(Icons.arrow_forward, size: 18, color: p.primary)),
      ]),
    );
  }
}

/// Field that looks like an input but opens a picker (airport, date, location, category).
class SelectField extends StatelessWidget {
  final String label;
  final IconData icon;
  final String? value;
  final String hint;
  final VoidCallback? onTap;
  const SelectField({super.key, required this.label, required this.icon, this.value, this.hint = 'Select', this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.tr, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
        const SizedBox(height: 6),
        Material(
          color: p.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: p.border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(children: [
                Icon(icon, size: 18, color: p.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(value ?? hint.tr, style: TextStyle(fontSize: 14, color: value == null ? p.muted : p.text)),
                ),
                Icon(Icons.keyboard_arrow_down, color: onTap == null ? p.border : p.muted),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class FilterPill extends StatelessWidget {
  final String label;
  final IconData? trailingIcon;
  final bool active;
  final VoidCallback? onTap;
  const FilterPill({super.key, required this.label, this.trailingIcon = Icons.keyboard_arrow_down, this.active = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Material(
      color: active ? p.tint : p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: active ? p.primary : p.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label.tr, style: TextStyle(fontSize: 12, color: active ? p.primary : p.text, fontWeight: FontWeight.w500)),
            if (trailingIcon != null) ...[const SizedBox(width: 4), Icon(trailingIcon, size: 16, color: active ? p.primary : p.muted)],
          ]),
        ),
      ),
    );
  }
}

/// Bottom-sheet list picker used by the select fields and filter pills.
Future<T?> pickFromList<T>(BuildContext context, String title, List<(T, String)> options, {T? selected}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
      child: ListView(shrinkWrap: true, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(title.tr, style: Theme.of(ctx).textTheme.titleMedium),
        ),
        for (final (value, label) in options)
          ListTile(
            title: Text(label.tr),
            trailing: value == selected ? Icon(Icons.check, color: Palette.of(ctx).primary) : null,
            onTap: () => Navigator.pop(ctx, value),
          ),
        const SizedBox(height: 16),
      ]),
    ),
  );
}

/// Airport switcher (Heathrow / Craiova ...). Changes the airport for browsing, reports, map and intake.
Future<void> pickAirport(BuildContext context) async {
  final data = AppData.instance;
  final code = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    useRootNavigator: true,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Choose airport'.tr, style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final a in data.airports)
            ListTile(
              leading: Container(
                width: 48,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8)),
                child: Text(a.code, style: TextStyle(color: p.primary, fontWeight: FontWeight.w800)),
              ),
              title: Text(a.name),
              subtitle: Text(a.country),
              trailing: a.code == data.airport.code ? Icon(Icons.check_circle, color: p.primary) : null,
              onTap: () => Navigator.pop(ctx, a.code),
            ),
          const SizedBox(height: 12),
        ]),
      );
    },
  );
  if (code != null) await data.setAirport(code);
}

/// Section wrapper: centered, max width for tablets/desktop, standard padding.
class PageBody extends StatelessWidget {
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  const PageBody({super.key, required this.children, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      physics: const AlwaysScrollableScrollPhysics(),
      children: children,
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list),
      ),
    );
  }
}
