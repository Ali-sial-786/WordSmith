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

/// How a word sent went, for [RuneBoardState.flash].
enum RuneFlash {
  /// Just lit.
  plain,

  /// A word found: its tiles jump.
  good,

  /// Found already: its tiles wobble.
  repeat,

  /// Not a word: its tiles shake.
  bad,
}

/// A Rune Rush grid of letter dice to find words on (shared/rune-rush.md). Swipe
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
    this.reducedMotion = false,
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

  /// No hops, shakes or rising points: the colours alone say how it went.
  final bool reducedMotion;

  @override
  State<RuneBoard> createState() => RuneBoardState();
}

class RuneBoardState extends State<RuneBoard> with TickerProviderStateMixin {
  /// A tile is taken when the finger is this near its middle, counted across
  /// plus down (a diamond, not a circle): the whole way along a row or
  /// column, but well clear of the corners a diagonal swipe cuts past.
  static const _reach = 0.46;

  /// The longest step, in cells, between the points of a swipe that are
  /// looked at: a fast finger jumps further than that between samples.
  static const _step = 0.2;

  /// The tiles traced, in order.
  List<int> _path = [];

  /// The path is being built by taps (it stays between touches).
  bool _tapping = false;

  /// The pointer tracing, the tile it went down on, whether it has moved on
  /// to another tile (a swipe, not a tap), and where it was last.
  int? _pointer;
  int? _down;
  bool _moved = false;
  Offset? _at;

