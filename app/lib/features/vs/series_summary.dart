import 'package:flutter/material.dart';

import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/game_icon.dart';
import 'rival_molds.dart';

/// The podium's look back at a Versus series: a column per racer in podium
/// order, a row per round with everyone's letters and who won it and how,
/// and the series totals at the foot. Tap a round to see everyone's mold;
/// the last one starts open. Drawn from `SERIES_END.history` alone, so it's
/// whole even for someone who joined late.
class SeriesSummary extends StatefulWidget {
  const SeriesSummary({super.key, required this.session, required this.series});

  final VsSession session;
  final SeriesEnd series;

  @override
  State<SeriesSummary> createState() => _SeriesSummaryState();
}

class _SeriesSummaryState extends State<SeriesSummary> {
  /// Width of the round-number column; the racers share the rest.
  static const _lead = 46.0;

  /// Rounds showing their molds, by round number.
  late final Set<int> _open = {if (widget.series.history.isNotEmpty) widget.series.history.last.round};

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final series = widget.series;
    final text = Theme.of(context).textTheme;
    // Podium order, then anyone the podium left out.
    final ids = <String>{
      for (final p in series.podium) p.id,
      for (final r in series.history)
        for (final p in r.progress) p.id,
    }.toList();
    final wins = {for (final p in series.podium) p.id: p.wins};
    final letters = series.letters;
    Widget columns(Widget Function(String id) cell, {Widget? lead}) => Row(
      children: [
        SizedBox(width: _lead, child: lead),
        for (final id in ids) Expanded(child: Center(child: cell(id))),
      ],
    );
    final rule = Divider(height: 1, thickness: 1, color: Palette.ash.withValues(alpha: 0.7));

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2C221C), Palette.soot, Color(0xFF1B1411)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.ash),
        boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 8, offset: Offset(0, 3))],
      ),
      // So a tapped round's ripple shows over the plate.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            columns((id) => _Racer(session: s, id: id)),
            const SizedBox(height: 8),
            for (final round in series.history) ...[
              rule,
              _RoundRow(
                session: s,
                round: round,
                ids: ids,
                lead: _lead,
                open: _open.contains(round.round),
                onTap: () => setState(() {
                  if (!_open.remove(round.round)) _open.add(round.round);
                }),
              ),
            ],
            Divider(height: 1, thickness: 1.5, color: Palette.iron.withValues(alpha: 0.6)),
            const SizedBox(height: 8),
            columns(
              lead: Text('Wins', style: text.labelSmall?.copyWith(color: Palette.steel)),
              (id) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_fire_department, size: 14, color: s.colorOf(id)),
                  const SizedBox(width: 1),
                  Text('${wins[id] ?? 0}', style: displayStyle(18, color: s.colorOf(id))),
                ],
              ),
            ),
            const SizedBox(height: 4),
            columns(
              lead: Text('Letters', style: text.labelSmall?.copyWith(color: Palette.steel)),
              (id) => Text('${letters[id] ?? 0}', style: letterStyle(15, color: s.colorOf(id))),
            ),
          ],
        ),
      ),
    );
  }
}

/// A column's head: the racer's avatar, name and colour.
class _Racer extends StatelessWidget {
  const _Racer({required this.session, required this.id});

  final VsSession session;
  final String id;

  @override
  Widget build(BuildContext context) {
    final player = session.lobby?.player(id);
    final mine = id == session.me;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: player == null || !player.connected ? 0.5 : 1,
          child: AvatarBadge(avatar: player?.avatar ?? 'avatar_01', size: 28),
        ),
        const SizedBox(height: 3),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            mine ? 'You' : session.nameOf(id),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: mine ? Palette.whiteHeat : Palette.steel),
          ),
        ),
        const SizedBox(height: 3),
        Container(
          width: 22,
          height: 3,
          decoration: BoxDecoration(color: session.colorOf(id), borderRadius: BorderRadius.circular(2)),
        ),
      ],
    );
  }
}

/// One round: its number, every racer's letters (the winner's ringed),
/// who won it and how, and, open, everyone's mold.
class _RoundRow extends StatelessWidget {
  const _RoundRow({
    required this.session,
    required this.round,
    required this.ids,
    required this.lead,
    required this.open,
    required this.onTap,
  });

  final VsSession session;
  final SeriesRound round;
  final List<String> ids;
  final double lead;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final text = Theme.of(context).textTheme;
    final progress = {for (final p in round.progress) p.id: p};
    final sudden = round.suddenDeath;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox(
                  width: lead,
                  child: Text(
                    '${round.round}',
                    textAlign: TextAlign.center,
                    style: displayStyle(19, color: sudden ? Palette.quenchRed : Palette.molten),
                  ),
                ),
                for (final id in ids)
                  Expanded(
                    child: Center(
                      child: _Letters(
                        progress: progress[id],
                        color: s.colorOf(id),
                        won: id == round.winner,
                        melted: id == round.melted?.id,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                SizedBox(width: lead),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (sudden)
                          TextSpan(
                            text: 'Sudden death · ',
                            style: TextStyle(color: Palette.quenchRed, fontWeight: FontWeight.w700),
                          ),
                        ..._how(s),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: Palette.steel),
                  ),
                ),
                Icon(open ? Icons.expand_less : Icons.expand_more, size: 20, color: Palette.steel),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: open
                  ? RivalMolds.past(
                      session: s,
                      past: round,
                      order: ids,
                      padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  /// "Ada · finished first", or that nobody won, and whose word melted.
  List<InlineSpan> _how(VsSession s) {
    final winner = round.winner;
    final melted = round.melted;
    return [
      if (winner == null)
        const TextSpan(text: 'No winner')
      else ...[
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: EdgeInsets.only(right: 3),
            child: GameIcon('crown', size: 13, color: Palette.molten),
          ),
        ),
        TextSpan(
          text: winner == s.me ? 'You' : s.nameOf(winner),
          style: TextStyle(color: s.colorOf(winner), fontWeight: FontWeight.w700),
        ),
        TextSpan(
          text: switch (round.how) {
            'finished' => ' · finished first',
            'survived' => ' · survived the heat',
            _ => ' · most letters on time',
          },
        ),
      ],
      if (melted != null)
        TextSpan(
          text: ' · ${melted.id == s.me ? 'you' : s.nameOf(melted.id)} melted',
          style: TextStyle(color: Palette.quenchRed),
        ),
    ];
  }
}

/// A racer's letters in one round: ringed for the winner, red for a melt,
/// a dash for someone who didn't race it.
class _Letters extends StatelessWidget {
  const _Letters({required this.progress, required this.color, required this.won, required this.melted});

  final RacerProgress? progress;
  final Color color;
  final bool won;
  final bool melted;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    if (p == null) return Text('–', style: letterStyle(14, color: Palette.ash));
    final full = p.total > 0 && p.filled >= p.total;
    final ink = melted ? Palette.quenchRed : (full || won ? Palette.whiteHeat : color);
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: won
            ? BoxDecoration(
                color: Palette.ember.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Palette.molten, width: 1.2),
                boxShadow: [BoxShadow(color: Palette.ember.withValues(alpha: 0.35), blurRadius: 8)],
              )
            : null,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '${p.filled}',
                style: letterStyle(15, color: ink),
              ),
              TextSpan(
                text: '/${p.total}',
                style: letterStyle(10, color: Palette.steel),
              ),
            ],
          ),
          maxLines: 1,
        ),
      ),
    );
  }
}
