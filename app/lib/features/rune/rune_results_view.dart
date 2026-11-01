import 'package:flutter/material.dart';

import '../../engine/heat.dart';
import '../../game/rune_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/xp_award.dart';
import '../coop/room_chat.dart';
import '../vs/team_widgets.dart';
import 'rune_review.dart';
import 'rune_widgets.dart';

/// The end of a Rune Rush game: the places on points, my XP, the game round
/// by round (each opens for its words and grid), and a rematch.
class RuneResultsView extends StatelessWidget {
  const RuneResultsView({super.key, required this.session, required this.onLeave});

  final RuneSession session;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final r = session.seriesEnd!;
    final game = r.rune;
    final text = Theme.of(context).textTheme;
    final mine = r.xp[session.me];
    final team = r.isTeam;
    final iWon = team ? r.team != null && r.team == session.myTeam : r.winner == session.me;
    final history = game?.history ?? const <RuneRoundEnd>[];
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
            children: [
              Text(
                team
                    ? r.team == null
                          ? 'A shared win!'
                          : iWon
                          ? 'YOUR TEAM WINS!'
                          : '${teamName(r.team!)} wins!'
                    : r.winner == null
                    ? 'A shared win!'
                    : iWon
                    ? 'YOU WIN!'
                    : '${session.nameOf(r.winner)} wins!',
                key: const ValueKey('rune-results-title'),
                textAlign: TextAlign.center,
                style: displayStyle(
                  28,
                  color: iWon ? Palette.molten : Palette.whiteHeat,
                ).copyWith(shadows: iWon ? [Shadow(color: Palette.ember, blurRadius: 24)] : null),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  '${r.rounds} ${r.rounds == 1 ? 'round' : 'rounds'}',
                  if (r.forfeit) team ? 'the other team left' : 'everyone else left',
                  if (r.tiebreak) 'won in a tiebreaker',
                  if (!r.forfeit && !r.tiebreak && r.winner == null && r.team == null) 'tied after 3 tiebreakers',
                ].join(' · '),
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: Palette.steel),
              ),
              const SizedBox(height: 18),
              if (team && game?.teamTotals != null) ...[
                _TeamTotals(session: session, series: r, game: game!),
                if (session.lobby != null) ...[
                  const SizedBox(height: 16),
                  TeamPicker(
                    session: session,
                    row: (p) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          AvatarBadge(avatar: p.avatar, size: 32),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              p.id == session.me ? 'You' : session.nameOf(p.id),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleSmall?.copyWith(color: session.colorOf(p.id)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ] else
                for (final p in r.podium) _PlaceRow(session: session, place: p, words: game?.words[p.id] ?? 0),
              if (mine != null) ...[
                const SizedBox(height: 14),
                XpAwardBanner(xp: mine.xp, level: mine.level, levelUps: mine.levelUps),
                if (mine.heatBonus > 0)
                  Text(
                    'Includes +${mine.heatBonus} for '
                    '${Heat.fromValue((session.grid?.heat ?? session.lobby?.heat ?? 1).clamp(1, 6)).label}',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: Palette.molten),
                  ),
              ],
              if (history.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Round by round',
                  textAlign: TextAlign.center,
                  style: displayStyle(18, color: Palette.molten),
                ),
                Text(
                  'Tap a round for its grid and words',
                  textAlign: TextAlign.center,
                  style: text.labelMedium?.copyWith(color: Palette.steel),
                ),
                const SizedBox(height: 6),
                for (final end in history)
                  ListTile(
                    key: ValueKey('rune-history-${end.round}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Text(end.tiebreak ? 'TB' : '${end.round}', style: displayStyle(18)),
                    title: Text(runeRoundHeadline(session, end), maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${end.size}×${end.size} · ${end.foundWords.length} of ${end.total} words found'),
                    trailing: Icon(Icons.chevron_right, color: Palette.steel),
                    onTap: () => _openRound(context, end),
                  ),
              ],
            ],
          ),
        ),
        _Actions(session: session, onLeave: onLeave),
      ],
    );
  }

  void _openRound(BuildContext context, RuneRoundEnd end) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Palette.forgeBlack,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
        children: [
          Text(
            end.tiebreak ? 'Tiebreaker round' : 'Round ${end.round}',
            textAlign: TextAlign.center,
            style: displayStyle(20, color: Palette.molten),
          ),
          Text(runeRoundHeadline(session, end), textAlign: TextAlign.center),
          const SizedBox(height: 10),
          RuneRoundReview(session: session, end: end),
        ],
      ),
    ),
  );
}

