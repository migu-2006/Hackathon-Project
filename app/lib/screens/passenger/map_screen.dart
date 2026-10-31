import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../api.dart';
import '../../models.dart';
import '../../poi.dart';
import '../../theme.dart';
import '../../ui.dart';
import 'item_details_screen.dart';

/// Interactive airport plan (OpenStreetMap data) with found items pinned on their zones.
class AirportMapScreen extends StatelessWidget {
  final String? airport; // defaults to the selected airport
  final String? focusZoneId;
  const AirportMapScreen({super.key, this.airport, this.focusZoneId});

  @override
  Widget build(BuildContext context) {
    final data = AppData.instance;
    return ListenableBuilder(
      listenable: data,
      builder: (context, _) {
        final code = airport ?? data.airport.code;
        return Scaffold(
          appBar: rAppBar(context, '${data.airportByCode(code).short} map'),
          body: AirportMapView(airport: code, focusZoneId: focusZoneId),
        );
      },
    );
  }
}

class AirportMapView extends StatefulWidget {
  final String airport;
  final String? focusZoneId;
  const AirportMapView({super.key, required this.airport, this.focusZoneId});

  @override
  State<AirportMapView> createState() => _AirportMapViewState();
}

class _AirportMapViewState extends State<AirportMapView> with SingleTickerProviderStateMixin {
  late Future<(AirportMap, List<Zone>)> _load = _fetch();
  final _transform = TransformationController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  Animation<Matrix4>? _tween;
  String? _level;
  String? _terminal;
  Size _viewport = Size.zero;
  double _s0 = 1; // px per metre at zoom 1 (whole airport fits the screen)
  bool _initialised = false;
  _Geometry? _geo;

