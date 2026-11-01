import 'package:flutter/material.dart';

import '../../game/rune_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/video_bubble.dart';
import '../../video/video_call.dart';
import '../vs/team_widgets.dart' show teamName;

/// What a word of [letters] letters scores before any doubling: its length
/// less two, at least 1 (shared/rune-rush.md).
int runeWordPoints(int letters) => letters <= 3 ? 1 : letters - 2;

/// "1:30" for [seconds].
String runeClock(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

/// One line on how Team Rune Rush teams score.
String teamScoringBlurb(String scoring) => scoring == 'sum'
    ? 'Everyone finds their own words; a team scores its smiths\' points added up'
    : 'A team shares one list of words; a word the other team missed scores double';

/// "Round 2 of 3", or the tiebreaker.
String runeRoundLabel(RuneSession s) {
  final g = s.grid;
  if (g == null) return '';
  if (g.tiebreak) return 'Tiebreaker round!';
  return 'Round ${g.round} of ${g.rounds}';
}

/// The headline for a finished round.
String runeRoundHeadline(RuneSession s, RuneRoundEnd end) {
  if (end.isTeam) {
    final team = end.team;
    final points = end.teamPoints ?? const [0, 0];
    if (team == null) return points[0] == 0 ? 'No points this round' : 'A tie, ${points[0]}–${points[1]}';
    final who = team == s.myTeam ? 'Your team' : teamName(team);
    return '$who takes the round, ${points[team]}–${points[1 - team]}';
  }
  final winner = end.winner;
  if (winner == null) {
    return end.points.values.every((p) => p == 0) ? 'No points this round' : 'A tie this round';
  }
  final points = end.points[winner] ?? 0;
  return winner == s.me ? 'You take the round with $points!' : '${s.nameOf(winner)} takes the round with $points';
}

/// The host's settings for the next Rune Rush game, which everyone sees:
/// the grid, the timer, the shortest word, the rounds, and in Team Rune
/// Grid how teams score.
class RuneSettingsPicker extends StatelessWidget {
  const RuneSettingsPicker({super.key, required this.session});

  final RuneSession session;

  @override
  Widget build(BuildContext context) {
    final r = session.lobby?.rune ?? const RuneSettings();
    final host = session.isHost;
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        if (!host)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('The host picks', style: text.labelMedium?.copyWith(color: Palette.steel)),
          ),
        _ChoiceRow<int>(
          id: 'size',
          label: 'Grid',
          options: const [(4, '4×4'), (5, '5×5'), (6, '6×6')],
          value: r.size,
          onSelected: host ? (v) => session.setRune(size: v) : null,
        ),
        _ChoiceRow<int>(
          id: 'seconds',
          label: 'Timer',
          options: [
            for (final s in const [30, 60, 90, 120, 180]) (s, runeClock(s)),
          ],
          value: r.seconds,
          onSelected: host ? (v) => session.setRune(seconds: v) : null,
        ),
        _ChoiceRow<int>(
          id: 'min',
          label: 'Shortest word',
          options: const [(3, '3 letters'), (4, '4'), (5, '5')],
          value: r.min,
          onSelected: host ? (v) => session.setRune(min: v) : null,
        ),
        _ChoiceRow<int>(
          id: 'rounds',
          label: 'Rounds',
          options: const [(1, '1'), (3, '3'), (5, '5')],
          value: r.rounds,
          onSelected: host ? (v) => session.setRune(rounds: v) : null,
        ),
        if (session.lobby?.mode == 'runeteam') ...[
          _ChoiceRow<String>(
            id: 'team-scoring',
            label: 'Teams',
            options: const [('pooled', 'Pooled words'), ('sum', 'Points added up')],
            value: r.teamScoring,
            onSelected: host ? (v) => session.setRune(teamScoring: v) : null,
          ),
          Text(
            teamScoringBlurb(r.teamScoring),
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: Palette.molten),
          ),
        ],
        const SizedBox(height: 4),
        Text(
          'Join touching letters, any direction. 3 letters 1 point, 4 letters 2, 5 letters 3, '
          '+1 a letter after; a word nobody else found scores double.',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: Palette.steel),
        ),
      ],
    );
  }
}

