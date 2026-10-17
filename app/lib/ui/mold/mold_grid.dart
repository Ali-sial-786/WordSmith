import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../engine/board.dart';
import '../../engine/puzzle.dart';
import '../effects/sparks.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';

enum CellFill { empty, revealed, filled }

/// Per-cell animation cues handed down by the puzzle screen.
class MoldCues {
  MoldCues();

  /// Delay before a newly filled cell starts its pour, so a word fills
  /// letter by letter.
  final Map<CellPos, Duration> fillDelay = {};

  /// Bumped to make cells pulse (e.g. "already forged").
  final Map<CellPos, int> flash = {};

  void stagger(List<CellPos> cells, {Duration step = const Duration(milliseconds: 70)}) {
    for (var i = 0; i < cells.length; i++) {
      fillDelay[cells[i]] = step * i;
    }
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
    required this.board,
    required this.metal,
    required this.cues,
    this.chiselMode = false,
    this.onCellTap,
    this.maxCell = 80,
  });

  final Board board;
  final MetalStyle metal;
  final MoldCues cues;
  final bool chiselMode;
  final ValueChanged<CellPos>? onCellTap;
  final double maxCell;

  @override
  Widget build(BuildContext context) {
    final puzzle = board.puzzle;
    return LayoutBuilder(
      builder: (context, c) {
        final cell = min(
          maxCell,
          min(c.maxWidth / puzzle.cols, c.maxHeight / puzzle.rows),
        );
        final gap = cell * 0.07;
        return Center(
          child: SizedBox(
            width: cell * puzzle.cols,
            height: cell * puzzle.rows,
            child: Stack(
              children: [
                for (final pos in puzzle.cells)
                  Positioned(
                    left: pos.x * cell + gap / 2,
                    top: pos.y * cell + gap / 2,
                    width: cell - gap,
                    height: cell - gap,
                    child: MoldCell(
                      key: ValueKey(pos),
                      letter: puzzle.letterAt[pos]!,
                      fill: cellFill(board, pos),
                      metal: metal,
                      delay: cues.fillDelay[pos] ?? Duration.zero,
                      flash: cues.flash[pos] ?? 0,
                      pickup: board.isFilled(pos) ? null : board.pickupAt(pos)?.kind.name,
                      highlight: chiselMode && !board.isFilled(pos),
                      onTap: chiselMode && !board.isFilled(pos) && onCellTap != null
                          ? () => onCellTap!(pos)
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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
    this.highlight = false,
    this.onTap,
  });

  final String letter;
  final CellFill fill;
  final MetalStyle metal;
  final Duration delay;
  final int flash;

  /// Hint kind name of an uncollected pickup in this cell.
  final String? pickup;
  final bool highlight;
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
    if (widget.pickup != null || widget.highlight) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(MoldCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fill == CellFill.filled && oldWidget.fill != CellFill.filled) {
      _heat.value = 0;
      Future.delayed(widget.delay, () {
        if (!mounted) return;
        _heat.forward(from: 0);
        _pop.forward(from: 0);
        _burst();
      });
    } else if (widget.fill == CellFill.revealed && oldWidget.fill == CellFill.empty) {
      _pop.forward(from: 0);
      _burst(small: true);
    }
    if (widget.flash != oldWidget.flash) _pop.forward(from: 0);
    final wantsPulse = widget.pickup != null || widget.highlight;
    if (wantsPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!wantsPulse && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  void _burst({bool small = false}) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final center = box.localToGlobal(box.size.center(Offset.zero));
    SparkField.of(context)?.burst(
      center,
      count: small ? 8 : 10,
      speed: box.size.width * (small ? 3 : 4.5),
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
    if (t < 0.25) return Color.lerp(Palette.whiteHeat, Palette.molten, t / 0.25)!;
    if (t < 0.5) return Color.lerp(Palette.molten, Palette.ember, (t - 0.25) / 0.25)!;
    return Color.lerp(Palette.ember, widget.metal.base, (t - 0.5) / 0.5)!;
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
            child: LayoutBuilder(
              builder: (context, c) => _buildCell(c.maxWidth),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCell(double s) {
    final radius = BorderRadius.circular(s * 0.16);
    final filled = widget.fill == CellFill.filled;
    final t = _heat.value;
    final layers = <Widget>[];
    if (!filled || t < 1) {
      layers.add(
        Image.asset(
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
                    color: Palette.ember.withValues(alpha: 0.8 * glow),
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
                color: color,
                colorBlendMode: BlendMode.modulate,
                errorBuilder: (_, _, _) => DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(color, Colors.white, 0.35)!,
                        color,
                        Color.lerp(color, Colors.black, 0.35)!,
                      ],
                    ),
                    border: Border.all(
                      color: Color.lerp(color, Colors.black, 0.4)!,
                      width: 1,
                    ),
                  ),
                  child: SizedBox.square(dimension: s),
                ),
              ),
            ),
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
            border: Border.all(
              color: Palette.molten.withValues(alpha: 0.45 + 0.5 * _pulse.value),
              width: 2,
            ),
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
              colorFilter: const ColorFilter.mode(Palette.molten, BlendMode.srcIn),
              placeholderBuilder: (_) =>
                  const Icon(Icons.local_fire_department, color: Palette.molten),
            ),
          ),
        ),
      );
    }
    if (widget.fill != CellFill.empty) {
      final letterColor = filled
          ? Color.lerp(Palette.darkLetter, widget.metal.letter, t)!
          : Palette.molten;
      layers.add(
        Text(
          widget.letter,
          style: letterStyle(s * 0.6, color: letterColor).copyWith(
            shadows: filled
                ? [
                    Shadow(
                      color: Colors.white.withValues(alpha: 0.25),
                      offset: Offset(0, s * 0.02),
                    ),
                  ]
                : [Shadow(color: Palette.ember, blurRadius: s * 0.2)],
          ),
        ),
      );
    }
    return Stack(alignment: Alignment.center, children: layers);
  }
}

/// What [pos] shows on [board].
CellFill cellFill(Board board, CellPos pos) {
  if (board.puzzle.slotsAt[pos]!.any(board.isSlotComplete)) return CellFill.filled;
  return board.revealed.contains(pos) ? CellFill.revealed : CellFill.empty;
}
