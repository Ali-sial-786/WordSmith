import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../engine/puzzle.dart';
import '../effects/sparks.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import '../widgets/forge_frame.dart';
import 'hammer_strike.dart';
import 'mold_model.dart';
import 'survival_overlay.dart';

export 'hammer_strike.dart' show HammerStrike, hammerImpact;
export 'mold_model.dart';
export 'survival_overlay.dart';

/// Per-cell animation cues handed down by the puzzle screen.
class MoldCues {
  MoldCues();

  /// Delay before a newly filled cell starts its pour, so a word fills
  /// letter by letter.
  final Map<CellPos, Duration> fillDelay = {};

  /// Bumped to make cells pulse (e.g. "already forged").
  final Map<CellPos, int> flash = {};

  /// Hammer Strikes still swinging (the latest few), each with its own id.
  /// A strike leaves once its swing is over, so a rebuilt grid never plays
  /// it again.
  final List<({CellPos cell, int id})> strikes = [];
  int _strikes = 0;

  /// Cells a hammer has struck: their reveal throws more sparks.
  final Set<CellPos> struck = {};

  void stagger(
    List<CellPos> cells, {
    Duration step = const Duration(milliseconds: 70),
    Duration start = Duration.zero,
  }) {
    for (var i = 0; i < cells.length; i++) {
      fillDelay[cells[i]] = start + step * i;
    }
  }

  /// A Hammer Strike on [cell]: the hammer swings down onto it, and its
  /// letter (and the words it [completed]) show as it lands.
  void strike(CellPos cell, {Iterable<List<CellPos>> completed = const []}) {
    strikes.add((cell: cell, id: ++_strikes));
    if (strikes.length > 3) strikes.removeAt(0);
    struck.add(cell);
    fillDelay[cell] = hammerImpact;
    for (final cells in completed) {
      stagger(cells, start: hammerImpact);
    }
  }

  /// The swing of strike [id] is over.
  void retire(int id) => strikes.removeWhere((s) => s.id == id);

  /// A new round or puzzle: forget everything.
  void clear() {
    fillDelay.clear();
    flash.clear();
    strikes.clear();
    struck.clear();
  }

  void pulse(Iterable<CellPos> cells) {
    for (final c in cells) {
      flash[c] = (flash[c] ?? 0) + 1;
    }
  }
}

/// The crossword grid ("the mold").
class MoldGrid extends StatelessWidget {
  const MoldGrid({
    super.key,
    required this.mold,
    required this.metal,
    required this.cues,
    this.chiselMode = false,
    this.onCellTap,
    this.onFilledTap,
    this.maxCell = 80,
    this.heat,
    this.melt,
    this.reducedMotion = false,
  });

  final MoldModel mold;
  final MetalStyle metal;
  final MoldCues cues;
  final bool chiselMode;
  final ValueChanged<CellPos>? onCellTap;

  /// Outside chisel mode: a tap on a filled or revealed cell (to look up its
  /// words, including the answers shown after a round that nobody found).
  final ValueChanged<CellPos>? onFilledTap;
  final double maxCell;

