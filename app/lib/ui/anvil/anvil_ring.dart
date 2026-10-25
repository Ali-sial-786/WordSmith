import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';
import '../widgets/forge_frame.dart';

/// The letter ring on the anvil face. Swipe across tiles to build a word;
/// swipe back onto the previous tile to drop the last letter; lift to submit.
///
/// [letters] never changes for a puzzle. [order] maps ring positions to tile
/// indices, so a Turn (shuffle) just passes a new order and the tiles glide
/// to their new places.
class AnvilRing extends StatefulWidget {
  const AnvilRing({
    super.key,
    required this.letters,
    required this.order,
    required this.size,
    required this.onSubmit,
    this.onSelectionChanged,
    this.enabled = true,
    this.guide,
  });

  final String letters;
  final List<int> order;
  final double size;

  /// Called on lift with the letters swiped (may be shorter than 3).
  final ValueChanged<String> onSubmit;

  /// Called with the current word whenever the selection changes.
  final ValueChanged<String>? onSelectionChanged;
  final bool enabled;

  /// Tiles to show a hand swiping through, to teach a first-time player.
  final List<int>? guide;

  @override
  State<AnvilRing> createState() => AnvilRingState();
}

class AnvilRingState extends State<AnvilRing> {
  static const _moveDuration = Duration(milliseconds: 380);

  /// Selected tile indices, in swipe order.
  final List<int> _selected = [];

  /// Where the finger is. Only the trail follows it, so moving between
  /// tiles repaints the trail without rebuilding the ring.
  final _pointer = ValueNotifier<Offset?>(null);
  int? _activePointer;
  bool _moving = false;

  int get _n => widget.letters.length;

  double get _tileDiameter {
    final f = switch (_n) {
      <= 4 => 0.29,
      5 => 0.27,
      6 => 0.25,
      7 => 0.23,
      _ => 0.21,
    };
    return widget.size * f;
  }

  double get _ringRadius => widget.size * (_n <= 4 ? 0.29 : 0.325);

  Offset _positionCenter(int position) {
    final angle = -pi / 2 + position * 2 * pi / _n;
    final c = widget.size / 2;
    return Offset(c + cos(angle) * _ringRadius, c + sin(angle) * _ringRadius);
  }

  Offset _tileCenter(int tile) => _positionCenter(widget.order.indexOf(tile));

  int? _tileAt(Offset p, double radiusFactor) {
    final r = _tileDiameter / 2 * radiusFactor;
    for (var tile = 0; tile < _n; tile++) {
      if ((_tileCenter(tile) - p).distance <= r) return tile;
    }
    return null;
  }

  String get _word => _selected.map((t) => widget.letters[t]).join();

  @override
  void didUpdateWidget(AnvilRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_listEquals(oldWidget.order, widget.order)) {
      _moving = true;
      _clear(notify: true);
      Future.delayed(_moveDuration, () {
        if (mounted) setState(() => _moving = false);
      });
    }
  }

  @override
  void dispose() {
    _pointer.dispose();
    super.dispose();
  }

  void _clear({bool notify = false}) {
    _selected.clear();
    _pointer.value = null;
    _activePointer = null;
    if (notify) widget.onSelectionChanged?.call('');
  }

  bool get _acceptsInput => widget.enabled && !_moving;

  void _onDown(PointerDownEvent e) {
    if (!_acceptsInput || _activePointer != null) return;
    final tile = _tileAt(e.localPosition, 1.0);
    if (tile == null) return;
    setState(() {
      _activePointer = e.pointer;
      _selected
        ..clear()
        ..add(tile);
    });
    _pointer.value = e.localPosition;
    widget.onSelectionChanged?.call(_word);
  }

  void _onMove(PointerMoveEvent e) {
    // A finger still moving as the puzzle closes.
    if (!mounted || e.pointer != _activePointer) return;
    final tile = _tileAt(e.localPosition, 0.8);
    var changed = false;
    if (tile != null) {
      if (_selected.length >= 2 && tile == _selected[_selected.length - 2]) {
        _selected.removeLast();
        changed = true;
      } else if (!_selected.contains(tile)) {
        _selected.add(tile);
        changed = true;
      }
    }
    _pointer.value = e.localPosition;
    if (changed) {
      setState(() {});
      widget.onSelectionChanged?.call(_word);
    }
  }

  void _onUp(PointerEvent e) {
    if (!mounted || e.pointer != _activePointer) return;
    final word = _word;
    setState(_clear);
    widget.onSelectionChanged?.call('');
    if (word.isNotEmpty && e is PointerUpEvent) widget.onSubmit(word);
  }

  @override
  Widget build(BuildContext context) {
    final d = _tileDiameter;
    final s = widget.size;
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      behavior: HitTestBehavior.opaque,
      child: SizedBox.square(
        dimension: s,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: _AnvilFace(active: _selected.isNotEmpty)),
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _TrailPainter(
                      points: [for (final t in _selected) _tileCenter(t)],
                      pointer: _pointer,
                      width: d * 0.26,
                    ),
                  ),
                ),
              ),
            ),
            for (var tile = 0; tile < _n; tile++)
              AnimatedPositioned(
                key: ValueKey(tile),
                duration: _moveDuration,
                curve: Curves.easeInOutBack,
                left: _tileCenter(tile).dx - d / 2,
                top: _tileCenter(tile).dy - d / 2,
                width: d,
                height: d,
                child: LetterTile(letter: widget.letters[tile], hot: _selected.contains(tile)),
              ),
            if (widget.guide case final guide? when _selected.isEmpty && !_moving && guide.length > 1)
              Positioned.fill(
                child: IgnorePointer(
                  child: SwipeGuide(points: [for (final t in guide) _tileCenter(t)], size: d),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A round forged-iron tile with its letter. Hot while selected.
class LetterTile extends StatelessWidget {
  const LetterTile({super.key, required this.letter, required this.hot});

  final String letter;
  final bool hot;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final d = c.maxWidth;
        return AnimatedScale(
          scale: hot ? 1.1 : 1,
          duration: const Duration(milliseconds: 120),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (hot)
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Palette.fire.ember.withValues(alpha: 0.7),
                        blurRadius: d * 0.35,
                        spreadRadius: d * 0.02,
                      ),
                    ],
                  ),
                ),
              // The hot tile glows fire-orange in every scheme.
              SchemeIron(
                enabled: !hot,
                child: Image.asset(
                  hot ? 'assets/images/tile_hot.png' : 'assets/images/tile_cold.png',
                  width: d,
                  height: d,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => _PaintedTile(hot: hot),
                ),
              ),
              Text(
                letter,
                style: letterStyle(d * 0.5, color: hot ? Palette.darkLetter : Palette.whiteHeat).copyWith(
                  shadows: [
                    Shadow(
                      color: hot
                          ? Palette.fire.white.withValues(alpha: 0.5)
                          : Palette.isLight
                          ? Colors.white.withValues(alpha: 0.6)
                          : Colors.black.withValues(alpha: 0.7),
                      offset: Offset(0, d * 0.015),
                      blurRadius: d * 0.03,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PaintedTile extends StatelessWidget {
  const _PaintedTile({required this.hot});

  final bool hot;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        center: const Alignment(-0.3, -0.35),
        colors: hot
            ? [Palette.fire.white, Palette.fire.molten, Palette.fire.ember]
            : const [Color(0xFF5A5C62), Color(0xFF3A3B3F), Color(0xFF232427)],
        stops: const [0, 0.55, 1],
      ),
      border: Border.all(color: hot ? Palette.fire.molten : const Color(0xFF8A6A4A), width: 1.5),
    ),
  );
}

class _AnvilFace extends StatelessWidget {
  const _AnvilFace({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      SchemeIron(
        child: Image.asset(
          'assets/images/anvil_face.webp',
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0xFF2E2A28), Color(0xFF221D1A), Color(0xFF151110)],
                stops: [0, 0.8, 1],
              ),
              boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 24)],
            ),
          ),
        ),
      ),
      AnimatedOpacity(
        opacity: active ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        child: Image.asset(
          'assets/images/anvil_face_glow.webp',
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Palette.fire.ember.withValues(alpha: 0.5), width: 3),
            ),
          ),
        ),
      ),
    ],
  );
}

