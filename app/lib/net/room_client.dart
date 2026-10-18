import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../engine/puzzle.dart';
import 'hub_client.dart' show wsUri;
import 'socket.dart';

/// Messages from a room (shared/room-protocol.md).
sealed class RoomEvent {
  const RoomEvent();

  static RoomEvent? parse(Map<String, dynamic> m) => switch (m['op']) {
    'WELCOME' => RoomWelcome(m['you'] as String, (m['serverNow'] as num).toInt()),
    'LOBBY' => RoomLobby.fromJson(m),
    'ROUND_START' => RoundStart.fromJson(m),
    'WORD_RESULT' => WordResult(
      seq: m['seq'] as int,
      word: m['word'] as String? ?? '',
      result: m['result'] as String,
      by: m['by'] as String?,
      points: m['points'] as int? ?? 0,
      slot: m['slot'] as int?,
      auto: _slotWords(m['auto']),
      pickup: m['pickup'] as String?,
    ),
    'CLAIMED' => WordClaimed(
      slot: m['slot'] as int,
      word: m['word'] as String,
      by: m['by'] as String,
      points: m['points'] as int? ?? 0,
      scores: _scores(m['scores']),
      auto: _slotWords(m['auto']),
      pickup: m['pickup'] as String?,
    ),
    'BONUS' => BonusClaimed(
      word: m['word'] as String,
      by: m['by'] as String,
      points: m['points'] as int? ?? 0,
      scores: _scores(m['scores']),
    ),
    'REVEAL' => Revealed(
      by: m['by'] as String,
      kind: m['kind'] as String,
      cells: _cellLetters(m['cells']),
      auto: _slotWords(m['auto']),
    ),
    // Versus round ends say how the round was won; co-op ones don't.
    'ROUND_END' => m.containsKey('how') ? VsRoundEnd.fromJson(m) : RoundEnd.fromJson(m),
    'PROGRESS' => RacerProgress.fromJson(m),
    'HEATED' => HeatedSlot.fromJson(m),
    'MELT' => Melted((m['slot'] as num).toInt(), m['id'] as String?),
    'SERIES_END' => SeriesEnd.fromJson(m),
    'SNAPSHOT' => RoomSnapshot.fromJson(m),
    'EMOTE' => RoomEmote(m['from'] as String, m['emote'] as String),
    'CHAT' => RoomChat(ChatLine.fromJson(m)),
    'ERROR' => RoomError(m['code'] as String? ?? 'unknown'),
    _ => null,
  };
}

