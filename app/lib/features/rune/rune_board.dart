import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';

/// Tiles [a] and [b] (row by row on a [size]×[size] grid) touch: across, up
/// and down, or diagonally.
bool runeTilesTouch(int a, int b, int size) {
  if (a == b) return false;
  return (a ~/ size - b ~/ size).abs() <= 1 && (a % size - b % size).abs() <= 1;
}

/// The word a path of tiles spells.
String runeWordOf(List<String> tiles, List<int> path) => [for (final i in path) tiles[i]].join();

/// A Rune Grid of letter dice to find words on (shared/rune-grid.md). Swipe
/// through touching tiles and let go to send the word; or tap tiles one by
/// one and tap the last again to send it. Going back over the tile before
/// takes the last one off. [quarterTurns] turns the grid (the letters stay
/// upright); [highlight] marks a word's path, for looking back at a round.
class RuneBoard extends StatefulWidget {
  const RuneBoard({
    super.key,
    required this.tiles,
    required this.size,
    this.enabled = true,
    this.quarterTurns = 0,
    this.onChanged,
    this.onSubmit,
    this.highlight = const [],
  });

  /// Row by row; a tile is a letter or `QU`.
  final List<String> tiles;
  final int size;
  final bool enabled;
  final int quarterTurns;

  /// The word traced so far, as it changes ('' once it's sent or dropped).
  final ValueChanged<String>? onChanged;

  /// A word traced and let go (or tapped twice at its end), with its path.
  final void Function(String word, List<int> path)? onSubmit;
  final List<int> highlight;

  @override
  State<RuneBoard> createState() => RuneBoardState();
}

class RuneBoardState extends State<RuneBoard> {
  /// The tiles traced, in order.
  List<int> _path = [];

  /// The path is being built by taps (it stays between touches).
  bool _tapping = false;

  /// The pointer tracing, the tile it went down on, and whether it has
  /// moved on to another tile (a swipe, not a tap).
  int? _pointer;
  int? _down;
  bool _moved = false;

  /// A word just sent, lit in the colour of how it went.
  List<int> _flash = const [];
  Color? _flashColor;
  Timer? _flashTimer;

  int get _n => widget.size;

  @override
  void didUpdateWidget(RuneBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new grid, or play stopped: drop whatever was being traced.
    if (oldWidget.tiles != widget.tiles || (oldWidget.enabled && !widget.enabled)) _clear(notify: false);
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    super.dispose();
  }

