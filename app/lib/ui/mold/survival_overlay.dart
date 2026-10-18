import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../engine/puzzle.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';

/// Survival's heated word, for the mold: its cells and how long it has left.
class HeatView {
  const HeatView({required this.cells, required this.remainingMs, required this.durationMs, this.onSecond});

  /// The heated slot's cells, in word order.
  final List<CellPos> cells;

  /// Time left right now (it may be paused, so it's asked each frame).
  final int Function() remainingMs;
  final int durationMs;

  /// Called as the shown seconds change, in the last 5 (for ticks).
  final ValueChanged<int>? onSecond;
}

/// A word melting away (Survival). [id] tells one melt from the next.
class MeltView {
  const MeltView({required this.cells, required this.id});

  final List<CellPos> cells;
  final Object id;
}

/// Metal's glow as it heats, by how much of the time is spent: a dull red
/// first, then cherry, orange and yellow, and white heat at the end.
Color heatGlow(double spent) {
  const ramp = [
    (0.0, Color(0xFF5A1206)),
    (0.25, Color(0xFF9C1E08)),
    (0.5, Color(0xFFD9360C)),
    (0.7, Color(0xFFFF7A1A)),
    (0.86, Color(0xFFFFC24A)),
    (1.0, Color(0xFFFFF4D6)),
  ];
  for (var i = 1; i < ramp.length; i++) {
    final (t1, c1) = ramp[i];
    final (t0, c0) = ramp[i - 1];
    if (spent <= t1) return Color.lerp(c0, c1, (spent - t0) / (t1 - t0))!;
  }
  return ramp.last.$2;
}

/// How long the melt plays before the round's results.
const meltDuration = Duration(milliseconds: 2400);

/// Where each cell sits in the mold grid.
typedef CellRect = Rect Function(CellPos cell);

/// The heated word's cells fill with heat from the bottom as the time runs
/// out, their rims pulse faster, and a badge counts the seconds down.
class HeatOverlay extends StatefulWidget {
  const HeatOverlay({super.key, required this.heat, required this.rectOf});

  final HeatView heat;
  final CellRect rectOf;

  @override
  State<HeatOverlay> createState() => _HeatOverlayState();
}

class _HeatOverlayState extends State<HeatOverlay> with SingleTickerProviderStateMixin {
  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker;
  int? _lastSecond;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _time.value = elapsed.inMicroseconds / 1e6;
      final secs = (widget.heat.remainingMs() / 1000).ceil();
      if (secs != _lastSecond) {
        _lastSecond = secs;
        if (secs <= 5 && secs > 0) widget.heat.onSecond?.call(secs);
      }
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _HeatPainter(heat: widget.heat, rectOf: widget.rectOf, time: _time),
        size: Size.infinite,
      ),
    ),
  );
}

class _HeatPainter extends CustomPainter {
  _HeatPainter({required this.heat, required this.rectOf, required this.time}) : super(repaint: time);

  final HeatView heat;
  final CellRect rectOf;
  final ValueNotifier<double> time;

  @override
  void paint(Canvas canvas, Size size) {
    if (heat.cells.isEmpty) return;
    final left = heat.remainingMs().clamp(0, heat.durationMs);
    final spent = 1 - left / max(1, heat.durationMs);
    // Hotter faster towards the end.
    final hot = pow(spent, 1.25).toDouble();
    final now = time.value;
    // Faster as it gets hotter: about 1 beat a second, up to 4.
    final beat = 0.5 + 0.5 * sin(now * pi * (2 + 6 * spent * spent));
    final glow = heatGlow(hot);
    final cell = rectOf(heat.cells.first).width;

    // The whole branch as one hot bar behind its cells: the gaps glow too.
    final bar = heat.cells.map(rectOf).reduce((a, b) => a.expandToInclude(b));
    canvas.drawRRect(
      RRect.fromRectAndRadius(bar.inflate(cell * (0.04 + 0.1 * hot)), Radius.circular(cell * 0.2)),
      Paint()
        ..color = glow.withValues(alpha: 0.18 + 0.5 * hot)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, cell * (0.12 + 0.45 * hot)),
    );