  /// Survival: the heated word counting down, and a word melting away.
  final HeatView? heat;
  final MeltView? melt;
  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cell = min(maxCell, min(c.maxWidth / mold.cols, c.maxHeight / mold.rows));
        final gap = cell * 0.07;
        Rect rectOf(CellPos pos) =>
            Rect.fromLTWH(pos.x * cell + gap / 2, pos.y * cell + gap / 2, cell - gap, cell - gap);
        return Center(
          child: SizedBox(
            width: cell * mold.cols,
            height: cell * mold.rows,
            child: Stack(
              // Melting drips and the countdown badge reach past the edges.
              clipBehavior: Clip.none,
              children: [
                for (final pos in mold.cells) Positioned.fromRect(rect: rectOf(pos), child: _cell(pos)),
                if (!reducedMotion)
                  for (final st in cues.strikes)
                    // Keyed here, among the Stack's children, so each swing keeps its
                    // own animation when an older one leaves the list.
                    Positioned.fill(
                      key: ValueKey(('strike', st.id)),
                      child: HammerStrike(
                        cell: rectOf(st.cell),
                        mirror: st.cell.x * 2 >= mold.cols,
                        onDone: () => cues.retire(st.id),
                      ),
                    ),
                if (heat != null && melt == null)
                  Positioned.fill(
                    child: HeatOverlay(heat: heat!, rectOf: rectOf),
                  ),
                if (melt != null)
                  Positioned.fill(
                    child: MeltOverlay(melt: melt!, rectOf: rectOf, animate: !reducedMotion),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _cell(CellPos pos) {
    final fill = mold.fillOf(pos);
    final empty = fill != CellFill.filled && fill != CellFill.revealed;
    final owner = mold.ownerColor(pos);
    return MoldCell(
      key: ValueKey(pos),
      letter: mold.letterAt(pos),
      fill: fill,
      metal: owner == null ? metal : MetalStyle.fromColor(owner),
      initial: mold.ownerInitial(pos),
      delay: cues.fillDelay[pos] ?? Duration.zero,
      flash: cues.flash[pos] ?? 0,
      struck: cues.struck.contains(pos),
      pickup: fill == CellFill.filled ? null : mold.pickupAt(pos),
      gilded: fill != CellFill.filled && mold.isGilded(pos),
      highlight: chiselMode && empty,
      onTap: chiselMode
          ? (empty && onCellTap != null ? () => onCellTap!(pos) : null)
          : (!empty && onFilledTap != null ? () => onFilledTap!(pos) : null),
    );
  }
}

class MoldCell extends StatefulWidget {
  const MoldCell({
    super.key,
    required this.letter,
    required this.fill,
    required this.metal,
    required this.delay,
    required this.flash,
    this.pickup,
    this.gilded = false,
    this.initial,
    this.highlight = false,
    this.struck = false,
    this.onTap,
  });

  final String letter;

  /// Co-op: the forger's initial, drawn small in the corner.
  final String? initial;
  final CellFill fill;
  final MetalStyle metal;
  final Duration delay;
  final int flash;

  /// Hint kind name of an uncollected pickup in this cell.
  final String? pickup;

  /// A gilded cell whose blueprint piece is still there.
  final bool gilded;
  final bool highlight;

  /// A hammer struck it: its reveal throws a bigger burst of sparks.
  final bool struck;
  final VoidCallback? onTap;

  @override
  State<MoldCell> createState() => _MoldCellState();
}

class _MoldCellState extends State<MoldCell> with TickerProviderStateMixin {
  /// 0 → 1: white-hot pour cooling down to the metal colour.
  late final AnimationController _heat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: widget.fill == CellFill.filled ? 1 : 0,
  );

  /// Short pop for reveals and flashes.
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    value: 1,
  );

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pickup != null || widget.highlight || widget.gilded) _pulse.repeat(reverse: true);
  }

  /// Filled or revealed, but still drawn empty until its delay is up (a
  /// word pouring in letter by letter, or a hammer on its way down).
  bool _waiting = false;
  int _changes = 0;

  @override
  void didUpdateWidget(MoldCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final filled = widget.fill == CellFill.filled && oldWidget.fill != CellFill.filled;
    final revealed = widget.fill == CellFill.revealed && oldWidget.fill == CellFill.empty;
    if (filled || revealed) {
      if (filled) _heat.value = 0;
      final change = ++_changes;
      void show() {
        if (!mounted || change != _changes) return;
        setState(() => _waiting = false);
        if (filled) _heat.forward(from: 0);
        _pop.forward(from: 0);
        _burst(small: revealed && !widget.struck, big: widget.struck);
      }

      if (widget.delay > Duration.zero) {
        _waiting = true;
        Future.delayed(widget.delay, show);
      } else {
        show();
      }
    }
    if (widget.flash != oldWidget.flash) _pop.forward(from: 0);
    final wantsPulse = widget.pickup != null || widget.highlight || widget.gilded;
    if (wantsPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!wantsPulse && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  void _burst({bool small = false, bool big = false}) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final center = box.localToGlobal(box.size.center(Offset.zero));
    SparkField.of(context)?.burst(
      center,
      // A hammer blow throws more, faster.
      count: big ? 26 : (small ? 8 : 10),
      speed: box.size.width * (big ? 6 : (small ? 3 : 4.5)),
      gravity: box.size.width * 14,
    );
  }

  @override
  void dispose() {
    _heat.dispose();
    _pop.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Color _metalColor(double t) {
    // white heat → molten → ember → cooled metal
    const fire = Palette.fire;
    if (t < 0.25) return Color.lerp(fire.white, fire.molten, t / 0.25)!;
    if (t < 0.5) return Color.lerp(fire.molten, fire.ember, (t - 0.25) / 0.25)!;
    return Color.lerp(fire.ember, widget.metal.base, (t - 0.5) / 0.5)!;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: Listenable.merge([_heat, _pop, _pulse]),
        builder: (context, _) {
          final pop = Curves.easeOut.transform(1 - _pop.value);
          final scale = 1 + 0.14 * sin(pop * pi);
          return Transform.scale(
            scale: scale,
            child: LayoutBuilder(builder: (context, c) => _buildCell(c.maxWidth)),
          );
        },
      ),
    );
  }

  Widget _buildCell(double s) {
    final radius = BorderRadius.circular(s * 0.16);
    final fill = _waiting ? CellFill.empty : widget.fill;
    final filled = fill == CellFill.filled;
    final t = _heat.value;
    final layers = <Widget>[];
    if (!filled || t < 1) {
      layers.add(
        SchemeIron(
          child: Image.asset(
            'assets/images/cell_empty.png',
            width: s,
            height: s,
            fit: BoxFit.fill,
            errorBuilder: (_, _, _) => DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF14100D), Color(0xFF2A221C)],
                ),
                border: Border.all(color: const Color(0xFF3E322A), width: 1),
              ),
              child: SizedBox.square(dimension: s),
            ),
          ),
        ),
      );
    }
    if (filled) {
      final color = _metalColor(t);
      final glow = (1 - t).clamp(0.0, 1.0);
      layers.add(
        Opacity(
          opacity: Curves.easeOut.transform((t * 4).clamp(0.0, 1.0)),
          child: Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                if (glow > 0.05)
                  BoxShadow(
                    color: Palette.fire.ember.withValues(alpha: 0.8 * glow),
                    blurRadius: s * 0.5 * glow,
                  ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Image.asset(
                'assets/images/cell_metal.png',
                width: s,
                height: s,
                fit: BoxFit.fill,
                color: _forModulate(color),
                colorBlendMode: BlendMode.modulate,
                errorBuilder: (_, _, _) => DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color.lerp(color, Colors.white, 0.35)!, color, Color.lerp(color, Colors.black, 0.35)!],
                    ),
                    border: Border.all(color: Color.lerp(color, Colors.black, 0.4)!, width: 1),
                  ),
                  child: SizedBox.square(dimension: s),
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (widget.gilded && !filled) {
      final shine = _pulse.value;
      layers.add(
        Container(
          width: s,
          height: s,
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment(-1.4 + 2.4 * shine, -1),
              end: Alignment(-0.4 + 2.4 * shine, 1),
              colors: [
                Palette.gold.withValues(alpha: 0.10),
                Palette.gold.withValues(alpha: 0.38),
                Palette.gold.withValues(alpha: 0.10),
              ],
            ),
            border: Border.all(
              color: Palette.gold.withValues(alpha: 0.7 + 0.3 * shine),
              width: max(1.5, s * 0.05),
            ),
            boxShadow: [
              BoxShadow(
                color: Palette.gold.withValues(alpha: 0.25 + 0.2 * shine),
                blurRadius: s * 0.3,
              ),
            ],
          ),
        ),
      );
    }
    if (widget.highlight) {
      layers.add(
        Container(
          width: s,
          height: s,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: Palette.molten.withValues(alpha: 0.45 + 0.5 * _pulse.value), width: 2),
          ),
        ),
      );
    }
    if (widget.pickup != null && !filled) {
      layers.add(
        Opacity(
          opacity: 0.55 + 0.45 * _pulse.value,
          child: Container(
            width: s * 0.62,
            height: s * 0.62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Palette.ember.withValues(alpha: 0.5 + 0.3 * _pulse.value),
                  blurRadius: s * 0.35,
                ),
              ],
            ),
            child: SvgPicture.asset(
              'assets/icons/ember.svg',
              colorFilter: ColorFilter.mode(Palette.molten, BlendMode.srcIn),
              placeholderBuilder: (_) => Icon(Icons.local_fire_department, color: Palette.molten),
            ),
          ),
        ),
      );
    }
    if (fill != CellFill.empty) {
      final letterColor = filled ? Color.lerp(Palette.darkLetter, widget.metal.letter, t)! : Palette.molten;
      layers.add(
        Text(
          widget.letter,
          style: letterStyle(s * 0.6, color: letterColor).copyWith(
            shadows: filled
                ? [Shadow(color: Colors.white.withValues(alpha: 0.25), offset: Offset(0, s * 0.02))]
                : [Shadow(color: Palette.ember, blurRadius: s * 0.2)],
          ),
        ),
      );
    }
    if (filled && widget.initial != null) {
      layers.add(
        Positioned(
          left: s * 0.08,
          top: s * 0.04,
          child: Text(widget.initial!, style: letterStyle(s * 0.2, color: widget.metal.letter.withValues(alpha: 0.75))),
        ),
      );
    }
    return Stack(alignment: Alignment.center, children: layers);
  }
}

/// cell_metal.png is a mid-grey plate (about 63% brightness), so multiplying
/// it by the metal colour would come out too dark. Brighten the tint so the
/// plate's average lands near the intended colour, keeping its shading.
Color _forModulate(Color c) {
  int up(double v) => (v * 255 / 0.8).clamp(0, 255).round();
  return Color.fromARGB(255, up(c.r), up(c.g), up(c.b));
}
