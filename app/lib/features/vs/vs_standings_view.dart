import 'dart:async';

import 'package:flutter/material.dart';

import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/metal_button.dart';
import '../coop/emotes.dart';
import '../coop/room_chat.dart';
import 'rival_molds.dart';
import '../solo/forged_overlay.dart' show ScrapWords;
import '../coop/next_round_bar.dart';
import 'round_flash.dart';
import 'team_widgets.dart';
import 'vs_widgets.dart';

/// The time between Versus rounds (up to 30 s): the round's card (who won and how),
/// everyone's molds, the series tally, and what comes next. After the round
/// that decided the series, the same, then on to the podium.
class VsStandingsView extends StatefulWidget {
  const VsStandingsView({super.key, required this.session, required this.cues, required this.onLeave});

  final VsSession session;
  final MoldCues cues;
  final VoidCallback onLeave;

  @override
  State<VsStandingsView> createState() => _VsStandingsViewState();
}

class _VsStandingsViewState extends State<VsStandingsView> {
  late final Timer _tick;

  /// The banner the round's card settles into.
  final _banner = GlobalKey();

  /// The round the card is for; it has begun to make way, and has settled.
  Object? _flashFor;
  bool _revealed = false;
  bool _settled = false;

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
    final winner = end.winner;
    final next = end.next;
    final secs = end.standingsEndsAt == null ? 0 : ((end.standingsEndsAt! - s.serverNow) / 1000).ceil().clamp(0, 99);
    final lastFilled = {for (final p in end.progress) p.id: p};
    // A new round's card plays from the start; the same round again (a
    // reconnect) leaves it where it was.
    final round = end.round ?? end;
    if (round != _flashFor) {
      _flashFor = round;
      _revealed = _settled = false;
    }
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
      children: [
        // Rising in as the card makes way.
        RivalMolds(key: ValueKey(_revealed), session: s, end: end, padding: const EdgeInsets.only(top: 14)),
        const SizedBox(height: 18),
        if (end.isTeam) ...[
          TeamTally(session: s, tally: end.teamTally!, winner: end.team, scores: end.teamScores),
          const SizedBox(height: 12),
        ],
        for (final id in end.isTeam ? _byTeam(s) : s.standingsOrder)
          _TallyRow(
            session: s,
            id: id,
            wins: end.tally[id] ?? 0,
            filled: lastFilled[id],
            wonThis: end.isTeam ? end.team != null && s.teamOf(id) == end.team : id == winner,
            score: end.scores?[id],
            bonus: end.bonusTally[id] ?? 0,
          ),
        const SizedBox(height: 18),
        if (next != null) ...[
          Text(
            next.suddenDeath
                ? '${end.totalScore ? 'Tiebreaker' : 'Sudden death'}: ${end.isTeam ? 'Copper vs Cobalt' : next.racers.map(s.nameOf).join(' vs ')}'
                : end.totalScore
                ? 'Round ${next.round} of ${s.series}'
                : 'Round ${next.round} of up to ${s.series}',
            textAlign: TextAlign.center,
            style: displayStyle(18, color: next.suddenDeath ? Palette.quenchRed : Palette.molten),
          ),
          if (end.standingsEndsAt != null)
            NextRoundBar(session: s, endsAt: end.standingsEndsAt!, players: next.racers)
          else
            Text('Starts in $secs', textAlign: TextAlign.center, style: text.titleMedium),
          if (next.suddenDeath && !next.racers.contains(s.me))
            Text("You'll watch this one", textAlign: TextAlign.center, style: text.bodySmall),
        ],
        if (s.mold != null && s.racing) ...[
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: MoldGrid(
              mold: s.mold!,
              metal: MetalStyle.forChapter('steel'),
              cues: widget.cues,
              maxCell: 32,
              onFilledTap: (c) => showMeanings(context, s.mold!.wordsAt(c)),
            ),
          ),
          Text('Glowing letters are the words you missed.', textAlign: TextAlign.center, style: text.bodySmall),
        ],
        if (s.scrapWords.isNotEmpty) ...[
          const SizedBox(height: 14),
          ScrapWords(words: [...s.scrapWords]..sort()),
        ],
      ],
    );
    return Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: widget.onLeave,
                    icon: Icon(Icons.close, color: Palette.steel),
                  ),
                  const Spacer(),
                  ChatButton(session: s),
                  EmoteButton(onEmote: s.emote),
                ],
              ),
            ),
            // Where the round's card settles, kept in view above the standings.
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
              child: Opacity(
                opacity: _settled ? 1 : 0,
                child: RoundBanner(key: _banner, session: s, end: end),
              ),
            ),
            Expanded(child: list),
            if (s.finalRound) _SeeResults(session: s),
          ],
        ),
        if (!_settled)
          Positioned.fill(
            child: RoundFlash(
              key: ValueKey(_flashFor),
              session: s,
              end: end,
              banner: _banner,
              onSettle: () => setState(() => _revealed = true),
              onSettled: () => setState(() => _settled = true),
            ),
          ),
      ],
    );
  }
}