    for (final (i, c) in heat.cells.indexed) {
      final r = rectOf(c);
      final rr = RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.16));
      // A flicker, like metal in the fire, that grows with the heat.
      final shimmer = 1 + 0.12 * hot * sin(now * 11 + i * 1.7) * sin(now * 4.3 + i);
      final a = ((0.12 + 0.62 * hot) * shimmer).clamp(0.0, 0.8);
      // Brightest in the middle of each cell, cooler at its rim.
      canvas.drawRRect(
        rr,
        Paint()
          ..shader = RadialGradient(
            radius: 0.75,
            colors: [
              heatGlow(min(1, hot + 0.12)).withValues(alpha: a),
              glow.withValues(alpha: a * 0.85),
              heatGlow(max(0, hot - 0.2)).withValues(alpha: a * 0.6),
            ],
            stops: const [0.0, 0.55, 1.0],
          ).createShader(r),
      );
      canvas.drawRRect(
        rr,
        Paint()
          ..color = Color.lerp(glow, Colors.white, 0.25 * beat)!.withValues(alpha: 0.55 + 0.45 * max(beat, hot))
          ..style = PaintingStyle.stroke
          ..strokeWidth = max(2, r.width * (0.05 + 0.03 * hot)),
      );
    }
    if (hot > 0.55) _embers(canvas, bar, cell, (hot - 0.55) / 0.45, now);
    _badge(canvas, rectOf(heat.cells.first), (left / 1000).ceil(), spent, beat);
  }

  /// Sparks drifting up off the metal as it nears melting.
  void _embers(Canvas canvas, Rect bar, double cell, double amount, double now) {
    final rng = Random(heat.cells.first.x * 31 + heat.cells.first.y);
    final n = (4 + 10 * amount).round();
    for (var k = 0; k < n; k++) {
      final speed = 0.35 + 0.4 * rng.nextDouble();
      final phase = rng.nextDouble();
      final x0 = bar.left + bar.width * rng.nextDouble();
      final t = (now * speed + phase) % 1.0;
      final y = bar.bottom - (bar.height + cell * 1.2) * t;
      final x = x0 + sin((now + phase * 7) * 3) * cell * 0.12;
      canvas.drawCircle(
        Offset(x, y),
        cell * (0.035 + 0.03 * rng.nextDouble()),
        Paint()..color = heatGlow(min(1, 0.7 + 0.3 * rng.nextDouble())).withValues(alpha: amount * (1 - t) * 0.9),
      );
    }
  }

  void _badge(Canvas canvas, Rect first, int secs, double spent, double beat) {
    final h = max(16.0, first.height * 0.42);
    final urgent = spent > 0.67;
    final text = TextPainter(
      text: TextSpan(
        text: '${secs}s',
        style: letterStyle(h * 0.62, color: urgent ? Colors.white : Palette.darkLetter),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = max(h * 1.5, text.width + h * 0.6);
    final box = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(first.left + w * 0.3, first.top - h * 0.15), width: w, height: h),
      Radius.circular(h / 2),
    );
    final fill = urgent ? Color.lerp(Palette.quenchRed, Palette.ember, beat)! : Palette.molten;
    canvas
      ..drawRRect(
        box.inflate(2),
        Paint()
          ..color = fill.withValues(alpha: 0.6)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, h * 0.25),
      )
      ..drawRRect(box, Paint()..color = fill)
      ..drawRRect(
        box,
        Paint()
          ..color = Palette.whiteHeat.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    text.paint(canvas, box.center - Offset(text.width / 2, text.height / 2));
  }

  @override
  bool shouldRepaint(_HeatPainter old) => old.heat != heat || old.rectOf != rectOf;
}

/// The melt: the word's cells flash white-hot, sag, and run down in drips
/// that fall away, leaving scorched holes. Stays on its last frame.
class MeltOverlay extends StatefulWidget {
  const MeltOverlay({super.key, required this.melt, required this.rectOf, this.animate = true});

  final MeltView melt;
  final CellRect rectOf;

  /// Reduced motion: go straight to the scorched holes.
  final bool animate;

  @override
  State<MeltOverlay> createState() => _MeltOverlayState();
}

class _MeltOverlayState extends State<MeltOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(vsync: this, duration: meltDuration);

  @override
  void initState() {
    super.initState();
    widget.animate ? _t.forward() : _t.value = 1;
  }

  @override
  void didUpdateWidget(MeltOverlay old) {
    super.didUpdateWidget(old);
    if (old.melt.id != widget.melt.id) widget.animate ? _t.forward(from: 0) : _t.value = 1;
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _MeltPainter(cells: widget.melt.cells, rectOf: widget.rectOf, t: _t),
        size: Size.infinite,
      ),
    ),
  );
}

class _MeltPainter extends CustomPainter {
  _MeltPainter({required this.cells, required this.rectOf, required this.t}) : super(repaint: t);

  final List<CellPos> cells;
  final CellRect rectOf;
  final Animation<double> t;

  static const _cooled = Color(0xFF4A1606);

