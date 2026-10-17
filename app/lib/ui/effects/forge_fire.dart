import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/palette.dart';

/// Animated forge fire (shaders/forge_fire.frag) rising from the bottom of its
/// box. When [animate] is false it shows a single still frame, and where
/// shaders can't load it falls back to a flickering glow.
class ForgeFire extends StatefulWidget {
  const ForgeFire({super.key, this.intensity = 1, this.animate = true});

  /// 0–1: how tall and bright the fire is.
  final double intensity;
  final bool animate;

  @override
  State<ForgeFire> createState() => _ForgeFireState();
}

class _ForgeFireState extends State<ForgeFire> with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram?>? _program;

  ui.FragmentShader? _shader;
  final _time = ValueNotifier<double>(7.3);
  late final Ticker _ticker = createTicker((elapsed) {
    _time.value = 7.3 + elapsed.inMicroseconds / 1e6;
  });

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
    if (widget.animate && !_ticker.isActive) {
      _ticker.start();
    } else if (!widget.animate && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
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
            ? _GlowPainter(_time, widget.intensity)
            : _FirePainter(_shader!, _time, widget.intensity),
      ),
    ),
  );
}

class _FirePainter extends CustomPainter {
  _FirePainter(this.shader, this.time, this.intensity) : super(repaint: time);

  final ui.FragmentShader shader;
  final ValueNotifier<double> time;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time.value)
      ..setFloat(3, intensity);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_FirePainter old) =>
      old.shader != shader || old.intensity != intensity;
}

/// Fallback: a warm glow from the bottom edge that flickers.
class _GlowPainter extends CustomPainter {
  _GlowPainter(this.time, this.intensity) : super(repaint: time);

  final ValueNotifier<double> time;
  final double intensity;

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
            Palette.ember.withValues(alpha: 0.55 * intensity * flicker),
            const Color(0xFF8A2A06).withValues(alpha: 0.25 * intensity * flicker),
            Colors.transparent,
          ],
          stops: const [0, 0.45, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.intensity != intensity;
}
