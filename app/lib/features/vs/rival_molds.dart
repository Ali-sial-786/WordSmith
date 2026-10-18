import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/puzzle.dart';
import '../../game/providers.dart';
import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/game_icon.dart';

/// After a Versus round, every racer's mold in miniature: mine first, then my
/// rivals in the round's order, filled cells in each racer's colour, with
/// their letter count and the winner crowned. Drawn from the round's slots
/// and `ROUND_END.molds`, so nothing shows without both (an older server, or
/// back in the forge without that round's start); a round from
/// `SERIES_END.history` brings both.
class RivalMolds extends ConsumerStatefulWidget {
  /// The round [end] closed, on this phone's [VsSession.round].
  RivalMolds({super.key, required this.session, required VsRoundEnd end, this.padding = EdgeInsets.zero})
    : source = end,
      round = end.round,
      winner = end.winner,
      molds = end.molds,
      melted = end.melted,
      shape = null,
      order = null;

  /// A round from the series' history, which brings its own shape; [order]
  /// lines the tiles up with a summary's columns.
  RivalMolds.past({
    super.key,
    required this.session,
    required SeriesRound past,
    this.order,
    this.padding = EdgeInsets.zero,
  }) : source = past,
       round = past.round,
       winner = past.winner,
       molds = past.molds,
       melted = past.melted,
       shape = past;

  final VsSession session;

  /// What the row is drawn from: it rises in again when this changes.
  final Object source;
  final int? round;
  final String? winner;
  final Map<String, List<int>> molds;
  final ({String id, int slot})? melted;

  /// The mold's shape, when it isn't the session's round.
  final MoldShape? shape;

  /// Racers in this order, rather than mine first and then the round's.
  final List<String>? order;

  /// Around the row, only when there is one to show.
  final EdgeInsets padding;

  @override
  ConsumerState<RivalMolds> createState() => _RivalMoldsState();
}

class _RivalMoldsState extends ConsumerState<RivalMolds> with SingleTickerProviderStateMixin {
  // Each tile rises in a beat after the one before; its filled cells then
  // cool from white heat to the racer's colour.
  static const _stagger = 90;
  static const _rise = 320;
  static const _cool = 650;

  late final AnimationController _in = AnimationController(vsync: this);

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(RivalMolds old) {
    super.didUpdateWidget(old);
    if (!identical(old.source, widget.source)) _start();
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  void _start() {
    final n = max(1, widget.molds.length);
    _in.duration = Duration(milliseconds: _stagger * (n - 1) + _rise + _cool);
    if (ref.read(settingsProvider).reducedMotion) {
      _in.value = 1;
    } else {
      _in.forward(from: 0);
    }
  }

  /// How far tile [i] has risen and cooled (0–1 each), [ms] into the animation.
  static (double, double) _phase(int i, double ms) =>
      (((ms - i * _stagger) / _rise).clamp(0.0, 1.0), ((ms - i * _stagger - _rise * 0.5) / _cool).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final molds = widget.molds;
    final live = s.round;
    final round = widget.shape ?? (live == null || (widget.round != null && widget.round != live.round) ? null : live);
    if (round == null || molds.isEmpty) return const SizedBox.shrink();
    final slotCells = {for (final slot in round.slots) slot.slot: slot.cells};
    final cells = {for (final slot in round.slots) ...slot.cells}.toList();
    final melt = widget.melted;
    final order = widget.order;
    final racers = [
      for (final id in <String>{
        if (order != null) ...order.where(molds.containsKey),
        if (molds.containsKey(s.me)) s.me,
        ...molds.keys,
      })
        (id: id, filled: {for (final slot in molds[id]!) ...?slotCells[slot]}),
    ];
    return Padding(
      padding: widget.padding,
      child: LayoutBuilder(
        builder: (context, c) {
          const gap = 6.0;
          final width = min(96.0, (c.maxWidth - gap * (racers.length - 1)) / racers.length);
          return AnimatedBuilder(
            animation: _in,
            builder: (context, _) {
              final ms = _in.value * (_in.duration?.inMilliseconds ?? 0);
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, r) in racers.indexed) ...[
                    if (i > 0) const SizedBox(width: gap),
                    _rising(
                      i,
                      ms,
                      _MoldTile(
                        width: width,
                        cols: round.cols,
                        rows: round.rows,
                        cells: cells,
                        filled: r.filled,
                        melted: {
                          if (melt?.id == r.id)
                            for (final c in slotCells[melt!.slot] ?? const <CellPos>[])
                              if (!r.filled.contains(c)) c,
                        },
                        color: s.colorOf(r.id),
                        name: r.id == s.me ? 'You' : s.nameOf(r.id),
                        player: s.lobby?.player(r.id),
                        mine: r.id == s.me,
                        winner: r.id == widget.winner,
                        cool: Curves.easeOut.transform(_phase(i, ms).$2),
                      ),
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _rising(int i, double ms, Widget tile) {
    final rise = _phase(i, ms).$1;
    if (rise >= 1) return tile;
    final t = Curves.easeOutCubic.transform(rise);
    return Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: tile),
    );
  }
}

/// One racer's mold, name and letter count.
class _MoldTile extends StatelessWidget {
  const _MoldTile({
    required this.width,
    required this.cols,
    required this.rows,
    required this.cells,
    required this.filled,
    required this.melted,
    required this.color,
    required this.name,
    required this.player,
    required this.mine,
    required this.winner,
    required this.cool,
  });

  final double width;
  final int cols;
  final int rows;
  final List<CellPos> cells;
  final Set<CellPos> filled;

  /// Survival: the empty cells of the word that melted on this mold.
  final Set<CellPos> melted;
  final Color color;
  final String name;

  /// Null once they've left the room.
  final RoomPlayer? player;
  final bool mine;
  final bool winner;

  /// How far the filled cells have cooled from white heat (0–1).
  final double cool;

  @override
  Widget build(BuildContext context) {
    const pad = 5.0;
    final inner = width - pad * 2;
    // Tall molds are capped so the row stays short; every tile has the same grid.
    final moldHeight = min(inner * rows / cols, inner * 1.15);
    final text = Theme.of(context).textTheme;
    final done = filled.length >= cells.length && cells.isNotEmpty;
    return SizedBox(
      width: width,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(pad, pad + 1, pad, pad),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF2C221C), Palette.soot, Color(0xFF1B1411)],
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: winner ? Palette.molten : (mine ? Palette.iron : Palette.ash),
                width: winner ? 1.5 : 1,
              ),
              boxShadow: [
                const BoxShadow(color: Color(0x99000000), blurRadius: 6, offset: Offset(0, 2)),
                if (winner) BoxShadow(color: Palette.ember.withValues(alpha: 0.45), blurRadius: 14),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: inner,
                  height: moldHeight,
                  child: CustomPaint(
                    painter: _MiniMoldPainter(
                      cols: cols,
                      rows: rows,
                      cells: cells,
                      filled: filled,
                      melted: melted,
                      color: color,
                      cool: cool,
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Opacity(
                  opacity: player == null || !player!.connected ? 0.5 : 1,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Five across a small phone leaves room for the name only.
                      if (inner >= 62) ...[
                        AvatarBadge(avatar: player?.avatar ?? 'avatar_01', size: 16),
                        const SizedBox(width: 3),
                      ],
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelSmall?.copyWith(color: mine ? Palette.whiteHeat : Palette.steel),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${filled.length}/${cells.length}',
                  maxLines: 1,
                  style: letterStyle(
                    13,
                    color: melted.isNotEmpty ? Palette.quenchRed : (done ? Palette.whiteHeat : color),
                  ),
                ),
              ],
            ),
          ),
          if (winner) Positioned(top: -11, child: GameIcon('crown', size: 18, color: Palette.molten)),
        ],
      ),
    );
  }
}