Map<String, int> _scores(Object? j) => {
  for (final e in ((j as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt(),
};

List<(int, String)> _slotWords(Object? j) => [
  for (final a in ((j as List?) ?? const []).cast<Map<String, dynamic>>()) (a['slot'] as int, a['word'] as String),
];

List<(CellPos, String)> _cellLetters(Object? j) => [
  for (final c in ((j as List?) ?? const []).cast<Map<String, dynamic>>())
    ((x: c['x'] as int, y: c['y'] as int), c['letter'] as String),
];

class RoomWelcome extends RoomEvent {
  const RoomWelcome(this.you, this.serverNow);
  final String you;
  final int serverNow;
}

class RoomPlayer {
  const RoomPlayer({
    required this.id,
    required this.username,
    required this.avatar,
    required this.level,
    required this.color,
    required this.ready,
    required this.connected,
  });

  factory RoomPlayer.fromJson(Map<String, dynamic> j) => RoomPlayer(
    id: j['id'] as String,
    username: j['username'] as String? ?? '?',
    avatar: j['avatar'] as String? ?? 'avatar_01',
    level: j['level'] as int? ?? 1,
    color: j['color'] as int? ?? 0,
    ready: j['ready'] as bool? ?? false,
    connected: j['connected'] as bool? ?? true,
  );

  final String id;
  final String username;
  final String avatar;
  final int level;
  final int color;
  final bool ready;
  final bool connected;
}

class RoomLobby extends RoomEvent {
  const RoomLobby({
    required this.code,
    required this.mode,
    required this.phase,
    required this.hostId,
    required this.heat,
    required this.players,
    this.series = 3,
    this.variant = 'classic',
    this.chosenHeat,
    int? autoHeat,
  }) : autoHeat = autoHeat ?? heat;

  factory RoomLobby.fromJson(Map<String, dynamic> j) => RoomLobby(
    code: j['code'] as String,
    mode: j['mode'] as String? ?? 'coop',
    phase: j['phase'] as String? ?? 'lobby',
    hostId: j['hostId'] as String? ?? '',
    heat: j['heat'] as int? ?? 1,
    players: [
      for (final p in ((j['players'] as List?) ?? const []).cast<Map<String, dynamic>>()) RoomPlayer.fromJson(p),
    ],
    series: j['series'] as int? ?? 3,
    variant: j['variant'] as String? ?? 'classic',
    // `heatChoice` is a tier or "auto"; older servers send neither field.
    chosenHeat: j['heatChoice'] is int ? j['heatChoice'] as int : null,
    autoHeat: j['autoHeat'] as int?,
  );

  final String code;
  final String mode;
  final String phase;
  final String hostId;

  /// The heat the next round or series plays (the current one's while it's on).
  final int heat;
  final List<RoomPlayer> players;

  /// The tier the host picked (1–6), or null while the room is on Auto.
  final int? chosenHeat;

  /// What Auto gives right now: the host's level in co-op, the middle level in Versus.
  final int autoHeat;

  /// Versus: best of this many rounds.
  final int series;

  /// `classic` or `survival` (shared/survival.md).
  final String variant;

  bool get isVs => mode == 'vs';
  bool get survival => variant == 'survival';
  bool get autoHeatOn => chosenHeat == null;
  int get maxPlayers => isVs ? 5 : 4;

  RoomPlayer? player(String id) {
    for (final p in players) {
      if (p.id == id) return p;
    }
    return null;
  }
}

class RemoteSlot {
  const RemoteSlot(this.slot, this.x, this.y, this.across, this.length);

  final int slot;
  final int x;
  final int y;
  final bool across;
  final int length;

  List<CellPos> get cells => [for (var i = 0; i < length; i++) across ? (x: x + i, y: y) : (x: x, y: y + i)];
}

List<RemoteSlot> _remoteSlots(List<dynamic> j) => [
  for (final s in j.cast<Map<String, dynamic>>())
    RemoteSlot(s['slot'] as int, s['x'] as int, s['y'] as int, s['d'] == 'a', s['len'] as int),
];

/// A mold's shape: its grid and slots, never the words.
abstract interface class MoldShape {
  int get cols;
  int get rows;
  List<RemoteSlot> get slots;
}

class RoundStart extends RoomEvent implements MoldShape {
  const RoundStart({
    required this.round,
    required this.heat,
    required this.startsAt,
    required this.endsAt,
    required this.serverNow,
    required this.letters,
    required this.cols,
    required this.rows,
    required this.slots,
    required this.pickups,
    this.series,
    this.regular,
    this.suddenDeath = false,
    this.racers = const [],
    this.tally = const {},
    this.variant = 'classic',
    this.heated,
  });

  factory RoundStart.fromJson(Map<String, dynamic> j) => RoundStart(
    round: j['round'] as int? ?? 1,
    heat: j['heat'] as int? ?? 1,
    startsAt: (j['startsAt'] as num).toInt(),
    endsAt: (j['endsAt'] as num).toInt(),
    serverNow: (j['serverNow'] as num?)?.toInt() ?? 0,
    letters: j['letters'] as String,
    cols: j['cols'] as int,
    rows: j['rows'] as int,
    slots: _remoteSlots(j['slots'] as List),
    pickups: [
      for (final p in ((j['pickups'] as List?) ?? const []).cast<Map<String, dynamic>>())
        (x: p['x'] as int, y: p['y'] as int),
    ],
    series: j['series'] as int?,
    regular: j['regular'] as int?,
    suddenDeath: j['suddenDeath'] as bool? ?? false,
    racers: [for (final id in (j['players'] as List?) ?? const []) id as String],
    tally: _scores(j['tally']),
    variant: j['variant'] as String? ?? 'classic',
    heated: j['heated'] is Map ? HeatedSlot.fromJson((j['heated'] as Map).cast()) : null,
  );

  final int round;
  final int heat;
  final int startsAt;
  final int endsAt;
  final int serverNow;
  final String letters;
  @override
  final int cols;
  @override
  final int rows;
  @override
  final List<RemoteSlot> slots;
  final List<CellPos> pickups;

  /// Versus: series length, the regular round number (null in sudden death),
  /// who races this round (everyone else watches) and wins so far.
  final int? series;
  final int? regular;
  final bool suddenDeath;
  final List<String> racers;
  final Map<String, int> tally;

  /// Survival: `survival`, with the first heated slot.
  final String variant;
  final HeatedSlot? heated;

  bool get survival => variant == 'survival';
}

/// Survival: the slot now heated (the team's in co-op, mine in Versus) and
/// when it melts, in server time.
class HeatedSlot extends RoomEvent {
  const HeatedSlot({
    required this.slot,
    required this.startsAt,
    required this.deadline,
    required this.durationMs,
    required this.saved,
    this.serverNow = 0,
  });

  factory HeatedSlot.fromJson(Map<String, dynamic> j) => HeatedSlot(
    slot: (j['slot'] as num).toInt(),
    startsAt: (j['startsAt'] as num?)?.toInt() ?? 0,
    deadline: (j['deadline'] as num).toInt(),
    durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
    saved: (j['saved'] as num?)?.toInt() ?? 0,
    serverNow: (j['serverNow'] as num?)?.toInt() ?? 0,
  );

  final int slot;
  final int startsAt;
  final int deadline;
  final int durationMs;

  /// Heated words saved so far this round.
  final int saved;
  final int serverNow;
}

/// Survival: a heated word melted; the round is over. [id] is whose mold
/// (Versus).
class Melted extends RoomEvent {
  const Melted(this.slot, this.id);

  final int slot;
  final String? id;
}

class WordResult extends RoomEvent {
  const WordResult({
    required this.seq,
    required this.word,
    required this.result,
    this.by,
    this.points = 0,
    this.slot,
    this.auto = const [],
    this.pickup,
  });

  final int seq;
  final String word;

  /// `claimed`, `bonus`, `already`, `invalid`, `rate_limited` or `too_late`.
  final String result;
  final String? by;
  final int points;

  /// Versus `claimed`: the slot on my own mold, crossing slots it completed,
  /// and an ember collected (granted after the series).
  final int? slot;
  final List<(int, String)> auto;
  final String? pickup;
}

/// Versus: how full a racer's mold is (never their words).
class RacerProgress extends RoomEvent {
  const RacerProgress(this.id, this.filled, this.total, {this.slots});

  factory RacerProgress.fromJson(Map<String, dynamic> j) => RacerProgress(
    j['id'] as String,
    (j['filled'] as num?)?.toInt() ?? 0,
    (j['total'] as num?)?.toInt() ?? 0,
    slots: j['slots'] is List ? [for (final s in j['slots'] as List) (s as num).toInt()] : null,
  );

  final String id;
  final int filled;
  final int total;

  /// Only while I'm watching the round: the racer's complete slots (no letters).
  final List<int>? slots;

  double get fraction => total == 0 ? 0 : filled / total;
}

List<RacerProgress> _progress(Object? j) => [
  for (final p in ((j as List?) ?? const []).cast<Map<String, dynamic>>()) RacerProgress.fromJson(p),
];

Map<String, List<int>> _molds(Object? j) => {
  for (final e in ((j as Map?) ?? const {}).entries)
    e.key as String: [for (final s in (e.value as List?) ?? const []) (s as num).toInt()],
};

({String id, int slot})? _melted(Object? j) =>
    j is Map ? (id: j['id'] as String, slot: (j['slot'] as num).toInt()) : null;

/// Versus: the round after this one's standings.
class NextRound {
  const NextRound(this.round, this.suddenDeath, this.racers);

  final int round;
  final bool suddenDeath;
  final List<String> racers;
}

class VsRoundEnd extends RoomEvent {
  const VsRoundEnd({
    required this.reason,
    required this.winner,
    required this.how,
    required this.progress,
    required this.tally,
    required this.answers,
    this.next,
    this.standingsEndsAt,
    this.round,
    this.melted,
    this.molds = const {},
  });

  factory VsRoundEnd.fromJson(Map<String, dynamic> j) {
    final next = j['next'] as Map<String, dynamic>?;
    return VsRoundEnd(
      reason: j['reason'] as String? ?? 'timeout',
      winner: j['winner'] as String?,
      how: j['how'] as String? ?? 'none',
      progress: _progress(j['progress']),
      tally: _scores(j['tally']),
      answers: _slotWords(j['answers']),
      next: next == null
          ? null
          : NextRound((next['round'] as num?)?.toInt() ?? 0, next['suddenDeath'] as bool? ?? false, [
              for (final id in (next['players'] as List?) ?? const []) id as String,
            ]),
      standingsEndsAt: (j['standingsEndsAt'] as num?)?.toInt(),
      round: (j['round'] as num?)?.toInt(),
      melted: _melted(j['melted']),
      molds: _molds(j['molds']),
    );
  }

  final String reason;
  final String? winner;

  /// `finished`, `timeout`, `survived` (someone else melted) or `none`.
  final String how;

  /// Survival: whose word melted, ending the round.
  final ({String id, int slot})? melted;
  final List<RacerProgress> progress;

  /// Each racer's complete slots (forged or filled in by themselves), now the
  /// round is over: rivals' cells are never shown before. Empty from a server
  /// that doesn't send them.
  final Map<String, List<int>> molds;
  final Map<String, int> tally;
  final List<(int, String)> answers;
  final NextRound? next;
  final int? standingsEndsAt;

  /// The round that ended.
  final int? round;
}

class PodiumPlace {
  const PodiumPlace(this.id, this.username, this.wins, this.place);

  final String id;
  final String username;
  final int wins;
  final int place;
}

Map<String, List<String>> _bins(Object? j) => {
  for (final e in ((j as Map?) ?? const {}).entries)
    e.key as String: [for (final w in (e.value as List?) ?? const []) w as String],
};

/// Versus: one round of a finished series, as `SERIES_END.history` sums it
/// up: how it went, every racer's mold with the mold's shape, the words and
/// everyone's Scrap Bin, so it can be drawn and gone back over without having
/// seen that round start.
class SeriesRound implements MoldShape {
  const SeriesRound({
    required this.round,
    required this.suddenDeath,
    required this.reason,
    required this.winner,
    required this.how,
    required this.cols,
    required this.rows,
    required this.slots,
    required this.progress,
    required this.molds,
    this.melted,
    this.letters = '',
    this.answers = const [],
    this.bins = const {},
    this.saved = const {},
  });

  factory SeriesRound.fromJson(Map<String, dynamic> j) => SeriesRound(
    round: (j['round'] as num?)?.toInt() ?? 0,
    suddenDeath: j['suddenDeath'] as bool? ?? false,
    reason: j['reason'] as String? ?? 'timeout',
    winner: j['winner'] as String?,
    how: j['how'] as String? ?? 'none',
    cols: (j['cols'] as num?)?.toInt() ?? 0,
    rows: (j['rows'] as num?)?.toInt() ?? 0,
    slots: _remoteSlots((j['slots'] as List?) ?? const []),
    progress: _progress(j['progress']),
    molds: _molds(j['molds']),
    melted: _melted(j['melted']),
    letters: j['letters'] as String? ?? '',
    answers: _slotWords(j['answers']),
    bins: _bins(j['bins']),
    saved: _scores(j['saved']),
  );

  final int round;
  final bool suddenDeath;

  /// `finished`, `timeout` or `melted` (Survival).
  final String reason;
  final String? winner;

  /// `finished`, `timeout`, `survived` (someone else melted) or `none`.
  final String how;
  @override
  final int cols;
  @override
  final int rows;
  @override
  final List<RemoteSlot> slots;

  /// The racers of the round (just the tied leaders in sudden death).
  final List<RacerProgress> progress;

  /// Each racer's complete slots, as in that round's [VsRoundEnd.molds].
  final Map<String, List<int>> molds;

  /// Survival: whose word melted, ending the round, and each racer's words
  /// saved.
  final ({String id, int slot})? melted;
  final Map<String, int> saved;

  /// The anvil everyone had, every grid word by slot, and each racer's bonus
  /// words in the order found. Empty from a server that doesn't send them.
  final String letters;
  final List<(int, String)> answers;
  final Map<String, List<String>> bins;
}

class SeriesEnd extends RoomEvent {
  const SeriesEnd({
    required this.winner,
    required this.early,
    required this.forfeit,
    required this.rounds,
    required this.podium,
    required this.xp,
    this.history = const [],
    this.json = const {},
  });

  factory SeriesEnd.fromJson(Map<String, dynamic> j) => SeriesEnd(
    winner: j['winner'] as String?,
    early: j['early'] as bool? ?? false,
    forfeit: j['forfeit'] as bool? ?? false,
    rounds: (j['rounds'] as num?)?.toInt() ?? 0,
    podium: [
      for (final p in ((j['podium'] as List?) ?? const []).cast<Map<String, dynamic>>())
        PodiumPlace(
          p['id'] as String,
          p['username'] as String? ?? '',
          (p['wins'] as num?)?.toInt() ?? 0,
          (p['place'] as num?)?.toInt() ?? 0,
        ),
    ],
    xp: _xpAwards(j['xp']),
    history: [
      for (final r in ((j['history'] as List?) ?? const []).cast<Map<String, dynamic>>()) SeriesRound.fromJson(r),
    ],
    json: j,
  );

  final String? winner;
  final bool early;
  final bool forfeit;
  final int rounds;
  final List<PodiumPlace> podium;
  final Map<String, XpAward> xp;

  /// Every round played, in order. Empty from a server that doesn't send it.
  final List<SeriesRound> history;

  /// The message as it came, kept in the puzzle history.
  final Map<String, dynamic> json;

  /// Letters each racer filled over the rounds they raced.
  Map<String, int> get letters {
    final total = <String, int>{};
    for (final r in history) {
      for (final p in r.progress) {
        total[p.id] = (total[p.id] ?? 0) + p.filled;
      }
    }
    return total;
  }
}

class WordClaimed extends RoomEvent {
  const WordClaimed({
    required this.slot,
    required this.word,
    required this.by,
    required this.points,
    required this.scores,
    required this.auto,
    this.pickup,
  });

  final int slot;
  final String word;
  final String by;
  final int points;
  final Map<String, int> scores;
  final List<(int, String)> auto;
  final String? pickup;
}

class BonusClaimed extends RoomEvent {
  const BonusClaimed({required this.word, required this.by, required this.points, required this.scores});

  final String word;
  final String by;
  final int points;
  final Map<String, int> scores;
}

class Revealed extends RoomEvent {
  const Revealed({required this.by, required this.kind, required this.cells, required this.auto});

  final String by;
  final String kind;
  final List<(CellPos, String)> cells;
  final List<(int, String)> auto;
}

class RoundPlayerResult {
  const RoundPlayerResult(this.id, this.points, this.words, this.longest, {this.username = '', this.bonus = 0});

  final String id;
  final int points;
  final int words;
  final String longest;

  /// Set even for players who have left the room since.
  final String username;

  /// Bonus words found.
  final int bonus;
}

class XpAward {
  const XpAward(
    this.xp,
    this.level,
    this.levelUps,
    this.rewards, {
    this.scrapHammers = 0,
    this.pickups = const {},
    this.heatBonus = 0,
    this.tiersAbove = 0,
  });

  final int xp;
  final int level;
  final int levelUps;

  /// Level-up rewards.
  final Map<String, int> rewards;

  /// Hammer Strikes smelted from this round's bonus words (Scrap Bin).
  final int scrapHammers;

  /// Versus: embers collected during the series, granted at the end.
  final Map<String, int> pickups;

  /// The part of [xp] the heat added, and how many tiers it ran above this
  /// smith's own (shared/room-protocol.md "XP and heat").
  final int heatBonus;
  final int tiersAbove;
}

Map<String, XpAward> _xpAwards(Object? j) => {
  for (final e in ((j as Map?) ?? const {}).entries)
    e.key as String: XpAward(
      (e.value['xp'] as num?)?.toInt() ?? 0,
      (e.value['level'] as num?)?.toInt() ?? 1,
      (e.value['levelUps'] as num?)?.toInt() ?? 0,
      _scores(e.value['rewards']),
      scrapHammers: (e.value['scrapHammers'] as num?)?.toInt() ?? 0,
      pickups: _scores(e.value['pickups']),
      heatBonus: (e.value['heatBonus'] as num?)?.toInt() ?? 0,
      tiersAbove: (e.value['tiersAbove'] as num?)?.toInt() ?? 0,
    ),
};

class RoundEnd extends RoomEvent {
  const RoundEnd({
    required this.reason,
    required this.teamScore,
    required this.filled,
    required this.total,
    required this.stars,
    required this.players,
    required this.mvp,
    required this.answers,
    required this.xp,
    this.saved = 0,
  });

  factory RoundEnd.fromJson(Map<String, dynamic> j) => RoundEnd(
    reason: j['reason'] as String? ?? 'timeout',
    teamScore: j['teamScore'] as int? ?? 0,
    filled: j['filled'] as int? ?? 0,
    total: j['total'] as int? ?? 0,
    stars: j['stars'] as int? ?? 0,
    players: [
      for (final p in ((j['players'] as List?) ?? const []).cast<Map<String, dynamic>>())
        RoundPlayerResult(
          p['id'] as String,
          p['points'] as int? ?? 0,
          p['words'] as int? ?? 0,
          p['longest'] as String? ?? '',
          username: p['username'] as String? ?? '',
          bonus: p['bonus'] as int? ?? 0,
        ),
    ]..sort((a, b) => b.points.compareTo(a.points)),
    mvp: j['mvp'] as String?,
    answers: _slotWords(j['answers']),
    xp: _xpAwards(j['xp']),
    saved: (j['saved'] as num?)?.toInt() ?? 0,
  );

  /// `complete`, `timeout` or `melted` (Survival).
  final String reason;
  final int teamScore;
  final int filled;
  final int total;
  final int stars;
  final List<RoundPlayerResult> players;
  final String? mvp;
  final List<(int, String)> answers;
  final Map<String, XpAward> xp;

  /// Survival: heated words the team saved.
  final int saved;

  bool get completed => reason == 'complete';
  bool get melted => reason == 'melted';
}

class RoomSnapshot extends RoomEvent {
  const RoomSnapshot({
    required this.lobby,
    this.round,
    this.claims = const [],
    this.auto = const [],
    this.bonus = const [],
    this.revealed = const [],
    this.scores = const {},
    this.results,
    this.mine = const [],
    this.mineAuto = const [],
    this.progress = const [],
    this.standings,
    this.seriesEnd,
    this.heated,
    this.saved = 0,
    this.chat = const [],
  });

  factory RoomSnapshot.fromJson(Map<String, dynamic> j) {
    final round = j['round'] as Map<String, dynamic>?;
    final mine = round?['mine'] as Map<String, dynamic>?;
    final results = j['results'] as Map<String, dynamic>?;
    final standings = j['standings'] as Map<String, dynamic>?;
    final vsResults = results != null && results.containsKey('podium');
    return RoomSnapshot(
      lobby: RoomLobby.fromJson(j['lobby'] as Map<String, dynamic>),
      round: round == null ? null : RoundStart.fromJson(round),
      claims: [
        for (final c in ((round?['claims'] as List?) ?? const []).cast<Map<String, dynamic>>())
          (c['slot'] as int, c['word'] as String, c['by'] as String),
      ],
      auto: _slotWords(round?['auto']),
      bonus: [
        for (final b in ((round?['bonus'] as List?) ?? const []).cast<Map<String, dynamic>>())
          (b['word'] as String, b['by'] as String),
      ],
      revealed: _cellLetters(round?['revealed']),
      scores: _scores(round?['scores']),
      results: results == null || vsResults ? null : RoundEnd.fromJson(results),
      mine: _slotWords(mine?['claims']),
      mineAuto: _slotWords(mine?['auto']),
      progress: [
        for (final p in ((round?['progress'] as List?) ?? const []).cast<Map<String, dynamic>>())
          RacerProgress.fromJson(p),
      ],
      standings: standings == null ? null : VsRoundEnd.fromJson(standings),
      seriesEnd: vsResults ? SeriesEnd.fromJson(results) : null,
      heated: round?['heated'] is Map ? HeatedSlot.fromJson((round!['heated'] as Map).cast()) : null,
      saved: (round?['saved'] as num?)?.toInt() ?? 0,
      chat: [for (final l in ((j['chat'] as List?) ?? const []).cast<Map<String, dynamic>>()) ChatLine.fromJson(l)],
    );
  }

  final RoomLobby lobby;
  final RoundStart? round;
  final List<(int, String, String)> claims;
  final List<(int, String)> auto;
  final List<(String, String)> bonus;
  final List<(CellPos, String)> revealed;
  final Map<String, int> scores;
  final RoundEnd? results;

  /// Versus: my own mold's words, everyone's progress, the last round's
  /// standings and the series result.
  final List<(int, String)> mine;
  final List<(int, String)> mineAuto;
  final List<RacerProgress> progress;
  final VsRoundEnd? standings;
  final SeriesEnd? seriesEnd;

  /// Survival: the heated slot right now (the team's, or mine in Versus)
  /// and the words saved so far.
  final HeatedSlot? heated;
  final int saved;

  /// The room's latest chat lines, oldest first.
  final List<ChatLine> chat;
}

class RoomEmote extends RoomEvent {
  const RoomEmote(this.from, this.emote);
  final String from;
  final String emote;
}

/// One line of room chat, profanity already starred out by the server.
class ChatLine {
  const ChatLine({required this.id, required this.from, required this.username, required this.text, required this.at});

  factory ChatLine.fromJson(Map<String, dynamic> j) => ChatLine(
    id: (j['id'] as num).toInt(),
    from: j['from'] as String,
    username: j['username'] as String? ?? '',
    text: j['text'] as String? ?? '',
    at: (j['at'] as num?)?.toInt() ?? 0,
  );

  /// Counts up from 1 in each room.
  final int id;
  final String from;

  /// The sender's username when they wrote it, for players who have left.
  final String username;
  final String text;

  /// Server time, ms.
  final int at;
}

class RoomChat extends RoomEvent {
  const RoomChat(this.line);
  final ChatLine line;
}

class RoomError extends RoomEvent {
  const RoomError(this.code);
  final String code;
}

/// Not from the server: the host role has just moved to me (the host left,
/// or was away too long). [RoomSession] adds it to its effects.
class BecameHost extends RoomEvent {
  const BecameHost();
}

/// The connection to one room. Rejoins automatically for a while after a
/// drop (the server keeps your seat for 30 s).
class RoomClient {
  RoomClient({
    required String baseUrl,
    required this.code,
    required Future<String?> Function() token,
    SocketConnector? connect,
    Duration rejoinWindow = const Duration(seconds: 28),
  }) {
    _socket = ReconnectingSocket(
      uri: wsUri(baseUrl, '/v1/ws/room/${Uri.encodeComponent(code)}'),
      token: token,
      connect: connect,
      giveUpAfter: rejoinWindow,
      maxRetryDelay: const Duration(seconds: 2),
      // 4001: account deleted; 4000–4099: the room closed or turned us away.
      shouldStop: (c) => c >= 4000 && c < 4100,
      onMessage: _onMessage,
      onOpen: () => _status.add(true),
      onDown: () => _status.add(false),
      onGiveUp: (c) {
        if (!_closed.isCompleted) _closed.complete(c);
      },
    );
  }

  final String code;
  late final ReconnectingSocket _socket;
  final _events = StreamController<RoomEvent>.broadcast();
  final _status = StreamController<bool>.broadcast();
  final _closed = Completer<int?>();
  int _seq = 0;

  Stream<RoomEvent> get events => _events.stream;

  /// true when (re)connected, false when the connection drops.
  Stream<bool> get connection => _status.stream;

  /// Completes when the client stops trying (room closed, or gone too long).
  Future<int?> get closed => _closed.future;
  bool get connected => _socket.connected;

  Future<void> start() => _socket.start();

  void _onMessage(String data) {
    try {
      final event = RoomEvent.parse(jsonDecode(data) as Map<String, dynamic>);
      if (event != null) _events.add(event);
    } on Object catch (e) {
      debugPrint('room message ignored: $e');
    }
  }

  void _send(Map<String, Object?> m) => _socket.send(jsonEncode(m));

  void ready(bool ready) => _send({'op': 'READY', 'ready': ready});

  /// Host only: best of [series] rounds (Versus), the variant (`classic` or
  /// `survival`), and the [heat]: a tier 1–6, or `'auto'`.
  void config({int? series, String? variant, Object? heat}) =>
      _send({'op': 'CONFIG', 'series': ?series, 'variant': ?variant, 'heat': ?heat});
  void startRound() => _send({'op': 'START'});
  void again() => _send({'op': 'AGAIN'});
  void emote(String emote) => _send({'op': 'EMOTE', 'emote': emote});
  void chat(String text) => _send({'op': 'CHAT', 'text': text});

  /// Sends a word; returns its sequence number (echoed in [WordResult]).
  int submit(String word) {
    _seq++;
    _send({'op': 'SUBMIT', 'word': word, 'seq': _seq});
    return _seq;
  }

  void hint(String kind, {CellPos? cell}) =>
      _send({'op': 'HINT', 'kind': kind, if (cell != null) 'x': cell.x, if (cell != null) 'y': cell.y});

  Future<void> leave() async {
    _send({'op': 'LEAVE'});
    await _socket.stop();
    if (!_closed.isCompleted) _closed.complete(1000);
  }

  Future<void> dispose() async {
    await _socket.stop();
    await _events.close();
    await _status.close();
  }
}