  /// A word just sent, lit in the colour of how it went.
  List<int> _flash = const [];
  Color? _flashColor;
  RuneFlash _flashKind = RuneFlash.plain;
  late final AnimationController _flashing = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  )..addStatusListener(_flashed);

  /// Each tile's hop as it's traced.
  final Map<int, AnimationController> _hops = {};

  /// Points rising off words found.
  final List<_Rising> _rising = [];

  int get _n => widget.size;

  @override
  void didUpdateWidget(RuneBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new grid, or play stopped: drop whatever was being traced.
    if (oldWidget.tiles != widget.tiles || (oldWidget.enabled && !widget.enabled)) _clear(notify: false);
  }

  @override
  void dispose() {
    _flashing.dispose();
    for (final c in _hops.values) {
      c.dispose();
    }
    for (final r in _rising) {
      r.controller.dispose();
    }
    super.dispose();
  }

  /// Lights [path] in [color] for a moment: how a word sent went, with
  /// [label] (its points) rising off its last tile.
  void flash(List<int> path, Color color, {RuneFlash kind = RuneFlash.plain, String? label}) {
    if (!mounted) return;
    setState(() {
      _flash = path;
      _flashColor = color;
      _flashKind = kind;
    });
    _flashing.forward(from: 0);
    if (label != null && path.isNotEmpty && !widget.reducedMotion) _rise(path.last, label, color);
  }

  void _flashed(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) setState(() => _flash = const []);
  }

  void _rise(int tile, String label, Color color) {
    final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    final r = _Rising(tile, label, color, c);
    c.addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      c.dispose();
      if (mounted) setState(() => _rising.remove(r));
    });
    setState(() => _rising.add(r));
    c.forward();
  }

  void _hop(int tile) {
    if (widget.reducedMotion) return;
    (_hops[tile] ??= AnimationController(vsync: this, duration: const Duration(milliseconds: 200))).forward(from: 0);
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
    _at = null;
    if (notify && had) {
      widget.onChanged?.call('');
      if (mounted) setState(() {});
    }
  }

  void _set(List<int> path) {
    if (!mounted) return;
    final grew = path.length > _path.length;
    setState(() => _path = path);
    if (grew) _hop(path.last);
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

  /// The tile under [p] on a board [side] across. [strict]: only within
  /// [_reach] of its middle, so a swipe can cut past a corner on its way to
  /// a diagonal without picking up the tile beside it.
  int? _hit(Offset p, double side, {bool strict = false}) {
    if (p.dx < 0 || p.dy < 0 || p.dx >= side || p.dy >= side) return null;
    final cell = side / _n;
    final c = (p.dx / cell).floor().clamp(0, _n - 1);
    final r = (p.dy / cell).floor().clamp(0, _n - 1);
    if (strict) {
      final off = p - Offset((c + 0.5) * cell, (r + 0.5) * cell);
      if (off.dx.abs() + off.dy.abs() > cell * _reach) return null;
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
    _at = e.localPosition;
    // A swipe starts at once; a tap waits to see what it is.
    if (!_tapping || _path.isEmpty) _set([t]);
  }

  void _onMove(PointerMoveEvent e, double side) {
    // A finger still moving as the round ends and the board goes.
    if (!mounted || e.pointer != _pointer || !widget.enabled) return;
    _trace(e.localPosition, side);
  }

  /// Follows the finger from where it was to [to], looking at every point
  /// along the way: samples come far apart on a fast swipe, and a tile in
  /// between (the middle of a diagonal, say) mustn't be skipped.
  void _trace(Offset to, double side) {
    final from = _at ?? to;
    _at = to;
    final steps = max(1, ((to - from).distance / (side / _n * _step)).ceil());
    for (var k = 1; k <= steps && mounted && _pointer != null; k++) {
      _visit(Offset.lerp(from, to, k / steps)!, side);
    }
  }

  void _visit(Offset p, double side) {
    final t = _hit(p, side, strict: true);
    if (t == null || t == _down && !_moved) return;
    if (!_moved) {
      _moved = true;
      // Swiping from a word being tapped out starts a new one.
      if (_tapping) {
        _tapping = false;
        _path = [_down!];
      }
    }
    if (_path.isEmpty || t == _path.last) return;
    if (_path.length >= 2 && t == _path[_path.length - 2]) {
      _set(_path.sublist(0, _path.length - 1));
    } else if (!_path.contains(t) && runeTilesTouch(_path.last, t, _n)) {
      _set([..._path, t]);
    }
  }

  void _onUp(PointerUpEvent e, double side) {
    if (!mounted || e.pointer != _pointer) return;
    // The last stretch of a swipe, up to where the finger lifted.
    if (_moved && widget.enabled) _trace(e.localPosition, side);
    _pointer = null;
    _at = null;
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

  /// Tile [i] hopping as it's traced, and jumping, wobbling or shaking with
  /// the word it was in.
  Widget _moving(int i, double cell, Widget child) {
    final hop = _hops[i];
    final flashing = _flash.contains(i) && !widget.reducedMotion && _flashKind != RuneFlash.plain;
    if (hop == null && !flashing) return child;
    return AnimatedBuilder(
      animation: Listenable.merge([?hop, if (flashing) _flashing]),
      child: child,
      builder: (context, child) {
        var scale = 1.0;
        var dx = 0.0;
        var turn = 0.0;
        if (hop != null && hop.isAnimating) scale += 0.14 * sin(pi * hop.value);
        if (flashing) {
          final t = _flashing.value;
          switch (_flashKind) {
            case RuneFlash.good:
              // Staggered along the word, first tile first.
              final at = (t * 1.6 - 0.6 * _flash.indexOf(i) / max(1, _flash.length - 1)).clamp(0.0, 1.0);
              scale += 0.16 * sin(pi * at);
            case RuneFlash.repeat:
              turn = sin(t * pi * 4) * 0.09 * (1 - t);
            case RuneFlash.bad:
              dx = sin(t * pi * 6) * cell * 0.07 * (1 - t);
            case RuneFlash.plain:
              break;
          }
        }
        if (scale == 1 && dx == 0 && turn == 0) return child!;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.translationValues(dx, 0, 0)
            ..rotateZ(turn)
            ..scaleByDouble(scale, scale, 1, 1),
          child: child,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final side = min(c.maxWidth, c.maxHeight);
        final cell = side / _n;
        final flashing = _flash.isNotEmpty;
        final path = flashing ? _flash : (_path.isNotEmpty ? _path : widget.highlight);
        final lit = flashing ? _DieLook.lit(_flashColor!) : _DieLook.hot();
        final cold = _DieLook.cold();
        final word = runeWordOf(widget.tiles, _path);
        final rim = cell * 0.1;
        Offset centre(int i) => Offset((_shown(i).$2 + 0.5) * cell, (_shown(i).$1 + 0.5) * cell);
        Widget place(int i, Widget child) {
          final (r, col) = _shown(i);
          return Positioned(left: col * cell, top: r * cell, width: cell, height: cell, child: _moving(i, cell, child));
        }

        return Center(
          child: Semantics(
            label: 'Letter grid, $_n by $_n${word.isEmpty ? '' : ', tracing $word'}',
            child: Listener(
              onPointerDown: (e) => _onDown(e, side),
              onPointerMove: (e) => _onMove(e, side),
              onPointerUp: (e) => _onUp(e, side),
              onPointerCancel: _onCancel,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                key: const ValueKey('rune-board'),
                width: side,
                height: side,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // The tray the dice sit in, a little wider than the grid.
                    Positioned(
                      left: -rim,
                      top: -rim,
                      right: -rim,
                      bottom: -rim,
                      child: _Tray(radius: cell * 0.22 + rim),
                    ),
                    for (var i = 0; i < widget.tiles.length; i++)
                      place(
                        i,
                        _DieFace(
                          key: ValueKey('rune-tile-$i'),
                          size: cell,
                          look: path.contains(i) ? lit : cold,
                          first: path.length > 1 && path.first == i,
                        ),
                      ),
                    if (path.length > 1)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _TracePainter(
                              points: [for (final i in path) centre(i)],
                              color: lit.glow!,
                              width: cell,
                            ),
                          ),
                        ),
                      ),
                    // The letters over the line, so it never hides them.
                    for (var i = 0; i < widget.tiles.length; i++)
                      place(
                        i,
                        IgnorePointer(
                          child: _DieLetter(letter: widget.tiles[i], size: cell, look: path.contains(i) ? lit : cold),
                        ),
                      ),
                    for (final r in _rising)
                      Positioned(
                        key: ObjectKey(r),
                        left: centre(r.tile).dx - cell,
                        top: centre(r.tile).dy - cell * 0.5,
                        width: cell * 2,
                        height: cell,
                        child: IgnorePointer(
                          child: _RisingLabel(rising: r, cell: cell),
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

/// A die's colours: its face from top to bottom, the depth under it, its
/// letter, and the glow round it when lit.
class _DieLook {
  const _DieLook({required this.top, required this.bottom, required this.side, required this.ink, this.glow});

  final Color top;
  final Color bottom;
  final Color side;
  final Color ink;
  final Color? glow;

  /// Bone-pale dice with dark letters, on a dark scheme or a light one.
  factory _DieLook.cold() {
    if (Palette.isLight) {
      return _DieLook(
        top: Color.lerp(Palette.soot, Colors.white, 0.7)!,
        bottom: Color.lerp(Palette.soot, Palette.ash, 0.35)!,
        side: Color.lerp(Palette.ash, Palette.whiteHeat, 0.4)!,
        ink: Palette.whiteHeat,
      );
    }
    return _DieLook(
      top: Color.lerp(Palette.whiteHeat, Colors.white, 0.45)!,
      bottom: Color.lerp(Palette.whiteHeat, Palette.molten, 0.3)!,
      side: Color.lerp(Palette.rim, Palette.forgeBlack, 0.35)!,
      ink: Palette.darkLetter,
    );
  }

  /// Being traced: hot from the fire, in the scheme's accent.
  factory _DieLook.hot() => _DieLook.lit(Palette.ember, top: Color.lerp(Palette.molten, Colors.white, 0.3));

  /// Lit in [color] (a word just sent, by how it went).
  factory _DieLook.lit(Color color, {Color? top}) => _DieLook(
    top: top ?? Color.lerp(color, Colors.white, 0.45)!,
    bottom: color,
    side: Color.lerp(color, Colors.black, 0.5)!,
    ink: color.computeLuminance() > 0.22 ? Palette.darkLetter : Colors.white,
    glow: color,
  );
}

/// Where a die's face sits in its cell: inset, and lifted by its depth.
EdgeInsets _faceInsets(double cell) {
  final pad = cell * 0.065;
  final depth = cell * 0.06;
  return EdgeInsets.fromLTRB(pad, pad - depth * 0.5, pad, pad + depth * 0.5);
}

class _DieFace extends StatelessWidget {
  const _DieFace({super.key, required this.size, required this.look, required this.first});

  final double size;
  final _DieLook look;

  /// Where the word starts: a white-hot ring.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.2);
    final depth = size * 0.06;
    final glow = look.glow;
    return Padding(
      padding: _faceInsets(size),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [look.top, look.bottom],
          ),
          border: Border.all(
            color: first ? Colors.white : Color.lerp(look.side, look.top, 0.35)!,
            width: first ? max(2.5, size * 0.04) : 1,
          ),
          boxShadow: [
            if (glow != null)
              BoxShadow(color: glow.withValues(alpha: 0.7), blurRadius: size * 0.3, spreadRadius: size * 0.02),
            // The die's side, under its face.
            BoxShadow(color: look.side, offset: Offset(0, depth)),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              offset: Offset(0, depth + size * 0.02),
              blurRadius: size * 0.08,
            ),
          ],
        ),
        // A sheen across the top of the face.
        child: Padding(
          padding: EdgeInsets.all(size * 0.045),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 0.15),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.5],
                colors: [Colors.white.withValues(alpha: 0.5), Colors.white.withValues(alpha: 0)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DieLetter extends StatelessWidget {
  const _DieLetter({required this.letter, required this.size, required this.look});

  final String letter;
  final double size;
  final _DieLook look;

  @override
  Widget build(BuildContext context) {
    final shown = letter == 'QU' ? 'Qu' : letter;
    final dark = look.ink.computeLuminance() < 0.3;
    return Padding(
      padding: _faceInsets(size),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            shown,
            style: letterStyle(size * (shown.length > 1 ? 0.44 : 0.56), color: look.ink).copyWith(
              // Cut into the face: lit from above.
              shadows: [
                Shadow(
                  color: dark ? Colors.white.withValues(alpha: 0.55) : Colors.black.withValues(alpha: 0.4),
                  offset: Offset(0, dark ? size * 0.015 : -size * 0.012),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The dark tray the dice sit in, rimmed in the frames' metal.
class _Tray extends StatelessWidget {
  const _Tray({required this.radius});

  final double radius;

  @override
  Widget build(BuildContext context) {
    final light = Palette.isLight;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: light
              ? [Color.lerp(Palette.ash, Palette.soot, 0.3)!, Palette.ash]
              : [
                  Color.lerp(Palette.soot, Palette.forgeBlack, 0.2)!.withValues(alpha: 0.94),
                  Palette.forgeBlack.withValues(alpha: 0.94),
                ],
        ),
        border: Border.all(color: Palette.rim.withValues(alpha: 0.85), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: light ? 0.2 : 0.55),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
    );
  }
}

/// The line joining a traced word's tiles: a glow with a white-hot core.
class _TracePainter extends CustomPainter {
  _TracePainter({required this.points, required this.color, required this.width});

  final List<Offset> points;
  final Color color;

  /// A cell across.
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas
      // A dark edge, so the line shows across the lit dice too…
      ..drawPath(path, stroke(Color.lerp(color, Colors.black, 0.45)!.withValues(alpha: 0.55), width * 0.2))
      // …then the glow, and its white-hot core.
      ..drawPath(path, stroke(Color.lerp(color, Colors.white, 0.3)!, width * 0.14))
      ..drawPath(path, stroke(Color.lerp(color, Colors.white, 0.85)!, width * 0.06));
    // A bead on each tile but the last, where the finger is.
    final bead = Paint()..color = Color.lerp(color, Colors.white, 0.85)!;
    for (final p in points.take(points.length - 1)) {
      canvas.drawCircle(p, width * 0.085, bead);
    }
  }

  @override
  bool shouldRepaint(_TracePainter old) =>
      old.color != color || old.width != width || old.points.length != points.length || !_same(old.points, points);

  static bool _same(List<Offset> a, List<Offset> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Points rising off a word's last tile.
class _Rising {
  _Rising(this.tile, this.label, this.color, this.controller);

  final int tile;
  final String label;
  final Color color;
  final AnimationController controller;
}

class _RisingLabel extends StatelessWidget {
  const _RisingLabel({required this.rising, required this.cell});

  final _Rising rising;
  final double cell;

  @override
  Widget build(BuildContext context) {
    final style = letterStyle(cell * 0.5, color: Palette.gold);
    return AnimatedBuilder(
      animation: rising.controller,
      builder: (context, _) {
        final t = rising.controller.value;
        final fade = t < 0.65 ? 1.0 : (1 - t) / 0.35;
        final grow = t < 0.2 ? 0.6 + 0.6 * Curves.easeOut.transform(t / 0.2) : 1.2 - 0.2 * ((t - 0.2) / 0.8);
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.translationValues(0, -cell * (0.45 + 0.8 * Curves.easeOut.transform(t)), 0)
            ..scaleByDouble(grow, grow, 1, 1),
          child: Center(
            child: Text(
              rising.label,
              style: style.copyWith(
                color: Color.lerp(Palette.gold, Colors.white, 0.25)!.withValues(alpha: fade),
                shadows: [
                  // A dark edge all round, so it reads over the dice.
                  for (final o in const [Offset(1.5, 1.5), Offset(-1.5, 1.5), Offset(1.5, -1.5), Offset(-1.5, -1.5)])
                    Shadow(
                      color: Palette.darkLetter.withValues(alpha: 0.9 * fade),
                      offset: o,
                    ),
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.7 * fade),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                  Shadow(color: Palette.gold.withValues(alpha: 0.7 * fade), blurRadius: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