class _MiniMoldPainter extends CustomPainter {
  _MiniMoldPainter({
    required this.cols,
    required this.rows,
    required this.cells,
    required this.filled,
    required this.melted,
    required this.color,
    required this.cool,
  });

  final int cols;
  final int rows;
  final List<CellPos> cells;
  final Set<CellPos> filled;
  final Set<CellPos> melted;
  final Color color;
  final double cool;

  @override
  void paint(Canvas canvas, Size size) {
    if (cols == 0 || rows == 0) return;
    final cell = min(size.width / cols, size.height / rows);
    final origin = Offset((size.width - cell * cols) / 2, (size.height - cell * rows) / 2);
    final gap = max(1.0, cell * 0.14);
    final radius = Radius.circular(cell * 0.24);
    // Straight from white heat: through molten, the cool colours turn muddy.
    final metal = Color.lerp(Palette.whiteHeat, color, cool)!;
    final glow = 1 - cool;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(0.6, cell * 0.07);
    for (final c in cells) {
      final rect = Rect.fromLTWH(
        origin.dx + c.x * cell + gap / 2,
        origin.dy + c.y * cell + gap / 2,
        cell - gap,
        cell - gap,
      );
      final r = RRect.fromRectAndRadius(rect, radius);
      if (filled.contains(c)) {
        if (glow > 0.05) {
          canvas.drawRRect(
            r.inflate(cell * 0.08),
            Paint()
              ..color = Palette.ember.withValues(alpha: 0.7 * glow)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, cell * 0.35),
          );
        }
        canvas.drawRRect(
          r,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color.lerp(metal, Colors.white, 0.35)!, metal, Color.lerp(metal, Colors.black, 0.3)!],
            ).createShader(rect),
        );
        canvas.drawRRect(r, stroke..color = Color.lerp(metal, Colors.black, 0.45)!);
      } else if (melted.contains(c)) {
        canvas.drawRRect(r, Paint()..color = Palette.quenchRed.withValues(alpha: 0.28));
        canvas.drawRRect(r, stroke..color = Palette.quenchRed.withValues(alpha: 0.9));
      } else {
        canvas.drawRRect(
          r,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF0F0B09), Color(0xFF221A15)],
            ).createShader(rect),
        );
        canvas.drawRRect(r, stroke..color = const Color(0xFF3E322A));
      }
    }
  }

  @override
  bool shouldRepaint(_MiniMoldPainter old) =>
      old.cool != cool ||
      old.color != color ||
      old.cols != cols ||
      old.rows != rows ||
      !listEquals(old.cells, cells) ||
      !setEquals(old.filled, filled) ||
      !setEquals(old.melted, melted);
}