  /// White heat → molten → ember → dull red, as [u] goes 0 → 1.
  static Color _molten(double u) {
    if (u < 0.3) return Color.lerp(Palette.whiteHeat, Palette.molten, u / 0.3)!;
    if (u < 0.65) return Color.lerp(Palette.molten, Palette.ember, (u - 0.3) / 0.35)!;
    return Color.lerp(Palette.ember, _cooled, (u - 0.65) / 0.35)!;
  }

  /// Runs of melting cells stacked in one column: each melts as one mass,
  /// so an upright word runs down into itself and drips off the bottom.
  List<List<CellPos>> get _columns {
    final byX = <int, List<CellPos>>{};
    for (final c in cells) {
      (byX[c.x] ??= []).add(c);
    }
    final runs = <List<CellPos>>[];
    for (final col in byX.values) {
      col.sort((a, b) => a.y.compareTo(b.y));
      var run = <CellPos>[col.first];
      for (final c in col.skip(1)) {
        if (c.y == run.last.y + 1) {
          run.add(c);
        } else {
          runs.add(run);
          run = [c];
        }
      }
      runs.add(run);
    }
    return runs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final v = t.value;
    // Heating up (0–0.25), then the metal runs (0.2–1).
    final flash = Curves.easeOut.transform((v / 0.25).clamp(0.0, 1.0));
    final u = Curves.easeIn.transform(((v - 0.2) / 0.8).clamp(0.0, 1.0));
    for (final cell in cells) {
      final r = rectOf(cell);
      final rr = RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.16));
      // The hole it leaves.
      if (u > 0) {
        final a = (u * 3).clamp(0.0, 1.0);
        canvas
          ..drawRRect(
            rr,
            Paint()
              ..shader = RadialGradient(
                colors: [
                  const Color(0xFF070504).withValues(alpha: a),
                  const Color(0xFF1B0E08).withValues(alpha: a),
                ],
              ).createShader(r),
          )
          ..drawRRect(
            rr.deflate(1),
            Paint()
              ..color = Palette.ember.withValues(alpha: 0.5 * (1 - u) + 0.15)
              ..style = PaintingStyle.stroke
              ..strokeWidth = max(1.5, r.width * 0.04),
          );
      }
      // Glowing before it gives way.
      if (u < 1) {
        canvas.drawRRect(
          rr.inflate(r.width * 0.06 * flash),
          Paint()
            ..color = Palette.molten.withValues(alpha: 0.55 * flash * (1 - u))
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r.width * 0.3),
        );
      }
    }
    for (final (i, run) in _columns.indexed) {
      final strip = rectOf(run.first).expandToInclude(rectOf(run.last));
      _pour(canvas, strip, rectOf(run.first).height, i, flash, u);
    }
  }

  /// A column of metal: it glows, slumps to a puddle at the bottom of
  /// [strip], and runs off it in drips that fall away as droplets.
  void _pour(Canvas canvas, Rect strip, double cell, int seed, double flash, double u) {
    final fade = 1 - ((u - 0.72) / 0.28).clamp(0.0, 1.0);
    if (fade <= 0) return;
    final color = u == 0 ? Color.lerp(Palette.molten, Palette.whiteHeat, flash)! : _molten(u);
    final alpha = (u == 0 ? flash * 0.92 : 0.96) * fade;
    final rng = Random(seed * 7919 + 13);
    // Slumps down to a puddle a quarter of a cell deep, narrowing a little.
    final top = strip.top + (strip.height - cell * 0.25) * Curves.easeInOut.transform(u);
    final bottom = strip.bottom + cell * 0.12 * u;
    final inset = strip.width * 0.08 * u;
    final left = strip.left + inset;
    final right = strip.right - inset;
    final dripW = strip.width * 0.1;
    final drips = [
      for (var d = 0; d < 3; d++)
        (
          x: left + (right - left) * (0.2 + 0.3 * d) + dripW * 0.6 * (rng.nextDouble() - 0.5),
          len: 0.45 + 0.8 * rng.nextDouble(),
        ),
    ];
    double dripEnd(double len) => bottom + cell * (0.15 + 1.2 * u) * len * min(1, u * 2.5);
    final body = Path()
      ..moveTo(left, top + cell * 0.08)
      // A rounded, sagging top.
      ..quadraticBezierTo(left, top, left + (right - left) * 0.2, top)
      ..quadraticBezierTo((left + right) / 2, top + cell * 0.22 * u, right - (right - left) * 0.2, top)
      ..quadraticBezierTo(right, top, right, top + cell * 0.08)
      ..lineTo(right, bottom);
    for (final d in drips.reversed) {
      final end = dripEnd(d.len);
      body
        ..lineTo(d.x + dripW, bottom)
        ..cubicTo(d.x + dripW * 0.4, bottom + (end - bottom) * 0.4, d.x + dripW * 0.9, end, d.x, end)
        ..cubicTo(d.x - dripW * 0.9, end, d.x - dripW * 0.4, bottom + (end - bottom) * 0.4, d.x - dripW, bottom);
    }
    body
      ..lineTo(left, bottom)
      ..close();
    final bounds = Rect.fromLTRB(left, top, right, bottom + cell * 1.5);
    canvas
      ..drawPath(
        body,
        Paint()
          ..color = color.withValues(alpha: alpha * 0.6)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, cell * 0.12),
      )
      ..drawPath(
        body,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(color, Palette.whiteHeat, 0.35)!.withValues(alpha: alpha),
              color.withValues(alpha: alpha),
              Color.lerp(color, _cooled, 0.35)!.withValues(alpha: alpha),
            ],
          ).createShader(bounds),
      );
    // A wet highlight down the left side.
    if (bottom - top > cell * 0.3) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(left + strip.width * 0.14, top + cell * 0.12, left + strip.width * 0.22, bottom - cell * 0.1),
          Radius.circular(strip.width * 0.04),
        ),
        Paint()..color = Colors.white.withValues(alpha: 0.28 * alpha * (1 - u)),
      );
    }
    // Droplets falling off the drips.
    for (final d in drips) {
      final fall = ((u - 0.35) / 0.65).clamp(0.0, 1.0);
      if (fall <= 0) continue;
      final y = dripEnd(d.len) + cell * 3.2 * fall * fall * d.len;
      canvas.drawCircle(
        Offset(d.x, y),
        dripW * (0.75 - 0.3 * fall),
        Paint()..color = _molten(min(1, u + 0.1)).withValues(alpha: (1 - fall) * 0.95),
      );
    }
    _smoke(canvas, strip, cell, seed, u);
  }

  /// A few wisps of smoke rising off the metal.
  void _smoke(Canvas canvas, Rect strip, double cell, int seed, double u) {
    if (u <= 0 || u >= 1) return;
    final rng = Random(seed * 104729 + 7);
    for (var k = 0; k < 3; k++) {
      final x = strip.left + strip.width * (0.2 + 0.6 * rng.nextDouble()) + sin(u * 6 + k) * strip.width * 0.08;
      final y = strip.top - cell * 1.1 * u * (0.6 + 0.5 * rng.nextDouble());
      canvas.drawCircle(
        Offset(x, y),
        cell * (0.12 + 0.2 * u),
        Paint()
          ..color = const Color(0xFF9A928B).withValues(alpha: 0.22 * (1 - u))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, cell * 0.12),
      );
    }
  }

  @override
  bool shouldRepaint(_MeltPainter old) => old.cells != cells || old.rectOf != rectOf;
}

