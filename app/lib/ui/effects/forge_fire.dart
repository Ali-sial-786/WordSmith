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
/// Each step the flames are drawn once, at one pixel per logical pixel (the
/// flames and coals are soft: they look the same), into an image that every frame then just stretches over the box: the
/// shader is the costliest thing on most screens, and the screen is redrawn
/// whole on every frame (Impeller and CanvasKit keep no raster cache), so
/// scrolling would otherwise run it at full resolution 120 times a second.
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

  /// Image pixels per logical pixel, at most.
  static const _resolution = 1.0;

  ui.FragmentShader? _shader;
  StepClock? _own;
  final _frame = _FireFrame();

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
    _frame.dispose();
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
            : _FirePainter(
                _shader!,
                _clock,
                widget.intensity,
                widget.colorFilter,
                _frame,
                min(MediaQuery.devicePixelRatioOf(context), _resolution),
              ),
      ),
    ),
  );
}

/// The flames as last drawn, and what for.
class _FireFrame {
  ui.Image? image;
  (double, Size, double, double)? look;

  void dispose() {
    image?.dispose();
    image = null;
  }
}

class _FirePainter extends CustomPainter {
  _FirePainter(this.shader, this.time, this.intensity, this.colorFilter, this.frame, this.resolution)
    : super(repaint: time);

  final ui.FragmentShader shader;
  final ValueListenable<double> time;
  final double intensity;
  final ColorFilter? colorFilter;
  final _FireFrame frame;

  /// Image pixels per logical pixel.
  final double resolution;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || !size.isFinite) return;
    final w = max(1, (size.width * resolution).ceil());
    final h = max(1, (size.height * resolution).ceil());
    final look = (time.value, size, intensity, resolution);
    if (frame.image == null || frame.look != look) {
      shader
        ..setFloat(0, w.toDouble())
        ..setFloat(1, h.toDouble())
        ..setFloat(2, time.value)
        ..setFloat(3, intensity);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = shader);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(w, h);
      picture.dispose();
      // Frames already drawn keep their own hold on the old image.
      frame
        ..image?.dispose()
        ..image = image
        ..look = look;
    }
    final image = frame.image!;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()
        ..filterQuality = FilterQuality.low
        ..colorFilter = colorFilter,
    );
  }

  @override
  bool shouldRepaint(_FirePainter old) =>
      old.shader != shader ||
      old.intensity != intensity ||
      old.colorFilter != colorFilter ||
      old.resolution != resolution ||
      old.time != time;
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
