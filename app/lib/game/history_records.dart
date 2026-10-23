import '../data/history.dart';
import '../engine/puzzle.dart';
import '../net/room_client.dart';
import 'coop_session.dart';
import 'daily_game.dart';
import 'replay_game.dart';
import 'solo_controller.dart';
import 'survival_run.dart';
import 'vs_session.dart';

/// A finished solo puzzle (a campaign stage, a replay or a Daily
/// Commission). [xp] once the reward is known; saved again with it.
PlayRecord soloRecord(SoloGame game, {required int at, int? xp}) {
  final kind = switch (game) {
    DailyGame() => PlayKind.daily,
    ReplayGame() => PlayKind.replay,
    _ => PlayKind.campaign,
  };
  final stage = switch (game) {
    SoloController(:final stage) || ReplayGame(:final stage) => stage,
    _ => null,
  };
  final hints = game.hintsUsed.values.fold(0, (a, b) => a + b);
  return PlayRecord(
    id: '${kind.name}-${game.board.puzzle.id}-$at',
    kind: kind,
    at: at,
    title: game.title,
    subtitle: game.subtitle,
    look: game.look,
    boards: [PlayedBoard.fromBoard(game.board)],
    result: {
      'stage': ?stage,
      if (game is DailyGame) 'date': game.info.date,
      'elapsedMs': game.playedMs,
      if (hints > 0) 'hints': hints,
      'xp': ?xp,
    },
  );
}

/// A Crucible run that played anything.
PlayRecord crucibleRecord(SurvivalRun run, {required int at}) => PlayRecord(
  id: 'crucible-${run.runId}',
  kind: PlayKind.crucible,
  at: at,
  title: 'The Crucible',
  subtitle: run.over ? 'Ended when a word melted' : 'Left mid-run',
  look: 'iron',
  boards: run.playedBoards,
  result: {
    'cleared': run.cleared,
    'saved': run.saved,
    'words': run.words,
    'melted': run.over,
    'elapsedMs': at - run.startedAt,
  },
);

/// A finished co-op round, the board as the team left it.
PlayRecord? coopRecord(CoopSession s, RoundEnd end, {required int at}) {
  final start = s.round;
  final mold = s.mold;
  final lobby = s.lobby;
  if (start == null || mold == null || lobby == null) return null;
  final board = _remoteBoard(
    start,
    answers: end.answers,
    owners: mold.owners,
    revealed: mold.revealedCells,
    bonus: [for (final (w, _) in s.bonusWords) w],
  );
  if (board == null) return null;
  final mine = end.players.where((p) => p.id == s.me).firstOrNull;
  final others = end.players.where((p) => p.id != s.me).length;
  return PlayRecord(
    id: 'coop-${lobby.code}-${start.startsAt}',
    kind: PlayKind.coop,
    at: at,
    title: end.melted || start.survival ? 'Co-op Survival' : 'Co-op',
    subtitle: others == 0 ? 'On your own' : 'With ${others == 1 ? '1 smith' : '$others smiths'}',
    look: 'bronze',
    boards: [board],
    players: _players(lobby, [for (final p in end.players) (p.id, p.username)]),
    me: s.me,
    result: {
      'code': lobby.code,
      'reason': end.reason,
      'completed': end.completed,
      'melted': end.melted,
      'stars': end.stars,
      'teamScore': end.teamScore,
      'filled': end.filled,
      'total': end.total,
      'heat': start.heat,
      'mvp': ?end.mvp,
      if (end.saved > 0) 'saved': end.saved,
      'points': {for (final p in end.players) p.id: p.points},
      'words': {for (final p in end.players) p.id: p.words},
      if (mine != null) 'myPoints': mine.points,
      if (end.xp[s.me] != null) 'xp': end.xp[s.me]!.xp,
    },
  );
}

/// A finished Versus series, with the whole SERIES_END for the look back.
PlayRecord? vsRecord(VsSession s, SeriesEnd end, {required int at}) {
  final lobby = s.lobby;
  if (lobby == null || end.json.isEmpty) return null;
  final me = end.podium.where((p) => p.id == s.me).firstOrNull;
  final others = end.podium.where((p) => p.id != s.me).length;
  return PlayRecord(
    id: 'vs-${lobby.code}-${s.round?.startsAt ?? at}',
    kind: PlayKind.vs,
    at: at,
    title: end.isTeam
        ? 'Team Versus'
        : end.history.any((r) => r.saved.isNotEmpty || r.reason == 'melted')
        ? 'Versus Survival'
        : 'Versus',
    subtitle: end.isTeam
        ? '${end.podium.length ~/ 2} against ${end.podium.length - end.podium.length ~/ 2} · best of ${lobby.series}'
        : others <= 0
        ? 'Best of ${lobby.series}'
        : 'Against ${others == 1 ? '1 smith' : '$others smiths'}',
    look: 'steel',
    players: _players(lobby, [for (final p in end.podium) (p.id, p.username)]),
    me: s.me,
    result: {
      'code': lobby.code,
      'winner': ?end.winner,
      'rounds': end.rounds,
      if (me != null) 'wins': me.wins,
      if (me != null) 'place': me.place,
      'tally': {for (final p in end.podium) p.id: p.wins},
      if (end.xp[s.me] != null) 'xp': end.xp[s.me]!.xp,
    },
    series: end.json,
  );
}

/// Everyone in the room or the results, with the colour they had.
List<PlayedPlayer> _players(RoomLobby lobby, List<(String, String)> results) {
  final seen = <String>{};
  return [
    for (final p in lobby.players)
      if (seen.add(p.id)) PlayedPlayer(id: p.id, username: p.username, color: p.color, avatar: p.avatar),
    for (final (id, name) in results)
      if (seen.add(id)) PlayedPlayer(id: id, username: name.isEmpty ? 'A smith' : name, color: 0),
  ];
}

/// A room's mold as a whole puzzle: the shape from ROUND_START, the words
/// from the answers. Null if the answers don't cover every slot.
PlayedBoard? _remoteBoard(
  RoundStart start, {
  required List<(int, String)> answers,
  required Map<int, String?> owners,
  required Set<CellPos> revealed,
  required List<String> bonus,
}) {
  final words = {for (final (slot, word) in answers) slot: word};
  final slots = [...start.slots]..sort((a, b) => a.slot.compareTo(b.slot));
  if (slots.any((s) => words[s.slot] == null)) return null;
  // Server slot ids are positions here, whatever they were.
  final position = {for (var i = 0; i < slots.length; i++) slots[i].slot: i};
  try {
    return PlayedBoard(
      puzzle: Puzzle(
        id: 'room',
        letters: start.letters,
        heat: start.heat,
        cols: start.cols,
        rows: start.rows,
        slots: [
          for (var i = 0; i < slots.length; i++)
            Slot(
              index: i,
              word: words[slots[i].slot]!,
              x: slots[i].x,
              y: slots[i].y,
              direction: slots[i].across ? Direction.across : Direction.down,
            ),
        ],
        bonus: const {},
      ),
      found: {
        for (final e in owners.entries)
          if (e.value != null && position[e.key] != null) position[e.key]!,
      },
      auto: {
        for (final e in owners.entries)
          if (e.value == null && position[e.key] != null) position[e.key]!,
      },
      revealed: revealed.toList(),
      bonus: bonus,
      owners: {
        for (final e in owners.entries)
          if (e.value != null && position[e.key] != null) position[e.key]!: e.value!,
      },
    );
  } on FormatException {
    return null;
  }
}
