import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/palette.dart';
import 'step_clock.dart';

class _Spark {
  _Spark(this.pos, this.vel, this.life, this.size, this.color, this.gravity);

  Offset pos;
  Offset vel;
  double age = 0;
  final double life;
  final double size;
  final Color color;
  final double gravity;

  double get t => (age / life).clamp(0, 1);
}

/// Hosts spark bursts drawn above its [child]. Descendants trigger bursts
/// with `SparkField.of(context)?.burst(globalPosition)`.
class SparkField extends StatefulWidget {
  const SparkField({super.key, required this.child, this.intensity = 1});

  final Widget child;

  /// Multiplier on particle counts (lowered for reduced motion).
  final double intensity;

  static SparkFieldState? of(BuildContext context) => context.findAncestorStateOfType<SparkFieldState>();

  @override
  State<SparkField> createState() => SparkFieldState();
}

class SparkFieldState extends State<SparkField> with SingleTickerProviderStateMixin {
  final _sparks = <_Spark>[];
  final _rng = Random();
  final _repaint = ValueNotifier<int>(0);
  final _boxKey = GlobalKey();
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  void burst(
    Offset global, {
    int count = 18,
    double speed = 260,
    double angle = -pi / 2,
    double spread = pi * 1.6,
    double gravity = 700,
    List<Color>? colors,
    double size = 2.2,
  }) {
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final local = box.globalToLocal(global);
    final n = (count * widget.intensity).round();
    colors ??= [Palette.fire.molten, Palette.fire.ember, Palette.fire.white];
    for (var i = 0; i < n; i++) {
      final a = angle + (_rng.nextDouble() - 0.5) * spread;
      final s = speed * (0.35 + _rng.nextDouble() * 0.9);
      _sparks.add(
        _Spark(
          local,
          Offset(cos(a), sin(a)) * s,
          0.35 + _rng.nextDouble() * 0.55,
          size * (0.6 + _rng.nextDouble() * 0.9),
          colors[_rng.nextInt(colors.length)],
          gravity,
        ),
      );
    }
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero ? 1 / 60 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    for (final s in _sparks) {
      s.age += dt;
      s.vel = Offset(s.vel.dx * 0.985, s.vel.dy * 0.985 + s.gravity * dt);
      s.pos += s.vel * dt;
    }
    _sparks.removeWhere((s) => s.age >= s.life);
    _repaint.value++;
    if (_sparks.isEmpty) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    key: _boxKey,
    fit: StackFit.passthrough,
    children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          child: RepaintBoundary(child: CustomPaint(painter: _SparkPainter(_sparks, _repaint))),
        ),
      ),
    ],
  );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.sparks, Listenable repaint) : super(repaint: repaint);

  final List<_Spark> sparks;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..blendMode = BlendMode.plus;
    for (final s in sparks) {
      final fade = 1 - s.t * s.t;
      paint
        ..color = s.color.withValues(alpha: fade)
        ..strokeWidth = s.size * (1 - s.t * 0.5);
      final tail = s.pos - s.vel * 0.028;
      canvas.drawLine(tail, s.pos, paint);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => false;
}

/// Slow embers drifting up from the bottom of a background, stepped by
/// [clock] (their own when there's none; see [StepClock]).
class EmberDrift extends StatefulWidget {
  const EmberDrift({super.key, this.count = 14, this.clock});

  final int count;

  /// Seconds to drift by; a [ForgeBackground] shares its fire's.
  final ValueListenable<double>? clock;

  @override
  State<EmberDrift> createState() => _EmberDriftState();
}

class _Ember {
  double x = 0, y = 0, speed = 0, sway = 0, phase = 0, size = 0, life = 0;
}

