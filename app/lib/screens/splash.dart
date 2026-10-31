import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Startup animation drawn over the app while it loads (~1.5 s):
/// the magnifier springs towards the screen, the plane in its lens takes off,
/// then the lens zooms through into the app. Skipped when the OS asks for reduced motion.
class StartupSplash extends StatefulWidget {
  final Widget child;
  const StartupSplash({super.key, required this.child});

  @override
  State<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends State<StartupSplash> with SingleTickerProviderStateMixin {
  static const top = Color(0xFF4C8DF6), bottom = Color(0xFF1E4FC9); // same gradient as the launcher icon

  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) setState(() => _done = true);
    });
  bool _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _done = true;
    } else if (!_c.isAnimating && !_done) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Progress of [t] inside [begin, end], 0..1.
  static double _seg(double t, double begin, double end) => ((t - begin) / (end - begin)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value;

              // 1. Magnifier approaches the screen with an elastic overshoot.
              final approach = const ElasticOutCurve(0.6).transform(_seg(t, 0, 0.55));
              var lensScale = 0.12 + 0.88 * approach;
              final lensTurn = -0.5 * (1 - approach);
              // 3. Recoil wobble as the plane leaves the lens.
              final recoil = _seg(t, 0.55, 0.85);
              lensScale *= 1 - 0.09 * math.sin(recoil * math.pi * 3) * (1 - recoil);
              // 4. Zoom through the lens into the app.
              final exit = Curves.easeInCubic.transform(_seg(t, 0.8, 1));
              lensScale *= 1 + 5 * exit;

              // 2. Wordmark springs in under the lens.
              final word = Curves.elasticOut.transform(_seg(t, 0.22, 0.62));

              // Plane: crouches back a few pixels, then shoots off to the top-right,
              // stretching along its flight path while it accelerates.
              final fly = _seg(t, 0.42, 0.8);
              final crouch = 10 * math.sin(math.pi * _seg(fly, 0, 0.4)); // px, springy wind-up
              final travel = MediaQuery.sizeOf(context).longestSide * 0.7 * Curves.easeInQuart.transform(fly) - crouch;
              final stretch = math.sin(fly * math.pi);

              return Material(
                type: MaterialType.transparency,
                child: Opacity(
                  opacity: 1 - exit,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [top, bottom],
                      ),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Transform.rotate(
                            angle: lensTurn,
                            child: Transform.scale(
                              scale: lensScale,
                              alignment: const Alignment(-0.18, -0.18), // lens centre
                              child: SizedBox.square(
                                dimension: 200,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    if (fly > 0 && fly < 1)
                                      Positioned.fill(
                                        child: CustomPaint(
                                          painter: _TrailPainter(
                                            from: const Offset(82, 82),
                                            to: const Offset(82, 82) + Offset(1, -1) * travel,
                                            opacity: 0.55 * (1 - fly),
                                          ),
                                        ),
                                      ),
                                    const Positioned.fill(child: CustomPaint(painter: _MagnifierPainter())),
                                    Positioned(
                                      left: 82 - 40,
                                      top: 82 - 40,
                                      child: Transform.translate(
                                        offset: Offset(1, -1) * travel,
                                        child: Transform.rotate(
                                          angle: math.pi / 4,
                                          child: Transform.scale(
                                            scaleX: 1 - 0.18 * stretch,
                                            scaleY: (1 + 0.35 * stretch) * (1 + 0.6 * fly),
                                            child: const Icon(Icons.flight, size: 80, color: Colors.white),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Opacity(
                            opacity: _seg(t, 0.22, 0.3),
                            child: Transform.scale(
                              scale: word,
                              child: const Text(
                                'SkyFindr',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 34,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// White magnifier like the launcher icon (artwork on a 1000-unit grid, lens centre at 410,410).
class _MagnifierPainter extends CustomPainter {
  const _MagnifierPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 1000;
    const c = Offset(410, 410), r = 300.0;
    canvas.drawLine(
      (c + const Offset(0.7 * r, 0.7 * r)) * u,
      const Offset(905, 905) * u,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 120 * u
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      c * u,
      (r - 39) * u,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white
        ..strokeWidth = 78 * u,
    );
  }

  @override
  bool shouldRepaint(_MagnifierPainter old) => false;
}

class _TrailPainter extends CustomPainter {
  final Offset from, to;
  final double opacity;
  const _TrailPainter({required this.from, required this.to, required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    if ((to - from).distance < 4) return;
    canvas.drawLine(
      from,
      to,
      Paint()
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: opacity),
          ],
        ).createShader(Rect.fromPoints(from, to)),
    );
  }

  @override
  bool shouldRepaint(_TrailPainter old) => old.to != to || old.opacity != opacity;
}
