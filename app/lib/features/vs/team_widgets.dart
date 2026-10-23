import 'package:flutter/material.dart';

import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import 'vs_widgets.dart';

/// Team Versus (shared/room-protocol.md "Team Versus"): the team names, the
/// two ways a round is won, and what shows during and after a round.

/// Copper (0) or Cobalt (1).
String teamName(int team) => team == 1 ? 'Cobalt' : 'Copper';

/// The rules the host picks from, with their names.
const teamRules = [('combined', 'Combined'), ('first', 'First to finish')];

/// One line on how [rule] decides a round.
String ruleBlurb(String rule) => rule == 'first'
    ? 'The first smith to fill their mold wins the round for their team'
    : "Your team's letters add up: fill every mold first, or have the most when time runs out";

/// "Copper", or "your team" when it's mine ([capital] at the start of a line).
String _teamWho(VsSession s, int team, {bool capital = false}) {
  if (team != s.myTeam) return teamName(team);
  return capital ? 'Your team' : 'your team';
}

/// The headline for a finished Team Versus round.
String teamRoundHeadline(VsSession s, VsRoundEnd end) {
  final team = end.team;
  if (team == null) return 'No winner this round';
  final who = _teamWho(s, team, capital: true);
  final winner = end.winner;
  // `first`: a racer won it for their team.
  if (winner != null) {
    final name = winner == s.me ? 'You' : s.nameOf(winner);
    return end.how == 'finished'
        ? '$name forged it first for ${_teamWho(s, team)}!'
        : '$name had the most letters: a round for ${_teamWho(s, team)}';
  }
  if (end.how == 'finished') return '$who filled every mold first!';
  final scores = end.teamScores ?? const [0, 0];
  return '$who wins on letters, ${scores[team]}–${scores[1 - team]}';
}

/// "YOUR TEAM WON THE ROUND!" or "Cobalt won the round", for the round's card.
String teamRoundTitle(VsSession s, VsRoundEnd end) {
  final team = end.team;
  if (team == null) return 'No winner this round';
  return team == s.myTeam ? 'YOUR TEAM WON THE ROUND!' : '${teamName(team)} won the round';
}

/// Under a Team Versus round's timer: each team's round wins and how it's
/// doing this round, letters added up (`combined`) or its best racer's
/// (`first`). My team is marked.
class TeamScoreBar extends StatelessWidget {
  const TeamScoreBar({super.key, required this.session});

  final VsSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final combined = s.rule != 'first';
    final letters = combined ? s.teamLetters : s.teamBest;
    final racers = s.teamRacers;
    final total = s.round == null ? 0 : s.mold?.cells.length ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Row(
        children: [
          for (final team in const [0, 1]) ...[
            if (team == 1) const SizedBox(width: 8),
            Expanded(
              child: _TeamHalf(
                team: team,
                mine: team == s.myTeam,
                wins: s.teamTally[team],
                letters: letters[team],
                // `combined` fills every racer's mold; `first`, one of them.
                outOf: total * (combined ? racers[team] : 1),
                caption: combined ? '${letters[team]} letters' : 'Best ${letters[team]}/$total',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TeamHalf extends StatelessWidget {
  const _TeamHalf({
    required this.team,
    required this.mine,
    required this.wins,
    required this.letters,
    required this.outOf,
    required this.caption,
  });

  final int team;
  final bool mine;
  final int wins;
  final int letters;
  final int outOf;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final color = Palette.team(team);
    final text = Theme.of(context).textTheme;
    final fraction = outOf == 0 ? 0.0 : (letters / outOf).clamp(0.0, 1.0);
    return Semantics(
      label: '${teamName(team)}${mine ? ', your team' : ''}: $wins round${wins == 1 ? '' : 's'} won, $caption',
      excludeSemantics: true,
      child: Container(
        key: ValueKey('team-bar-$team'),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: mine ? 0.22 : 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: mine ? color : Palette.ash, width: mine ? 1.5 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    mine ? '${teamName(team)} · you' : teamName(team),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w700),
                  ),
                ),
                WinPips(wins: wins, color: color, size: 11),
              ],
            ),
            const SizedBox(height: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: fraction),
                duration: const Duration(milliseconds: 300),
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 6,
                  color: fraction >= 1 ? Palette.whiteHeat : color,
                  backgroundColor: Palette.soot,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(caption, style: text.labelSmall),
          ],
        ),
      ),
    );
  }
}

/// The two teams' round wins after a round or a series, side by side, the
/// winners' ringed.
class TeamTally extends StatelessWidget {
  const TeamTally({super.key, required this.session, required this.tally, this.winner, this.scores});

  final VsSession session;

  /// `[copper, cobalt]` round wins.
  final List<int> tally;

  /// The team that won (the round, or the series), if any.
  final int? winner;