  Future<(AirportMap, List<Zone>)> _fetch() async {
    final r = await Future.wait([AppData.instance.mapFor(widget.airport), Api.instance.zones(widget.airport)]);
    return (r[0] as AirportMap, r[1] as List<Zone>);
  }

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      if (_tween != null) _transform.value = _tween!.value;
    });
  }

  @override
  void didUpdateWidget(AirportMapView old) {
    super.didUpdateWidget(old);
    if (old.airport != widget.airport) {
      setState(() {
        _load = _fetch();
        _initialised = false;
        _terminal = null;
        _level = null;
        _geo = null;
      });
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {
        _load = _fetch();
      });

  // ---------------------------------------------------------------- camera

  /// Matrix that fits [rect] (in metres) into the viewport.
  Matrix4 _fit(Rect rect, {double padding = 0.85, double maxPxPerMetre = 6}) {
    final r = Rect.fromLTRB(rect.left * _s0, rect.top * _s0, rect.right * _s0, rect.bottom * _s0);
    final scale = math.min(
      math.min(_viewport.width / r.width, _viewport.height / r.height) * padding,
      maxPxPerMetre / _s0,
    );
    final tx = _viewport.width / 2 - r.center.dx * scale;
    final ty = _viewport.height / 2 - r.center.dy * scale;
    return Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _animateTo(Matrix4 target) {
    _tween = Matrix4Tween(begin: _transform.value, end: target).animate(CurvedAnimation(parent: _anim, curve: Curves.easeInOutCubic));
    _anim.forward(from: 0);
  }

  void _focusTerminal(AirportMap map, String? group) {
    setState(() => _terminal = group);
    final shapes = group == null ? map.terminals : map.terminals.where((t) => t.group == group);
    var rect = shapes.first.bounds;
    for (final s in shapes) {
      rect = rect.expandToInclude(s.bounds);
    }
    _animateTo(_fit(rect.inflate(20)));
  }

  void _zoomBy(double factor) {
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    final m = _transform.value.clone();
    final scale = m.getMaxScaleOnAxis();
    final target = (scale * factor).clamp(0.5, 8 / _s0);
    final f = target / scale;
    final next = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(f, f, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1)
      ..multiply(m);
    _animateTo(next);
  }

  void _initCamera(AirportMap map, List<Zone> zones) {
    if (_initialised) return;
    _initialised = true;
    final focus = widget.focusZoneId == null ? null : zones.where((z) => z.id == widget.focusZoneId).firstOrNull;
    _transform.value = focus != null
        ? _fit(Rect.fromCenter(center: Offset(focus.x, focus.y), width: 260, height: 260))
        : _fit(map.focusBounds, padding: 0.95);
  }

  // ---------------------------------------------------------------- pins

  void _openZone(Zone zone) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        builder: (_, scroll) => ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text(zone.label, style: Theme.of(context).textTheme.titleLarge),
          Text('${zone.items.length} item(s) handed in here', style: TextStyle(color: Palette.of(context).muted)),
          if (zone.estimated)
            Text('Approximate position', style: TextStyle(color: Palette.of(context).muted, fontSize: 11.5)),
          const SizedBox(height: 10),
          for (final item in zone.items)
            FoundItemTile(
              item: item,
              potential: AppData.instance.potentialItemIds.contains(item.id),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => ItemDetailsScreen(item: item)));
              },
            ),
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- points of interest

  static const _markerSize = 26.0;

  /// Icon markers for shops, cafés, toilets... at a constant screen size. Hidden when zoomed out;
  /// where markers would overlap only the most important one is kept.
  List<Widget> _poiMarkers(double zoom) {
    final geo = _geo!;
    final pxPerMetre = _s0 * zoom;
    if (pxPerMetre < 0.6) return const [];
    final cell = (_markerSize + 2) / pxPerMetre; // metres covered by one marker
    final taken = <(int, int), List<Offset>>{}; // grid buckets of kept markers
    final out = <Widget>[];
    for (final poi in geo.pois) {
      if (_level != null && poi.levels.isNotEmpty && !poi.levels.contains(_level)) continue;
      final cx = (poi.pos.dx / cell).floor(), cy = (poi.pos.dy / cell).floor();
      var free = true;
      for (var dx = -1; dx <= 1 && free; dx++) {
        for (var dy = -1; dy <= 1 && free; dy++) {
          free = !(taken[(cx + dx, cy + dy)]?.any((o) => (o - poi.pos).distance < cell) ?? false);
        }
      }
      if (!free) continue;
      taken.putIfAbsent((cx, cy), () => []).add(poi.pos);
      final style = poiStyle(poi.type, poi.kind);
      out.add(Positioned(
        left: poi.pos.dx * _s0 - _markerSize / 2,
        top: poi.pos.dy * _s0 - _markerSize / 2,
        width: _markerSize,
        height: _markerSize,
        child: Transform.scale(
          scale: 1 / zoom,
          child: _PoiMarker(style: style, selected: identical(poi, _poi), onTap: () => _openPoi(geo.map, poi)),
        ),
      ));
    }
    return out;
  }

  MapPoint? _poi;

  Future<void> _openPoi(AirportMap map, MapPoint poi) async {
    setState(() => _poi = poi);
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _PoiSheet(map: map, poi: poi),
    );
    if (mounted) setState(() => _poi = null);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return FutureBuilder<(AirportMap, List<Zone>)>(
      future: _load,
      builder: (context, snap) {
        if (snap.hasError) {
          return PageBody(children: [NoteCard(icon: Icons.map_outlined, title: "Can't load the airport map", body: '${snap.error}')]);
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final (map, zones) = snap.data!;
        _geo ??= _Geometry(map);
        final pinned = zones.where((z) => z.items.isNotEmpty || z.id == widget.focusZoneId).toList();
        final levels = map.usefulLevels;
        final total = zones.fold<int>(0, (s, z) => s + z.items.length);

        return Column(children: [
          // Terminal + floor selectors.
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              children: [
                _Chip(label: 'Whole airport', selected: _terminal == null, onTap: () => _focusTerminal(map, null)),
                for (final g in map.terminalGroups)
                  _Chip(label: g, selected: _terminal == g, onTap: () => _focusTerminal(map, g)),
              ],
            ),
          ),
          if (levels.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                children: [
                  _Chip(label: 'All floors', small: true, selected: _level == null, onTap: () => setState(() => _level = null)),
                  for (final l in levels)
                    _Chip(label: 'Level $l', small: true, selected: _level == l, onTap: () => setState(() => _level = l)),
                ],
              ),
            ),
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              _viewport = c.biggest;
              _s0 = math.min(c.maxWidth / map.width, c.maxHeight / map.height);
              _initCamera(map, zones);
              final childSize = Size(map.width * _s0, map.height * _s0);
              return ClipRect(
                child: Stack(children: [
                  Positioned.fill(child: ColoredBox(color: p.background)),
                  InteractiveViewer(
                    transformationController: _transform,
                    constrained: false,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    minScale: 0.5,
                    maxScale: 8 / _s0,
                    child: AnimatedBuilder(
                      animation: _transform,
                      builder: (context, _) {
                        final zoom = _transform.value.getMaxScaleOnAxis();
                        return SizedBox.fromSize(
                          size: childSize,
                          child: Stack(clipBehavior: Clip.none, children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _MapPainter(
                                  geo: _geo!,
                                  s0: _s0,
                                  zoom: zoom,
                                  level: _level,
                                  palette: p,
                                  highlight: _terminal,
                                  fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
                                ),
                              ),
                            ),
                            ..._poiMarkers(zoom),
                            for (final z in pinned)
                              Positioned(
                                left: z.x * _s0 - 20,
                                top: z.y * _s0 - 44,
                                width: 40,
                                height: 44,
                                child: Transform.scale(
                                  scale: 1 / zoom,
                                  alignment: Alignment.bottomCenter,
                                  child: _Pin(
                                    count: z.items.length,
                                    focused: z.id == widget.focusZoneId,
                                    onTap: () => _openZone(z),
                                  ),
                                ),
                              ),
                          ]),
                        );
                      },
                    ),
                  ),
                  // Summary, attribution and zoom controls.
                  Positioned(
                    left: 12,
                    top: 8,
                    child: _Glass(
                      child: Text('$total item(s) on the map · tap a pin or a place', style: const TextStyle(fontSize: 11.5)),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    bottom: 6,
                    child: Text(map.attribution, style: TextStyle(fontSize: 9.5, color: p.muted)),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 16,
                    child: Column(children: [
                      _RoundButton(icon: Icons.add, onTap: () => _zoomBy(1.8)),
                      const SizedBox(height: 8),
                      _RoundButton(icon: Icons.remove, onTap: () => _zoomBy(1 / 1.8)),
                      const SizedBox(height: 8),
                      _RoundButton(icon: Icons.refresh, onTap: _refresh),
                    ]),
                  ),
                ]),
              );
            }),
          ),
        ]);
      },
    );
  }
}