/// One place in a Rune Rush game: the medal, the smith, points, words and rounds won.
class _PlaceRow extends StatelessWidget {
  const _PlaceRow({required this.session, required this.place, required this.words});

  final RuneSession session;
  final PodiumPlace place;
  final int words;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final player = session.lobby?.player(place.id);
    final metal = switch (place.place) {
      1 => Palette.molten,
      2 => const Color(0xFFC0C6CC),
      3 => const Color(0xFFB0703F),
      _ => Palette.steel,
    };
    final first = place.place == 1;
    return Container(
      key: ValueKey('rune-place-${place.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: first ? 10 : 6),
      decoration: BoxDecoration(
        color: first ? Palette.ember.withValues(alpha: 0.16) : Palette.soot.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: first ? Palette.molten : Palette.ash, width: first ? 2 : 1),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: first
                ? GameIcon('crown', size: 26, color: Palette.molten)
                : Text(
                    '${place.place}',
                    textAlign: TextAlign.center,
                    style: displayStyle(22, color: metal),
                  ),
          ),
          const SizedBox(width: 6),
          AvatarBadge(avatar: player?.avatar ?? 'avatar_01', size: first ? 48 : 38),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  place.id == session.me ? 'You' : session.nameOf(place.id),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(color: session.colorOf(place.id)),
                ),
                Text('$words words · ${place.wins} ${place.wins == 1 ? 'round' : 'rounds'} won', style: text.bodySmall),
              ],
            ),
          ),
          Text('${place.score ?? 0}', style: displayStyle(first ? 26 : 20, color: metal)),
          Text(' pts', style: text.labelSmall),
        ],
      ),
    );
  }
}

/// Team Rune Rush: each team's points over the game (the winners ringed), and who scored what.
class _TeamTotals extends StatelessWidget {
  const _TeamTotals({required this.session, required this.series, required this.game});

  final RuneSession session;
  final SeriesEnd series;
  final RuneGame game;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final totals = game.teamTotals ?? const [0, 0];
    final words = game.teamWords ?? const [0, 0];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final team in const [0, 1]) ...[
          if (team == 1) const SizedBox(width: 10),
          Expanded(
            child: Container(
              key: ValueKey('rune-team-total-$team'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Palette.team(team).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: team == series.team ? Palette.molten : Palette.team(team),
                  width: team == series.team ? 2.5 : 1,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    team == session.myTeam ? '${teamName(team)} (you)' : teamName(team),
                    style: text.titleSmall?.copyWith(color: Palette.team(team)),
                  ),
                  Text('${totals[team]}', style: text.headlineMedium?.copyWith(color: Palette.whiteHeat)),
                  Text('points · ${words[team]} words', style: text.labelSmall),
                  const SizedBox(height: 6),
                  for (final p in series.podium)
                    if (p.team == team)
                      Text(
                        '${p.id == session.me ? 'You' : session.nameOf(p.id)} · ${p.score ?? 0}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(color: session.colorOf(p.id)),
                      ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Leave, the host's rematch and set-up, and the chat.
class _Actions extends StatelessWidget {
  const _Actions({required this.session, required this.onLeave});

  final RuneSession session;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final rounds = session.settings.rounds;
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
        child: Row(
          children: [
            OutlinedButton(onPressed: onLeave, child: const Text('Leave')),
            const SizedBox(width: 12),
            Expanded(
              child: session.isHost
                  ? PlateButton(
                      label: 'Rematch',
                      sublabel: 'A new $rounds-round game',
                      icon: 'trophy',
                      primary: true,
                      onPressed: session.again,
                    )
                  : Text(
                      'Waiting for ${session.nameOf(session.lobby?.hostId)} to start a rematch…',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: Palette.steel),
                    ),
            ),
            if (session.isHost)
              IconButton(
                key: const ValueKey('to-lobby'),
                tooltip: 'Change the grid, timer, rounds or mode',
                icon: Icon(Icons.tune, color: Palette.molten),
                onPressed: () => session.setMode(session.lobby?.mode ?? 'rune'),
              ),
            if (session.chatEnabled) ...[const SizedBox(width: 4), ChatButton(session: session)],
          ],
        ),
      ),
    );
  }
}