  /// Lights [path] in [color] for a moment: how a word sent went.
  void flash(List<int> path, Color color) {
    _flashTimer?.cancel();
    setState(() {
      _flash = path;
      _flashColor = color;
    });
    _flashTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _flash = const []);
    });
  }

  /// Drops the word being traced.
  void clear() => _clear();

  void _clear({bool notify = true}) {
    final had = _path.isNotEmpty;
    _path = [];
    _tapping = false;
    _pointer = null;
    _down = null;
    _moved = false;
    if (notify && had) {
      widget.onChanged?.call('');
      if (mounted) setState(() {});
    }
  }

  void _set(List<int> path) {
    setState(() => _path = path);
    widget.onChanged?.call(runeWordOf(widget.tiles, path));
  }

  void _send() {
    final path = _path;
    final word = runeWordOf(widget.tiles, path);
    _path = [];
    _tapping = false;
    setState(() {});
    widget.onChanged?.call('');
    if (path.isNotEmpty) widget.onSubmit?.call(word, path);
  }

  /// Where a tile shown at row [r], column [c] is on the grid itself.
  int _logical(int r, int c) {
    var (row, col) = (r, c);
    for (var i = 0; i < widget.quarterTurns % 4; i++) {
      (row, col) = (_n - 1 - col, row);
    }
    return row * _n + col;
  }

  /// Where tile [i] shows: the grid turned [quarterTurns] times clockwise.
  (int, int) _shown(int i) {
    var (row, col) = (i ~/ _n, i % _n);
    for (var t = 0; t < widget.quarterTurns % 4; t++) {
      (row, col) = (col, _n - 1 - row);
    }
    return (row, col);
  }

  /// The tile under [p] on a board [side] across. [strict]: only near its
  /// middle, so a swipe can pass a corner on its way to a diagonal.
  int? _hit(Offset p, double side, {bool strict = false}) {
    if (p.dx < 0 || p.dy < 0 || p.dx >= side || p.dy >= side) return null;
    final cell = side / _n;
    final c = (p.dx / cell).floor().clamp(0, _n - 1);
    final r = (p.dy / cell).floor().clamp(0, _n - 1);
    if (strict) {
      final centre = Offset((c + 0.5) * cell, (r + 0.5) * cell);
      if ((p - centre).distance > cell * 0.42) return null;
    }
    return _logical(r, c);
  }

  void _onDown(PointerDownEvent e, double side) {
    if (!widget.enabled || _pointer != null) return;
    final t = _hit(e.localPosition, side);
    if (t == null) {
      // Off the grid: drop a word being tapped out.
      if (_tapping) _clear();
      return;
    }
    _pointer = e.pointer;
    _down = t;
    _moved = false;
    // A swipe starts at once; a tap waits to see what it is.
    if (!_tapping || _path.isEmpty) _set([t]);
  }

  void _onMove(PointerMoveEvent e, double side) {
    if (e.pointer != _pointer || !widget.enabled) return;
    final t = _hit(e.localPosition, side, strict: true);
    if (t == null || t == _down && !_moved) return;
    if (!_moved) {
      _moved = true;
      // Swiping from a word being tapped out starts a new one.
      if (_tapping) {
        _tapping = false;
        _path = [_down!];
      }
    }
    if (t == _path.last) return;
    if (_path.length >= 2 && t == _path[_path.length - 2]) {
      _set(_path.sublist(0, _path.length - 1));
    } else if (!_path.contains(t) && runeTilesTouch(_path.last, t, _n)) {
      _set([..._path, t]);
    }
  }

  void _onUp(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final down = _down;
    _down = null;
    if (!widget.enabled || down == null) return;
    if (_moved) {
      _moved = false;
      _send();
      return;
    }
    // A tap.
    if (!_tapping) {
      _tapping = true;
      return;
    }
    if (_path.isEmpty) {
      _set([down]);
    } else if (down == _path.last) {
      _send();
    } else if (!_path.contains(down) && runeTilesTouch(_path.last, down, _n)) {
      _set([..._path, down]);
    } else if (_path.contains(down)) {
      _set(_path.sublist(0, _path.indexOf(down) + 1));
    } else {
      _set([down]);
    }
  }

  void _onCancel(PointerCancelEvent e) {
    if (e.pointer == _pointer) _clear();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final side = min(c.maxWidth, c.maxHeight);
        final cell = side / _n;
        final path = _flash.isNotEmpty ? _flash : (_path.isNotEmpty ? _path : widget.highlight);
        final traceColor = _flash.isNotEmpty ? _flashColor! : Palette.molten;
        final word = runeWordOf(widget.tiles, _path);
        return Center(
          child: Semantics(
            label: 'Letter grid, $_n by $_n${word.isEmpty ? '' : ', tracing $word'}',
            child: Listener(
              onPointerDown: (e) => _onDown(e, side),
              onPointerMove: (e) => _onMove(e, side),
              onPointerUp: _onUp,
              onPointerCancel: _onCancel,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                key: const ValueKey('rune-board'),
                width: side,
                height: side,
                child: Stack(
                  children: [
                    for (var i = 0; i < widget.tiles.length; i++)
                      Builder(
                        builder: (context) {
                          final (r, col) = _shown(i);
                          return Positioned(
                            left: col * cell,
                            top: r * cell,
                            width: cell,
                            height: cell,
                            child: _Tile(
                              key: ValueKey('rune-tile-$i'),
                              letter: widget.tiles[i],
                              size: cell,
                              lit: path.contains(i),
                              first: path.isNotEmpty && path.first == i,
                              color: traceColor,
                            ),
                          );
                        },
                      ),
                    if (path.length > 1)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _TracePainter(
                              points: [
                                for (final i in path) Offset((_shown(i).$2 + 0.5) * cell, (_shown(i).$1 + 0.5) * cell),
                              ],
                              color: traceColor,
                              width: max(5, cell * 0.14),
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
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.letter,
    required this.size,
    required this.lit,
    required this.first,
    required this.color,
  });

  final String letter;
  final double size;
  final bool lit;
  final bool first;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pad = size * 0.06;
    final shown = letter == 'QU' ? 'Qu' : letter;
    return Padding(
      padding: EdgeInsets.all(pad),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: lit
                ? [Color.lerp(color, Palette.whiteHeat, 0.25)!, color]
                : [Color.lerp(Palette.iron, Palette.steel, 0.25)!, Palette.soot],
          ),
          border: Border.all(color: lit ? Palette.whiteHeat : Palette.ash, width: first ? 3 : 1.2),
          boxShadow: [
            if (lit) BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: size * 0.2),
            BoxShadow(color: Palette.forgeBlack.withValues(alpha: 0.5), offset: Offset(0, size * 0.04)),
          ],
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            shown,
            style: letterStyle(
              size * (shown.length > 1 ? 0.42 : 0.52),
              color: lit ? Palette.darkLetter : Palette.whiteHeat,
            ),
          ),
        ),
      ),
    );
  }
}

/// The line joining a traced word's tiles.
class _TracePainter extends CustomPainter {
  _TracePainter({required this.points, required this.color, required this.width});

  final List<Offset> points;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Color.lerp(color, Palette.forgeBlack, 0.35)!.withValues(alpha: 0.8)
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TracePainter old) => old.points != points || old.color != color || old.width != width;
}