class _EmberDriftState extends State<EmberDrift> with SingleTickerProviderStateMixin {
  final _rng = Random();
  late final List<_Ember> _embers = List.generate(widget.count, (_) {
    final e = _Ember();
    _respawn(e, initial: true);
    return e;
  });
  StepClock? _own;
  late ValueListenable<double> _clock;
  late double _at;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _clock = widget.clock ?? (_own ??= StepClock(this)..start());
    _at = _clock.value;
    _clock.addListener(_tick);
  }

  @override
  void didUpdateWidget(EmberDrift oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock) {
      _clock.removeListener(_tick);
      _listen();
    }
  }

  void _respawn(_Ember e, {bool initial = false}) {
    e
      ..x = _rng.nextDouble()
      ..y = initial ? _rng.nextDouble() : 1.05
      ..speed = 0.02 + _rng.nextDouble() * 0.05
      ..sway = 0.01 + _rng.nextDouble() * 0.02
      ..phase = _rng.nextDouble() * pi * 2
      ..size = 1 + _rng.nextDouble() * 2.2
      ..life = 0;
  }

  void _tick() {
    final now = _clock.value;
    final dt = (now - _at).clamp(0.0, 0.1);
    _at = now;
    for (final e in _embers) {
      e.life += dt;
      e.y -= e.speed * dt;
      if (e.y < -0.05) _respawn(e);
    }
  }

  @override
  void dispose() {
    _clock.removeListener(_tick);
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(size: Size.infinite, painter: _EmberPainter(_embers, _clock)),
    ),
  );
}

/// A soft white dot, faded out to its edge like a blurred disc: each ember's
/// glow is this, tinted. A blurred circle per ember per frame cost more.
final ui.Image _glow = () {
  const r = _EmberPainter.glowRadius;
  final recorder = ui.PictureRecorder();
  const rect = Rect.fromLTWH(0, 0, r * 2, r * 2);
  Canvas(recorder).drawCircle(
    rect.center,
    r,
    Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xFFFFFFFF), Color(0xC0FFFFFF), Color(0x66FFFFFF), Color(0x1FFFFFFF), Color(0x00FFFFFF)],
        stops: [0, 0.3, 0.55, 0.78, 1],
      ).createShader(rect),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync((r * 2).toInt(), (r * 2).toInt());
  picture.dispose();
  return image;
}();

class _EmberPainter extends CustomPainter {
  _EmberPainter(this.embers, this.time) : super(repaint: time);

  final List<_Ember> embers;
  final Listenable time;

  /// The glow sprite's radius, in its own pixels.
  static const glowRadius = 32.0;

  /// How far the glow's blur reaches past its circle.
  static const _blur = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final core = Paint()..blendMode = BlendMode.plus;
    final transforms = <RSTransform>[];
    final colors = <Color>[];
    for (final e in embers) {
      final flicker = 0.55 + 0.45 * sin(e.life * 5 + e.phase);
      final fadeTop = (e.y * 3).clamp(0.0, 1.0);
      final a = flicker * fadeTop;
      final p = Offset((e.x + sin(e.life * 1.3 + e.phase) * e.sway) * size.width, e.y * size.height);
      // A circle of radius g blurred (sigma 3): it reaches about 6 further,
      // and the small ones never get to full strength in the middle.
      final g = e.size * 2.2;
      transforms.add(
        RSTransform.fromComponents(
          rotation: 0,
          scale: (g + _blur) / glowRadius,
          anchorX: glowRadius,
          anchorY: glowRadius,
          translateX: p.dx,
          translateY: p.dy,
        ),
      );
      colors.add(Palette.ember.withValues(alpha: 0.5 * a * (1 - exp(-g * g / 18))));
      core.color = Palette.molten.withValues(alpha: 0.9 * a);
      canvas.drawCircle(p, e.size * 0.7, core);
    }
    canvas.drawAtlas(
      _glow,
      transforms,
      List.filled(transforms.length, const Rect.fromLTWH(0, 0, glowRadius * 2, glowRadius * 2)),
      colors,
      BlendMode.modulate,
      null,
      Paint()
        ..blendMode = BlendMode.plus
        ..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_EmberPainter old) => old.time != time || old.embers != embers;
}
