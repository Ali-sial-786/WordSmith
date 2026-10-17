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
    'ROUND_END' => RoundEnd.fromJson(m),
    'SNAPSHOT' => RoomSnapshot.fromJson(m),
    'EMOTE' => RoomEmote(m['from'] as String, m['emote'] as String),
    'ERROR' => RoomError(m['code'] as String? ?? 'unknown'),
    _ => null,
  };
}

Map<String, int> _scores(Object? j) => {
  for (final e in ((j as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt(),
};

List<(int, String)> _slotWords(Object? j) => [
  for (final a in ((j as List?) ?? const []).cast<Map<String, dynamic>>())
    (a['slot'] as int, a['word'] as String),
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
  });

  factory RoomLobby.fromJson(Map<String, dynamic> j) => RoomLobby(
    code: j['code'] as String,
    mode: j['mode'] as String? ?? 'coop',
    phase: j['phase'] as String? ?? 'lobby',
    hostId: j['hostId'] as String? ?? '',
    heat: j['heat'] as int? ?? 1,
    players: [
      for (final p in ((j['players'] as List?) ?? const []).cast<Map<String, dynamic>>())
        RoomPlayer.fromJson(p),
    ],
  );

  final String code;
  final String mode;
  final String phase;
  final String hostId;
  final int heat;
  final List<RoomPlayer> players;

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

  List<CellPos> get cells => [
    for (var i = 0; i < length; i++) across ? (x: x + i, y: y) : (x: x, y: y + i),
  ];
}

class RoundStart extends RoomEvent {
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
    slots: [
      for (final s in (j['slots'] as List).cast<Map<String, dynamic>>())
        RemoteSlot(s['slot'] as int, s['x'] as int, s['y'] as int, s['d'] == 'a', s['len'] as int),
    ],
    pickups: [
      for (final p in ((j['pickups'] as List?) ?? const []).cast<Map<String, dynamic>>())
        (x: p['x'] as int, y: p['y'] as int),
    ],
  );

  final int round;
  final int heat;
  final int startsAt;
  final int endsAt;
  final int serverNow;
  final String letters;
  final int cols;
  final int rows;
  final List<RemoteSlot> slots;
  final List<CellPos> pickups;
}

class WordResult extends RoomEvent {
  const WordResult({
    required this.seq,
    required this.word,
    required this.result,
    this.by,
    this.points = 0,
  });

  final int seq;
  final String word;

  /// `claimed`, `bonus`, `already`, `invalid`, `rate_limited` or `too_late`.
  final String result;
  final String? by;
  final int points;
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
  const BonusClaimed({
    required this.word,
    required this.by,
    required this.points,
    required this.scores,
  });

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
  const XpAward(this.xp, this.level, this.levelUps, this.rewards, {this.scrapHammers = 0});

  final int xp;
  final int level;
  final int levelUps;

  /// Level-up rewards.
  final Map<String, int> rewards;

  /// Hammer Strikes smelted from this round's bonus words (Scrap Bin).
  final int scrapHammers;
}

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
    xp: {
      for (final e in ((j['xp'] as Map?) ?? const {}).entries)
        e.key as String: XpAward(
          (e.value['xp'] as num?)?.toInt() ?? 0,
          (e.value['level'] as num?)?.toInt() ?? 1,
          (e.value['levelUps'] as num?)?.toInt() ?? 0,
          _scores(e.value['rewards']),
          scrapHammers: (e.value['scrapHammers'] as num?)?.toInt() ?? 0,
        ),
    },
  );

  final String reason;
  final int teamScore;
  final int filled;
  final int total;
  final int stars;
  final List<RoundPlayerResult> players;
  final String? mvp;
  final List<(int, String)> answers;
  final Map<String, XpAward> xp;

  bool get completed => reason == 'complete';
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
  });

  factory RoomSnapshot.fromJson(Map<String, dynamic> j) {
    final round = j['round'] as Map<String, dynamic>?;
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
      results: j['results'] == null
          ? null
          : RoundEnd.fromJson(j['results'] as Map<String, dynamic>),
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
}

class RoomEmote extends RoomEvent {
  const RoomEmote(this.from, this.emote);
  final String from;
  final String emote;
}

class RoomError extends RoomEvent {
  const RoomError(this.code);
  final String code;
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
  void startRound() => _send({'op': 'START'});
  void again() => _send({'op': 'AGAIN'});
  void emote(String emote) => _send({'op': 'EMOTE', 'emote': emote});

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
