import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';

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
  });

  final String letters;
  final List<int> order;
  final double size;

  /// Called on lift with the letters swiped (may be shorter than 3).
  final ValueChanged<String> onSubmit;

  /// Called with the current word whenever the selection changes.
  final ValueChanged<String>? onSelectionChanged;
  final bool enabled;

  @override
  State<AnvilRing> createState() => AnvilRingState();
}

class AnvilRingState extends State<AnvilRing> {
  static const _moveDuration = Duration(milliseconds: 380);

  /// Selected tile indices, in swipe order.
  final List<int> _selected = [];
  Offset? _pointer;
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

  void _clear({bool notify = false}) {
    _selected.clear();
    _pointer = null;
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
      _pointer = e.localPosition;
    });
    widget.onSelectionChanged?.call(_word);
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
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
    setState(() => _pointer = e.localPosition);
    if (changed) widget.onSelectionChanged?.call(_word);
  }

  void _onUp(PointerEvent e) {
    if (e.pointer != _activePointer) return;
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
                child: CustomPaint(
                  painter: _TrailPainter(
                    points: [for (final t in _selected) _tileCenter(t)],
                    pointer: _pointer,
                    width: d * 0.26,
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
                child: LetterTile(
                  letter: widget.letters[tile],
                  hot: _selected.contains(tile),
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
                        color: Palette.ember.withValues(alpha: 0.7),
                        blurRadius: d * 0.35,
                        spreadRadius: d * 0.02,
                      ),
                    ],
                  ),
                ),
              Image.asset(
                hot ? 'assets/images/tile_hot.png' : 'assets/images/tile_cold.png',
                width: d,
                height: d,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => _PaintedTile(hot: hot),
              ),
              Text(
                letter,
                style: letterStyle(
                  d * 0.5,
                  color: hot ? Palette.darkLetter : Palette.whiteHeat,
                ).copyWith(
                  shadows: [
                    Shadow(
                      color: hot
                          ? Palette.whiteHeat.withValues(alpha: 0.5)
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
            ? const [Palette.whiteHeat, Palette.molten, Palette.ember]
            : const [Color(0xFF5A5C62), Color(0xFF3A3B3F), Color(0xFF232427)],
        stops: const [0, 0.55, 1],
      ),
      border: Border.all(
        color: hot ? Palette.molten : const Color(0xFF8A6A4A),
        width: 1.5,
      ),
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
      Image.asset(
        'assets/images/anvil_face.png',
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
      AnimatedOpacity(
        opacity: active ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        child: Image.asset(
          'assets/images/anvil_face_glow.png',
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Palette.ember.withValues(alpha: 0.5),
                width: 3,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class _TrailPainter extends CustomPainter {
  _TrailPainter({required this.points, required this.pointer, required this.width});

  final List<Offset> points;
  final Offset? pointer;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (pointer != null) path.lineTo(pointer!.dx, pointer!.dy);
    Paint stroke(Color c, double w, [double blur = 0]) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = blur > 0 ? MaskFilter.blur(BlurStyle.normal, blur) : null;
    canvas
      ..drawPath(path, stroke(Palette.ember.withValues(alpha: 0.55), width * 1.8, width * 0.6))
      ..drawPath(path, stroke(Palette.ember, width))
      ..drawPath(path, stroke(Palette.molten, width * 0.55))
      ..drawPath(path, stroke(Palette.whiteHeat.withValues(alpha: 0.9), width * 0.18));
  }

  @override
  bool shouldRepaint(_TrailPainter old) =>
      old.pointer != pointer || old.points.length != points.length || old.width != width;
}
