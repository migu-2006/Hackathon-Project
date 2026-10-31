import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'theme.dart';

/// iOS-style "liquid glass" layer for buttons: a frosted blur of whatever is behind,
/// a specular sheen across the top, a soft glow along the bottom (light bending through
/// the glass) and a bright rim that fades around the edge. It is tint-neutral: the button's
/// own (translucent) background colour shows through, so any button colour becomes glass.
class LiquidGlass extends StatelessWidget {
  final Widget child;
  final ShapeBorder shape;
  final bool pressed;
  final double blur;
  const LiquidGlass({
    super.key,
    required this.child,
    this.shape = const StadiumBorder(),
    this.pressed = false,
    this.blur = 5, // stronger blurs wash the tint out at the edges
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: CustomPaint(
          painter: _GlassPainter(shape: shape, dark: dark, pressed: pressed),
          child: child,
        ),
      ),
    );
  }
}

class _GlassPainter extends CustomPainter {
  final ShapeBorder shape;
  final bool dark;
  final bool pressed;
  _GlassPainter({required this.shape, required this.dark, required this.pressed});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = shape.getOuterPath(rect);
    final boost = pressed ? 1.6 : 1.0; // the glass "lights up" under the finger
    double a(double v) => (v * (dark ? 0.6 : 1) * boost).clamp(0.0, 1.0);

    // Specular sheen: bright at the top edge, gone by the middle.
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [Colors.white.withValues(alpha: a(0.38)), Colors.white.withValues(alpha: 0)],
        ).createShader(rect),
    );
    // Refraction glow hugging the bottom edge.
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: const Alignment(0, 0.3),
          colors: [Colors.white.withValues(alpha: a(0.16)), Colors.white.withValues(alpha: 0)],
        ).createShader(rect),
    );
    // Rim light: strong top-left and bottom-right, faint in between, like a curved edge.
    final inset = shape.getOuterPath(rect.deflate(0.6));
    canvas.drawPath(
      inset,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: a(0.85)),
            Colors.white.withValues(alpha: a(0.08)),
            Colors.white.withValues(alpha: a(0.08)),
            Colors.white.withValues(alpha: a(0.5)),
          ],
          stops: const [0, 0.35, 0.65, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassPainter old) => old.pressed != pressed || old.dark != dark || old.shape != shape;
}

/// Hook for ButtonStyle.backgroundBuilder: wraps the button content in [LiquidGlass].
ButtonLayerBuilder glassBuilder(ShapeBorder shape) =>
    (context, states, child) => LiquidGlass(shape: shape, pressed: states.contains(WidgetState.pressed), child: child!);

/// Round glass for app bar icon buttons (back, help, refresh, account).
ButtonStyle glassIconStyle(BuildContext context) {
  final p = Palette.of(context);
  const shape = CircleBorder();
  return IconButton.styleFrom(
    backgroundColor: p.surface.withValues(alpha: 0.55),
    shape: shape,
    side: BorderSide(color: p.border.withValues(alpha: 0.6), width: 0.6),
    shadowColor: Colors.black.withValues(alpha: 0.25),
    elevation: 2,
  ).copyWith(backgroundBuilder: glassBuilder(shape));
}
