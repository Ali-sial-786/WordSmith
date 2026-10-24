import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/palette.dart';

/// Animated forge fire (shaders/forge_fire.frag) rising from the bottom of its
/// box. When [animate] is false it shows a single still frame, and where
/// shaders can't load it falls back to a flickering glow.
class ForgeFire extends StatefulWidget {
  const ForgeFire({super.key, this.intensity = 1, this.animate = true, this.colorFilter});

  /// 0–1: how tall and bright the fire is.
  final double intensity;
  final bool animate;

  /// Recolours the flames as they're drawn (cheaper than a [ColorFiltered]
  /// layer over them on every frame).
  final ColorFilter? colorFilter;

  @override
  State<ForgeFire> createState() => _ForgeFireState();
}

class _ForgeFireState extends State<ForgeFire> with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram?>? _program;

  /// The fire steps about 30 times a second (40 at 120 Hz), not on every
  /// display frame: each step redraws the whole screen, and slow flames look
  /// the same. The ticker takes one frame, then waits this long to ask for the
  /// next, so the step still lands on a frame.
  static const _step = Duration(milliseconds: 20);

  ui.FragmentShader? _shader;
  final _time = ValueNotifier<double>(7.3);
  Duration? _start;
  Timer? _next;
  late final Ticker _ticker = createTicker((_) {
    // Frame time, not a stopwatch, so tests see the same flames every run.
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    _time.value = 7.3 + (now - (_start ??= now)).inMicroseconds / 1e6;
    _ticker.stop();
    _next = Timer(_step, _resume);
  });

  void _resume() {
    if (mounted && widget.animate && !_ticker.isActive && _next?.isActive != true) _ticker.start();
  }

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
    if (widget.animate) _ticker.start();
  }

  @override
  void didUpdateWidget(ForgeFire oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate) {
      _resume();
    } else {
      _ticker.stop();
      _next?.cancel();
    }
  }

  @override
  void dispose() {
    _next?.cancel();
    _ticker.dispose();
    _time.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _shader == null
            ? _GlowPainter(_time, widget.intensity, widget.colorFilter)
            : _FirePainter(_shader!, _time, widget.intensity, widget.colorFilter),
      ),
    ),
  );
}

class _FirePainter extends CustomPainter {
  _FirePainter(this.shader, this.time, this.intensity, this.colorFilter) : super(repaint: time);

  final ui.FragmentShader shader;
  final ValueNotifier<double> time;
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
      old.shader != shader || old.intensity != intensity || old.colorFilter != colorFilter;
}

/// Fallback: a warm glow from the bottom edge that flickers.
class _GlowPainter extends CustomPainter {
  _GlowPainter(this.time, this.intensity, this.colorFilter) : super(repaint: time);

  final ValueNotifier<double> time;
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
  bool shouldRepaint(_GlowPainter old) => old.intensity != intensity || old.colorFilter != colorFilter;
}