/// A strip over the mold: how long the heated word has left, draining from
/// molten to red. [trailing] shows on the right (saved words, say).
class HeatBar extends StatefulWidget {
  const HeatBar({super.key, required this.heat, this.trailing, this.idle = 'Heating the next word…'});

  final HeatView? heat;
  final Widget? trailing;

  /// Shown while no word is heated.
  final String idle;

  @override
  State<HeatBar> createState() => _HeatBarState();
}

class _HeatBarState extends State<HeatBar> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void didUpdateWidget(HeatBar old) {
    super.didUpdateWidget(old);
    _run();
  }

  /// Ticks only while a word is heated.
  void _run() {
    if (widget.heat != null && !_ticker.isActive) {
      _ticker.start();
    } else if (widget.heat == null && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final heat = widget.heat;
    final text = Theme.of(context).textTheme;
    final left = heat == null ? 0 : heat.remainingMs().clamp(0, heat.durationMs);
    final f = heat == null ? 0.0 : left / max(1, heat.durationMs);
    final color = heatGlow(max(0.35, 1 - f));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          Icon(Icons.local_fire_department, size: 18, color: heat == null ? Palette.steel : color),
          const SizedBox(width: 6),
          Expanded(
            child: heat == null
                ? Text(widget.idle, style: text.labelMedium?.copyWith(color: Palette.steel))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Heated word: ${(left / 1000).ceil()}s',
                        style: text.labelMedium?.copyWith(color: f < 0.34 ? Palette.quenchRed : Palette.whiteHeat),
                      ),
                      const SizedBox(height: 3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: SizedBox(
                          height: 6,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(color: Palette.forgeBlack),
                              FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: f,
                                child: ColoredBox(color: color),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          if (widget.trailing != null) ...[const SizedBox(width: 12), widget.trailing!],
        ],
      ),
    );
  }
}