/// Paths built once per airport (metres), reused for every frame.
class _Geometry {
  final AirportMap map;
  final List<(MapShape, Path)> terminals;
  final List<(MapShape, Path)> rooms;
  final Map<String, Offset> groupLabels;
  final List<MapPoint> pois; // most important first, so they win when markers overlap

  _Geometry(this.map)
      : terminals = [for (final t in map.terminals) (t, _path(t.points))],
        rooms = [for (final r in map.rooms) (r, _path(r.points))],
        groupLabels = _labels(map),
        pois = [...map.pois]..sort((a, b) => poiPriority(a.type, a.name.isNotEmpty) - poiPriority(b.type, b.name.isNotEmpty));

  static Path _path(List<Offset> pts) => Path()..addPolygon(pts, true);

  /// Terminal name placed over its zones (the passenger building), else over its largest part.
  static Map<String, Offset> _labels(AirportMap map) {
    final out = <String, Offset>{};
    for (final g in map.terminalGroups) {
      final zs = map.zones.where((z) => z.group == g).toList();
      if (zs.isNotEmpty) {
        final c = zs.fold(Offset.zero, (s, z) => s + z.pos) / zs.length.toDouble();
        out[g] = c;
        continue;
      }
      final parts = map.terminals.where((t) => t.group == g);
      if (parts.isEmpty) continue;
      out[g] = parts.reduce((a, b) => a.area >= b.area ? a : b).bounds.center;
    }
    return out;
  }
}

class _MapPainter extends CustomPainter {
  final _Geometry geo;
  final double s0;
  final double zoom;
  final String? level;
  final Palette palette;
  final String? highlight;
  final String? fontFamily;