class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.id,
    required this.label,
    required this.options,
    required this.value,
    required this.onSelected,
  });

  final String id;
  final String label;
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T>? onSelected;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: text.labelLarge?.copyWith(color: Palette.steel)),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                for (final (v, name) in options)
                  ChoiceChip(
                    key: ValueKey('rune-$id-$v'),
                    label: Text(name),
                    visualDensity: VisualDensity.compact,
                    selected: value == v,
                    selectedColor: Palette.ember.withValues(alpha: 0.35),
                    labelStyle: TextStyle(color: Palette.whiteHeat),
                    checkmarkColor: Palette.whiteHeat,
                    showCheckmark: false,
                    side: BorderSide(color: value == v ? Palette.molten : Palette.ash),
                    // The host's pick stays lit (not greyed out as if disabled).
                    onSelected: onSelected == null
                        ? null
                        : (_) {
                            if (value != v) onSelected!(v);
                          },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The racers across the top of a round: bubble, name, words found so far
/// (never the words) and points over the game. Teammates first; my own
/// bubble last when video chat is on.
class RuneRivalStrip extends StatelessWidget {
  const RuneRivalStrip({super.key, required this.session, this.call});

  final RuneSession session;
  final VideoCall? call;

  @override
  Widget build(BuildContext context) {
    final grid = session.grid;
    if (grid == null) return const SizedBox.shrink();
    final ids = [
      for (final id in grid.players)
        if (id != session.me) id,
    ];
    if (session.isTeam) {
      final mine = session.myTeam;
      ids.sort((a, b) => (session.teamOf(a) == mine ? 0 : 1).compareTo(session.teamOf(b) == mine ? 0 : 1));
    }
    final call = this.call;
    return SizedBox(
      height: call == null ? 70 : 84,
      child: Row(
        children: [
          for (final id in ids.take(5))
            Expanded(
              child: _RivalTile(session: session, id: id, call: call),
            ),
          if (call != null)
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VideoBubble(
                    userId: session.me,
                    avatar: session.myPlayer?.avatar ?? 'avatar_01',
                    size: 42,
                    call: call,
                    color: session.colorOf(session.me),
                    me: true,
                  ),
                  Text('You', style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RivalTile extends StatelessWidget {
  const _RivalTile({required this.session, required this.id, this.call});

  final RuneSession session;
  final String id;
  final VideoCall? call;

  @override
  Widget build(BuildContext context) {
    final player = session.lobby?.player(id);
    final color = session.colorOf(id);
    final team = session.isTeam ? session.teamOf(id) : null;
    final words = session.tally[id] ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          VideoBubble(
            userId: id,
            avatar: player?.avatar ?? 'avatar_01',
            size: call == null ? 30 : 42,
            call: call,
            color: color,
            dimmed: player != null && !player.connected,
          ),
          Text(
            session.nameOf(id),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: team == null ? null : Palette.team(team)),
          ),
          Text(
            '$words ${words == 1 ? 'word' : 'words'} · ${session.totalOf(id)} pts',
            key: ValueKey('rune-rival-$id'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, height: 1.1, color: color, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

/// Team Rune Rush, under the timer: each team's points over the game and
/// words found this round. My team is marked.
class RuneTeamBar extends StatelessWidget {
  const RuneTeamBar({super.key, required this.session});

  final RuneSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final text = Theme.of(context).textTheme;
    final words = [0, 0];
    for (final e in s.tally.entries) {
      final team = s.teamOf(e.key);
      if (team != null) words[team] += e.value;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          for (final team in const [0, 1]) ...[
            if (team == 1) const SizedBox(width: 8),
            Expanded(
              child: Container(
                key: ValueKey('rune-team-$team'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Palette.team(team).withValues(alpha: team == s.myTeam ? 0.22 : 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: team == s.myTeam ? Palette.team(team) : Palette.ash),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      team == s.myTeam ? '${teamName(team)} · you' : teamName(team),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge?.copyWith(color: Palette.team(team), fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${s.teamTotals[team]} pts · ${words[team]} words',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Words as small chips: [unique] ones (nobody else found them) in gold,
/// [missed] ones (on the grid, found by nobody) dim.
class RuneWordChip extends StatelessWidget {
  const RuneWordChip({
    super.key,
    required this.word,
    this.points,
    this.unique = false,
    this.missed = false,
    this.color,
    this.onTap,
  });

  final String word;
  final int? points;
  final bool unique;
  final bool missed;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ink = missed ? Palette.steel : (color ?? Palette.whiteHeat);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: unique ? Palette.gold.withValues(alpha: 0.16) : Palette.soot.withValues(alpha: missed ? 0.4 : 0.85),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: unique ? Palette.gold : Palette.ash),
        ),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: word,
                style: letterStyle(13, color: ink),
              ),
              if (points != null)
                TextSpan(
                  text: ' ${points!}',
                  style: TextStyle(
                    fontSize: 11,
                    color: unique ? Palette.gold : Palette.steel,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The game's points so far, everyone's, for the countdown and standings.
String runePointsLine(RuneSession s, String id) {
  final total = s.totalOf(id);
  return '$total ${total == 1 ? 'point' : 'points'}';
}

/// "Copper vs Cobalt" or the tied leaders' names.
String runeNextLabel(RuneSession s, NextRound next) =>
    s.isTeam ? 'Copper vs Cobalt' : next.racers.map(s.nameOf).join(' vs ');

/// Shown big before a round: which round, the countdown and the grid's rules.
class RuneCountdown extends StatelessWidget {
  const RuneCountdown({super.key, required this.session});

  final RuneSession session;

  @override
  Widget build(BuildContext context) {
    final g = session.grid;
    final text = Theme.of(context).textTheme;
    return ColoredBox(
      color: Palette.forgeBlack.withValues(alpha: 0.72),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              runeRoundLabel(session),
              style: displayStyle(26, color: g?.tiebreak ?? false ? Palette.quenchRed : Palette.steel),
            ),
            Text(
              '${session.countdownLeft.inSeconds + 1}',
              style: displayStyle(
                110,
                color: Palette.molten,
              ).copyWith(shadows: [Shadow(color: Palette.ember, blurRadius: 40)]),
            ),
            if (g != null)
              Text(
                '${g.size}×${g.size} · ${runeClock(g.seconds)} · words of ${g.min}+ letters',
                style: text.titleMedium,
              ),
            if (!session.racing)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('You watch this one', style: text.titleMedium),
              ),
          ],
        ),
      ),
    );
  }
}