class _TrailPainter extends CustomPainter {
  _TrailPainter({required this.points, required this.pointer, required this.width}) : super(repaint: pointer);

  final List<Offset> points;

  /// The trail's loose end, following the finger.
  final ValueListenable<Offset?>? pointer;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (pointer?.value case final p?) path.lineTo(p.dx, p.dy);
    Paint stroke(Color c, double w, [double blur = 0]) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = blur > 0 ? MaskFilter.blur(BlurStyle.normal, blur) : null;
    canvas
      ..drawPath(path, stroke(Palette.fire.ember.withValues(alpha: 0.55), width * 1.8, width * 0.6))
      ..drawPath(path, stroke(Palette.fire.ember, width))
      ..drawPath(path, stroke(Palette.fire.molten, width * 0.55))
      ..drawPath(path, stroke(Palette.fire.white.withValues(alpha: 0.9), width * 0.18));
  }

  @override
  bool shouldRepaint(_TrailPainter old) =>
      old.pointer != pointer || !listEquals(old.points, points) || old.width != width;
}

/// A hand tracing a swipe through [points], over and over.
class SwipeGuide extends StatefulWidget {
  const SwipeGuide({super.key, required this.points, required this.size});

  final List<Offset> points;

  /// Tile diameter, to size the hand and trail.
  final double size;

  @override
  State<SwipeGuide> createState() => _SwipeGuideState();
}

class _SwipeGuideState extends State<SwipeGuide> with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 900 + 500 * widget.points.length),
  )..repeat();

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  /// The point a fraction [f] (0–1) of the way along the path.
  Offset _along(double f) {
    final pts = widget.points;
    final segments = pts.length - 1;
    final x = (f * segments).clamp(0.0, segments.toDouble());
    final i = x.floor().clamp(0, segments - 1);
    return Offset.lerp(pts[i], pts[i + 1], x - i)!;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _loop,
    builder: (context, _) {
      final t = _loop.value;
      // Rest on the first tile, trace the word, then fade out.
      final move = Curves.easeInOut.transform(((t - 0.12) / 0.66).clamp(0.0, 1.0));
      final fade = t < 0.08
          ? t / 0.08
          : t > 0.85
          ? (1 - t) / 0.15
          : 1.0;
      final head = _along(move);
      final path = [
        widget.points.first,
        for (var i = 1; i < widget.points.length && i / (widget.points.length - 1) <= move; i++) widget.points[i],
        head,
      ];
      return Opacity(
        opacity: 0.8 * fade.clamp(0.0, 1.0),
        child: CustomPaint(
          painter: _TrailPainter(points: path, pointer: null, width: widget.size * 0.14),
          child: Stack(
            children: [
              Positioned(
                left: head.dx - widget.size * 0.1,
                top: head.dy - widget.size * 0.05,
                child: Icon(
                  Icons.touch_app,
                  size: widget.size * 0.75,
                  color: Palette.whiteHeat,
                  shadows: const [Shadow(color: Colors.black87, blurRadius: 8)],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