  _MapPainter({
    required this.geo,
    required this.s0,
    required this.zoom,
    required this.level,
    required this.palette,
    this.highlight,
    this.fontFamily,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pxPerMetre = s0 * zoom;
    double px(double v) => v / pxPerMetre; // screen pixels -> metres
    final p = palette;
    canvas.save();
    canvas.scale(s0);

    // Terminal buildings.
    final fill = Paint()..color = Color.alphaBlend(p.primary.withValues(alpha: 0.13), p.surface);
    final fillHi = Paint()..color = Color.alphaBlend(p.primary.withValues(alpha: 0.26), p.surface);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = px(1.4)
      ..color = p.primary.withValues(alpha: 0.8);
    for (final (shape, path) in geo.terminals) {
      canvas.drawPath(path, highlight != null && shape.group == highlight ? fillHi : fill);
      canvas.drawPath(path, stroke);
    }

    // Indoor rooms (only once zoomed in enough to read them).
    if (pxPerMetre > 0.25) {
      final roomFill = Paint()..color = p.tint.withValues(alpha: 0.7);
      final roomStroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = px(0.6)
        ..color = p.primary.withValues(alpha: 0.25);
      for (final (shape, path) in geo.rooms) {
        if (level != null && shape.levels.isNotEmpty && !shape.levels.contains(level)) continue;
        canvas.drawPath(path, roomFill);
        canvas.drawPath(path, roomStroke);
      }
    }

    // Points of interest are widgets on top (icons + tap), see _AirportMapViewState._poiMarkers.


    // Gates.
    final gatePaint = Paint()..color = p.primary;
    final gateRing = Paint()..color = p.surface;
    final gateR = (1.2 + pxPerMetre * 2.5).clamp(1.2, 3.2); // dots grow as you zoom in
    for (final g in geo.map.gates) {
      canvas.drawCircle(g.pos, px(gateR + 1.2), gateRing);
      canvas.drawCircle(g.pos, px(gateR), gatePaint);
      if (pxPerMetre > 1.1) _text(canvas, g.name, g.pos + Offset(px(6), -px(6)), px(10), p.primary, FontWeight.w600);
    }

    // Terminal names, always readable.
    for (final e in geo.groupLabels.entries) {
      _text(canvas, e.key, e.value, px(12), p.text, FontWeight.w700, center: true, halo: p.surface);
    }
    canvas.restore();
  }

  void _text(Canvas canvas, String text, Offset at, double fontSize, Color color, FontWeight weight,
      {bool center = false, Color? halo}) {
    TextPainter tp(Paint? foreground) => TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: fontSize,
              fontWeight: weight,
              color: foreground == null ? color : null,
              foreground: foreground,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
    final main = tp(null);
    final offset = center ? at - Offset(main.width / 2, main.height / 2) : at;
    if (halo != null) {
      tp(Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = fontSize * 0.35
            ..color = halo)
          .paint(canvas, offset);
    }
    main.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.zoom != zoom || old.level != level || old.palette != palette || old.highlight != highlight || old.geo != geo;
}

class _Pin extends StatelessWidget {
  final int count;
  final bool focused;
  final VoidCallback onTap;
  const _Pin({required this.count, required this.focused, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = focused ? p.warning : const Color(0xFFE5484D);
    return GestureDetector(
      onTap: onTap,
      child: Stack(alignment: Alignment.topCenter, children: [
        Icon(Icons.location_on, size: 40, color: color, shadows: const [Shadow(blurRadius: 4, color: Colors.black26)]),
        Positioned(
          top: 7,
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: count == 0
                ? Icon(Icons.circle, size: 8, color: color)
                : Text('$count', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
          ),
        ),
      ]),
    );
  }
}

class _PoiMarker extends StatelessWidget {
  final PoiStyle style;
  final bool selected;
  final VoidCallback onTap;
  const _PoiMarker({required this.style, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: style.label,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedScale(
          scale: selected ? 1.3 : 1,
          duration: const Duration(milliseconds: 150),
          child: Container(
            decoration: BoxDecoration(
              color: style.color,
              shape: BoxShape.circle,
              border: Border.all(color: p.surface, width: 2),
              boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26, offset: Offset(0, 1))],
            ),
            alignment: Alignment.center,
            child: Icon(style.icon, size: 14, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Pop-up card for a tapped point of interest: name, opening hours and whatever else OSM knows.
class _PoiSheet extends StatelessWidget {
  final AirportMap map;
  final MapPoint poi;
  const _PoiSheet({required this.map, required this.poi});

  /// "Terminal 5 · near Gate A10", from the closest lost & found zone.
  String? get _where {
    if (map.zones.isEmpty) return null;
    final z = map.zones.reduce((a, b) => (a.pos - poi.pos).distance <= (b.pos - poi.pos).distance ? a : b);
    final d = (z.pos - poi.pos).distance;
    return d < 120 ? '${z.group} · near ${z.name}' : z.group;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final style = poiStyle(poi.type, poi.kind);
    final info = poi.info;
    final title = poi.name.isNotEmpty ? poi.name : style.label;
    final rawHours = info['hours'];
    final hours = rawHours == null ? null : OpeningHours.tryParse(rawHours);
    final status = hours?.statusAt(DateTime.now());
    final where = _where;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            CircleAvatar(radius: 22, backgroundColor: style.color, child: Icon(style.icon, color: Colors.white, size: 22)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                if (poi.name.isNotEmpty) Text(style.label, style: TextStyle(color: p.muted, fontSize: 13)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          // Opening hours.
          if (status != null) ...[
            RBadge(status.$2, icon: Icons.schedule, kind: status.$1 ? BadgeKind.success : BadgeKind.neutral),
            const SizedBox(height: 6),
          ],
          InfoRow(
            icon: Icons.schedule,
            label: 'Opening hours',
            value: hours != null ? hours.lines.join('\n') : rawHours ?? 'Not published — ask at an information desk',
          ),
          if (where != null) InfoRow(icon: Icons.place_outlined, label: 'Where', value: where),
          if (poi.levels.isNotEmpty)
            InfoRow(icon: Icons.layers_outlined, label: 'Floor', value: poi.levels.map((l) => 'Level $l').join(', ')),
          if (info['airside'] != null)
            InfoRow(
              icon: Icons.security,
              label: 'Security',
              value: info['airside'] == 'yes' ? 'Airside — after security' : 'Landside — before security',
            ),
          if (info['cuisine'] != null) InfoRow(icon: Icons.restaurant_menu, label: 'Serves', value: humanizeTag(info['cuisine']!)),
          if (info['brand'] != null && info['brand'] != poi.name) InfoRow(icon: Icons.sell_outlined, label: 'Brand', value: info['brand']!),
          if (info['operator'] != null && info['operator'] != info['brand'])
            InfoRow(icon: Icons.business_outlined, label: 'Operated by', value: info['operator']!),
          if (info['wheelchair'] != null)
            InfoRow(
              icon: Icons.accessible,
              label: 'Accessibility',
              value: switch (info['wheelchair']) {
                'yes' => 'Wheelchair accessible',
                'limited' => 'Limited wheelchair access',
                'no' => 'Not wheelchair accessible',
                final v => humanizeTag(v!),
              },
            ),
          if (info['description'] != null) InfoRow(icon: Icons.notes, label: 'About', value: info['description']!),
          if (info['phone'] != null) InfoRow(icon: Icons.call_outlined, label: 'Phone', value: info['phone']!),
          if (info['website'] != null) InfoRow(icon: Icons.language, label: 'Website', value: info['website']!),
          const SizedBox(height: 8),
          Text('Details from OpenStreetMap — they may be out of date.', style: TextStyle(color: p.muted, fontSize: 11)),
        ]),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool small;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap, this.small = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterPill(label: label, active: selected, trailingIcon: null, onTap: onTap),
      );
}

class _Glass extends StatelessWidget {
  final Widget child;
  const _Glass({required this.child});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: p.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border),
      ),
      child: child,
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Material(
      color: p.surface,
      shape: CircleBorder(side: BorderSide(color: p.border)),
      elevation: 1,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(9), child: Icon(icon, size: 20, color: p.primary)),
      ),
    );
  }
}

/// Small, non-interactive preview of the airport outline (Home airport card).
class AirportMiniMap extends StatelessWidget {
  final String airport;
  const AirportMiniMap({super.key, required this.airport});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return FutureBuilder<AirportMap>(
      future: AppData.instance.mapFor(airport),
      builder: (context, snap) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [p.tint, Color.alphaBlend(p.primary.withValues(alpha: 0.18), p.tint)],
            ),
          ),
          child: !snap.hasData
              ? Center(child: Icon(Icons.map_outlined, color: p.primary.withValues(alpha: 0.5), size: 40))
              : LayoutBuilder(builder: (context, c) {
                  final map = snap.data!;
                  final s0 = math.min(c.maxWidth / map.width, c.maxHeight / map.height) * 0.92;
                  return Center(
                    child: SizedBox(
                      width: map.width * s0,
                      height: map.height * s0,
                      child: CustomPaint(
                        painter: _MapPainter(
                          geo: _Geometry(map),
                          s0: s0,
                          zoom: 1,
                          level: null,
                          palette: p,
                          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
                        ),
                      ),
                    ),
                  );
                }),
        );
      },
    );
  }
}