/// After the round that decided the series: on to the podium now, or by
/// itself once the hold is up.
class _SeeResults extends StatelessWidget {
  const _SeeResults({required this.session});

  final VsSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final holding = s.finalRoundUntil != null;
    final secs = (s.finalRoundLeft.inMilliseconds / 1000).ceil();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Palette.forgeBlack.withValues(alpha: 0.55), Palette.forgeBlack.withValues(alpha: 0.9)],
        ),
        border: Border(top: BorderSide(color: Palette.ash)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
        child: PlateButton(
          label: 'See the results',
          sublabel: holding ? 'The podium in ${secs}s' : 'Tallying the series…',
          icon: 'trophy',
          primary: true,
          onPressed: holding ? s.seeResults : null,
        ),
      ),
    );
  }
}

/// Team Versus: everyone in the series, my team first, each team in tally order.
List<String> _byTeam(VsSession s) {
  final mine = s.myTeam;
  final ids = s.standingsOrder;
  return [
    for (final id in ids)
      if (s.teamOf(id) == mine) id,
    for (final id in ids)
      if (s.teamOf(id) != mine) id,
  ];
}

class _TallyRow extends StatelessWidget {
  const _TallyRow({
    required this.session,
    required this.id,
    required this.wins,
    required this.filled,
    required this.wonThis,
    this.score,
    this.bonus = 0,
  });

  final VsSession session;
  final String id;
  final int wins;
  final RacerProgress? filled;
  final bool wonThis;

  /// A total score series: letters over the series so far, and bonus words
  /// (the tie-break). Null in a series won on round wins.
  final int? score;
  final int bonus;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final player = session.lobby?.player(id);
    final color = session.colorOf(id);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: wonThis ? Palette.ember.withValues(alpha: 0.16) : Palette.soot,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: color, width: 5)),
      ),
      child: Row(
        children: [
          Opacity(
            opacity: player == null || !player.connected ? 0.4 : 1,
            child: AvatarBadge(avatar: player?.avatar ?? 'avatar_01', size: 34),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(session.nameOf(id) + (id == session.me ? ' (you)' : ''), style: text.titleSmall),
                Text(
                  filled == null
                      ? (player == null ? 'Left the forge' : 'Watched')
                      : '${filled!.filled}/${filled!.total} letters',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          WinPips(wins: wins, color: color, size: 14),
          const SizedBox(width: 8),
          if (score == null)
            Text('$wins', style: displayStyle(20, color: color))
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$score',
                  key: ValueKey('score-$id'),
                  style: displayStyle(20, color: color),
                ),
                Text('$bonus bonus', style: text.labelSmall?.copyWith(color: Palette.verdigris)),
              ],
            ),
        ],
      ),
    );
  }
}
