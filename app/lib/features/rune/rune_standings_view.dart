import 'dart:async';

import 'package:flutter/material.dart';

import '../../game/rune_session.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/metal_button.dart';
import '../coop/emotes.dart';
import '../coop/next_round_bar.dart';
import '../coop/room_chat.dart';
import '../vs/team_widgets.dart' show teamName;
import 'rune_review.dart';
import 'rune_widgets.dart';

/// Between Rune Grid rounds (up to 30 s): who took the round, the game's
/// points so far, everyone's words and every word on the grid, and the next
/// round's countdown. After the round that decided the game, the same, then
/// on to the podium.
class RuneStandingsView extends StatefulWidget {
  const RuneStandingsView({super.key, required this.session, required this.onLeave});

  final RuneSession session;
  final VoidCallback onLeave;

  @override
  State<RuneStandingsView> createState() => _RuneStandingsViewState();
}

class _RuneStandingsViewState extends State<RuneStandingsView> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final end = s.standings;
    final text = Theme.of(context).textTheme;
    if (end == null) return Center(child: CircularProgressIndicator(color: Palette.molten));
    final next = end.next;
    final order = [
      for (final id in s.standingsOrder)
        if (s.totals.containsKey(id)) id,
    ];
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: Row(
            children: [
              IconButton(
                onPressed: widget.onLeave,
                icon: Icon(Icons.close, color: Palette.steel),
              ),
              Expanded(
                child: Text(
                  end.tiebreak ? 'Tiebreaker round' : 'Round ${end.round} of ${s.rounds}',
                  style: displayStyle(16, color: Palette.steel),
                ),
              ),
              ChatButton(session: s, size: 20),
              EmoteButton(onEmote: s.emote, size: 20),
              const SizedBox(width: 8),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
            children: [
              Text(
                runeRoundHeadline(s, end),
                key: const ValueKey('rune-headline'),
                textAlign: TextAlign.center,
                style: displayStyle(
                  24,
                  color: Palette.molten,
                ).copyWith(shadows: [Shadow(color: Palette.ember, blurRadius: 20)]),
              ),
              const SizedBox(height: 10),
              if (s.isTeam)
                Text(
                  'Game so far: ${teamName(0)} ${s.teamTotals[0]} · ${teamName(1)} ${s.teamTotals[1]}',
                  textAlign: TextAlign.center,
                  style: text.titleMedium,
                )
              else
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 14,
                  runSpacing: 4,
                  children: [
                    for (final (i, id) in order.indexed)
                      Text(
                        '${i + 1}. ${id == s.me ? 'You' : s.nameOf(id)} ${s.totalOf(id)}',
                        style: text.titleSmall?.copyWith(color: s.colorOf(id)),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              if (next != null && end.standingsEndsAt != null) ...[
                if (next.suddenDeath)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'Tied at the top! Tiebreaker: ${runeNextLabel(s, next)}',
                      textAlign: TextAlign.center,
                      style: text.titleSmall?.copyWith(color: Palette.quenchRed),
                    ),
                  ),
                NextRoundBar(session: s, endsAt: end.standingsEndsAt!, players: next.racers),
              ] else if (s.showingFinalRound)
                PlateButton(
                  key: const ValueKey('rune-see-results'),
                  label: 'See the results',
                  sublabel: s.seriesEnd == null
                      ? 'Adding up the points…'
                      : 'In ${s.finalRoundLeft.inSeconds + 1} s by itself',
                  icon: 'trophy',
                  primary: true,
                  onPressed: s.seriesEnd == null ? null : s.seeResults,
                ),
              const SizedBox(height: 16),
              RuneRoundReview(key: ValueKey('rune-review-${end.round}'), session: s, end: end),
            ],
          ),
        ),
      ],
    );
  }
}