  /// Each team's letters this round, if shown.
  final List<int>? scores;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        for (final team in const [0, 1]) ...[
          if (team == 1) const SizedBox(width: 10),
          Expanded(
            child: Container(
              key: ValueKey('team-tally-$team'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Palette.team(team).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: team == winner ? Palette.molten : Palette.team(team),
                  width: team == winner ? 2.5 : 1,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    team == session.myTeam ? '${teamName(team)} (you)' : teamName(team),
                    style: text.titleSmall?.copyWith(color: Palette.team(team)),
                  ),
                  Text('${tally[team]}', style: text.headlineMedium?.copyWith(color: Palette.whiteHeat)),
                  Text(tally[team] == 1 ? 'round won' : 'rounds won', style: text.labelSmall),
                  if (scores != null) Text('${scores![team]} letters this round', style: text.labelSmall),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Team Versus, in the lobby or results: both teams with who's on each,
/// a button to join the other one while it has room, and for the host a
/// button on each player to move them across. [row] draws one player.
class TeamPicker extends StatelessWidget {
  const TeamPicker({super.key, required this.session, required this.row});

  final VsSession session;
  final Widget Function(RoomPlayer player) row;

  /// Players a team holds.
  static const maxTeam = 3;

  @override
  Widget build(BuildContext context) {
    final lobby = session.lobby!;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final team in const [0, 1]) ...[
          if (team == 1) const SizedBox(height: 12),
          Builder(
            builder: (context) {
              final members = lobby.team(team);
              final color = Palette.team(team);
              final mine = session.myTeam == team;
              return Container(
                key: ValueKey('team-$team'),
                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: color.withValues(alpha: mine ? 1 : 0.5),
                    width: mine ? 1.5 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            teamName(team),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleMedium?.copyWith(color: color),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('${members.length}/$maxTeam', style: text.labelMedium),
                        const Spacer(),
                        if (!mine && members.length < maxTeam)
                          TextButton(
                            key: ValueKey('join-team-$team'),
                            onPressed: () => session.joinTeam(team),
                            child: Semantics(
                              label: 'Join ${teamName(team)}',
                              excludeSemantics: true,
                              child: const Text('Join'),
                            ),
                          ),
                      ],
                    ),
                    for (final p in members)
                      Row(
                        children: [
                          Expanded(child: row(p)),
                          if (session.isHost && p.id != session.me)
                            IconButton(
                              key: ValueKey('move-${p.id}'),
                              tooltip: 'Move to ${teamName(1 - team)}',
                              visualDensity: VisualDensity.compact,
                              onPressed: lobby.team(1 - team).length < maxTeam
                                  ? () => session.moveToTeam(p.id, 1 - team)
                                  : null,
                              icon: Icon(Icons.swap_vert, color: Palette.steel),
                            ),
                        ],
                      ),
                    if (members.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text('Nobody yet', style: text.bodySmall),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
        const SizedBox(height: 6),
        Text(
          lobby.teamsEven ? 'Teams are even' : 'Teams need the same number of smiths',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: lobby.teamsEven ? Palette.verdigris : Palette.molten),
        ),
      ],
    );
  }
}

/// Team Versus, for the host: Combined or First to finish, with what it
/// means. Everyone sees the pick.
class RulePicker extends StatelessWidget {
  const RulePicker({super.key, required this.session});

  final VsSession session;

  @override
  Widget build(BuildContext context) {
    final rule = session.lobby?.rule ?? 'combined';
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(
          session.isHost ? 'How is a round won?' : 'How a round is won · the host picks',
          style: text.labelLarge?.copyWith(color: Palette.steel),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            for (final (id, label) in teamRules)
              ChoiceChip(
                key: ValueKey('rule-$id'),
                label: Text(label),
                selected: rule == id,
                selectedColor: Palette.ember.withValues(alpha: 0.35),
                labelStyle: TextStyle(color: Palette.whiteHeat),
                checkmarkColor: Palette.whiteHeat,
                side: BorderSide(color: rule == id ? Palette.molten : Palette.ash),
                onSelected: session.isHost ? (_) => session.setRule(id) : null,
              ),
          ],
        ),
        Text(
          ruleBlurb(rule),
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: Palette.molten),
        ),
      ],
    );
  }
}

/// The end of a Team Versus series: each team's round wins (the winners
/// ringed) and who was on it, with the round wins they raced in.
class TeamResults extends StatelessWidget {
  const TeamResults({super.key, required this.session, required this.series});

  final VsSession session;
  final SeriesEnd series;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final tally = series.teamTally ?? const [0, 0];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TeamTally(session: session, tally: tally, winner: series.team),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final team in const [0, 1]) ...[
              if (team == 1) const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final p in series.podium)
                      if (p.team == team)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            '${p.id == session.me ? 'You' : session.nameOf(p.id)} · ${p.wins} ${p.wins == 1 ? 'win' : 'wins'}',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium?.copyWith(color: session.colorOf(p.id)),
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
