import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/palette.dart';
import 'step_clock.dart';

/// Animated forge fire (shaders/forge_fire.frag) rising from the bottom of its
/// box, stepped by [clock] (its own when there's none). When [animate] is
/// false it shows a single still frame, and where shaders can't load it falls
/// back to a flickering glow.
///
/// The flames are drawn straight onto the screen. Drawing them into an
/// offscreen image each step instead (to reuse it between steps) crashed
/// Adreno's drivers, as Android's stretch shader once did.
class ForgeFire extends StatefulWidget {
  const ForgeFire({super.key, this.intensity = 1, this.animate = true, this.colorFilter, this.clock});

  /// 0–1: how tall and bright the fire is.
  final double intensity;
  final bool animate;

  /// Recolours the flames as they're drawn (cheaper than a [ColorFiltered]
  /// layer over them on every frame).
  final ColorFilter? colorFilter;

  /// Seconds to burn at; shared with the embers by a [ForgeBackground].
  final ValueListenable<double>? clock;

  @override
  State<ForgeFire> createState() => _ForgeFireState();
}

class _ForgeFireState extends State<ForgeFire> with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram?>? _program;

  ui.FragmentShader? _shader;
  StepClock? _own;

  ValueListenable<double> get _clock => widget.clock ?? (_own ??= StepClock(this, start: 7.3));

  @override
  void initState() {
    super.initState();
    _program ??= ui.FragmentProgram.fromAsset('shaders/forge_fire.frag')
        .then<ui.FragmentProgram?>((p) => p)
        .catchError((Object e) {
          debugPrint('forge fire shader unavailable: $e');
          return null;
        });
    _program!.then((p) {
      if (!mounted || p == null) return;
      setState(() => _shader = p.fragmentShader());
    });
    _run();
  }

  void _run() {
    if (widget.clock != null) {
      _own?.stop();
      return;
    }
    final own = _clock as StepClock;
    widget.animate ? own.start() : own.stop();
  }

  @override
  void didUpdateWidget(ForgeFire oldWidget) {
    super.didUpdateWidget(oldWidget);
    _run();
  }

  @override
  void dispose() {
    _own?.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _shader == null
            ? _GlowPainter(_clock, widget.intensity, widget.colorFilter)
            : _FirePainter(_shader!, _clock, widget.intensity, widget.colorFilter),
      ),
    ),
  );
}

class _FirePainter extends CustomPainter {
  _FirePainter(this.shader, this.time, this.intensity, this.colorFilter) : super(repaint: time);

  final ui.FragmentShader shader;
  final ValueListenable<double> time;
  final double intensity;
  final ColorFilter? colorFilter;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time.value)
      ..setFloat(3, intensity);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = shader
        ..colorFilter = colorFilter,
    );
  }

  @override
  bool shouldRepaint(_FirePainter old) =>
      old.shader != shader || old.intensity != intensity || old.colorFilter != colorFilter || old.time != time;
}

/// Fallback: a warm glow from the bottom edge that flickers.
class _GlowPainter extends CustomPainter {
  _GlowPainter(this.time, this.intensity, this.colorFilter) : super(repaint: time);

  final ValueListenable<double> time;
  final double intensity;
  final ColorFilter? colorFilter;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final flicker = 0.85 + 0.1 * sin(t * 7.1) + 0.05 * sin(t * 13.7);
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.bottomCenter,
          radius: 1.1,
          colors: [
            Palette.fire.ember.withValues(alpha: 0.55 * intensity * flicker),
            const Color(0xFF8A2A06).withValues(alpha: 0.25 * intensity * flicker),
            Colors.transparent,
          ],
          stops: const [0, 0.45, 1],
        ).createShader(rect)
        ..colorFilter = colorFilter,
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.intensity != intensity || old.colorFilter != colorFilter || old.time != time;
}
