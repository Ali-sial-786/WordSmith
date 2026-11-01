import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/game/rune_session.dart';
import 'package:wordsmith/net/room_client.dart';

/// A local stand-in for a Rune Rush room that records what the client sends.
class _LocalRoom {
  late HttpServer server;
  final received = <Map<String, dynamic>>[];
  final sockets = <WebSocket>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req, protocolSelector: (offered) => offered.first);
      sockets.add(ws);
      ws.listen((m) {
        final msg = jsonDecode(m as String) as Map<String, dynamic>;
        if (msg['op'] != 'PING') received.add(msg);
      });
    });
  }

  String get base => 'http://127.0.0.1:${server.port}';

  void send(Map<String, Object?> m) => sockets.last.add(jsonEncode(m));
}

const _tiles = ['C', 'A', 'T', 'S', 'O', 'R', 'E', 'D', 'QU', 'I', 'L', 'T', 'N', 'M', 'P', 'H'];

Map<String, Object?> _lobby(String phase, {String mode = 'rune', String teamScoring = 'pooled'}) => {
  'op': 'LOBBY',
  'code': 'R5X7KQ',
  'mode': mode,
  'phase': phase,
  'hostId': 'u1',
  'heat': 2,
  'rune': {'size': 4, 'seconds': 90, 'min': 3, 'rounds': 3, 'teamScoring': teamScoring},
  'players': [
    for (final (i, id) in ['u1', 'u2', 'u3', 'u4'].indexed)
      {
        'id': id,
        'username': 'P$i',
        'avatar': 'avatar_01',
        'level': 3,
        'color': i,
        'ready': true,
        'connected': true,
        if (mode == 'runeteam') 'team': i % 2,
      },
  ],
};

Map<String, Object?> _start(int now, {int round = 1, bool team = false, bool tiebreak = false}) => {
  'op': 'ROUND_START',
  'game': 'rune',
  'round': round,
  'rounds': 3,
  'tiebreak': tiebreak,
  'players': ['u1', 'u2', 'u3', 'u4'],
  'size': 4,
  'tiles': _tiles,
  'min': 3,
  'seconds': 90,
  'startsAt': now + 3000,
  'endsAt': now + 93000,
  'serverNow': now,
  'heat': 2,
  'totals': {'u1': 4, 'u2': 2, 'u3': 0, 'u4': 1},
  if (team) ...{
    'teams': {'u1': 0, 'u2': 1, 'u3': 0, 'u4': 1},
    'teamScoring': 'pooled',
    'teamTotals': [4, 3],
  },
};

Map<String, Object?> _end({Map<String, Object?>? next, int round = 1}) => {
  'op': 'ROUND_END',
  'game': 'rune',
  'round': round,
  'tiebreak': false,
  'size': 4,
  'tiles': _tiles,
  'found': {
    'u1': [
      {'word': 'QUILT', 'points': 6, 'unique': true},
      {'word': 'CAT', 'points': 1, 'unique': false},
    ],
    'u2': [
      {'word': 'CAT', 'points': 1, 'unique': false},
    ],
    'u3': [],
    'u4': [],
  },
  'points': {'u1': 7, 'u2': 1, 'u3': 0, 'u4': 0},
  'winner': 'u1',
  'words': ['QUILT', 'CATS', 'CAT', 'ORE'],
  'total': 4,
  'totals': {'u1': 11, 'u2': 3, 'u3': 0, 'u4': 1},
  'next': next,
  'standingsEndsAt': next == null ? null : 0,
};

void main() {
  late _LocalRoom room;
  late RuneSession session;

  setUp(() async {
    room = _LocalRoom();
    await room.start();
    session = RuneSession(
      client: RoomClient(baseUrl: room.base, code: 'R5X7KQ', token: () async => 'tok'),
      me: 'u1',
    );
    await session.start();
  });

  tearDown(() async {
    session.dispose();
    await room.server.close(force: true);
  });

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 200 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ok(), isTrue);
  }

  test('the lobby carries the settings; the host changes them and starts', () async {
    await until(() => room.sockets.isNotEmpty);
    room.send(_lobby('lobby'));
    await until(() => session.lobby != null);
    final lobby = session.lobby!;
    expect(lobby.isRune, isTrue);
    expect(lobby.isVs, isFalse, reason: 'no molds');
    expect(lobby.isTeam, isFalse);
    expect(lobby.maxPlayers, 6);
    expect(session.settings.seconds, 90);
    expect(session.rounds, 3);
    session
      ..setRune(size: 5)
      ..setRune(seconds: 60, min: 4)
      ..setMode('runeteam')
      ..startRound();
    await until(() => room.received.length == 4);
    expect(room.received, [
      {
        'op': 'CONFIG',
        'rune': {'size': 5},
      },
      {
        'op': 'CONFIG',
        'rune': {'seconds': 60, 'min': 4},
      },
      {'op': 'CONFIG', 'mode': 'runeteam'},
      {'op': 'START'},
    ]);
  });

  test('a round: my words, everyone\'s counts, then the standings and totals', () async {
    await until(() => room.sockets.isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    room
      ..send(_lobby('countdown'))
      ..send(_start(now));
    await until(() => session.grid != null);
    expect(session.racing, isTrue);
    expect(session.minLength, 3);
    expect(session.totals['u1'], 4);
    expect(session.countdownLeft, greaterThan(const Duration(seconds: 1)));
    expect(session.timeLeft, greaterThan(const Duration(seconds: 80)));
    expect(session.tally, {'u1': 0, 'u2': 0, 'u3': 0, 'u4': 0});

    session.submit('QUILT');
    await until(() => room.received.isNotEmpty);
    expect(room.received.last, {'op': 'SUBMIT', 'word': 'QUILT', 'seq': 1});
    room
      ..send({'op': 'WORD_RESULT', 'seq': 1, 'word': 'QUILT', 'result': 'found', 'points': 3})
      ..send({'op': 'RUNE_TALLY', 'id': 'u1', 'words': 1})
      ..send({'op': 'RUNE_TALLY', 'id': 'u2', 'words': 4});
    await until(() => session.tally['u2'] == 4);
    expect(session.mine.map((w) => (w.word, w.by, w.points)), [('QUILT', 'u1', 3)]);
    expect(session.has('QUILT'), isTrue);
    expect(session.myPoints, 3);

    room
      ..send(
        _end(
          next: {
            'round': 2,
            'tiebreak': false,
            'players': ['u1', 'u2', 'u3', 'u4'],
          },
        ),
      )
      ..send(_lobby('standings'));
    await until(() => session.phase == 'standings');
    expect(session.standings!.winner, 'u1');
    expect(session.countRound, 1, reason: 'ended while I was here: counted on screen');
    expect(session.standings!.found['u1']!.first.unique, isTrue);
    expect(session.standings!.foundWords, {'QUILT', 'CAT'});
    expect(session.roundOver, isTrue);
    expect(session.finalRound, isFalse);
    expect(session.totals['u1'], 11);
    expect(session.standingsOrder.first, 'u1');

    // The next round starts fresh.
    room.send(_start(now, round: 2));
    await until(() => session.grid!.round == 2);
    expect(session.standings, isNull);
    expect(session.mine, isEmpty);
  });

  test('pooled teams share their words; the game ends on a podium', () async {
    await until(() => room.sockets.isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    room
      ..send(_lobby('round', mode: 'runeteam'))
      ..send(_start(now, team: true));
    await until(() => session.grid != null);
    expect(session.isTeam, isTrue);
    expect(session.pooled, isTrue);
    expect(session.myTeam, 0);
    expect(session.teamOf('u4'), 1);
    expect(session.teamTotals, [4, 3]);

    room.send({'op': 'RUNE_WORD', 'word': 'CATS', 'by': 'u3', 'points': 2});
    await until(() => session.mine.isNotEmpty);
    expect(session.mine.single.by, 'u3');
    expect(session.feed.first.text, contains('CATS'));

    room
      ..send(_end())
      ..send({
        'op': 'SERIES_END',
        'game': 'rune',
        'winner': null,
        'team': 0,
        'teamTally': [2, 1],
        'early': false,
        'forfeit': false,
        'rounds': 3,
        'scoring': 'total',
        'history': [],
        'podium': [
          {'id': 'u1', 'username': 'P0', 'wins': 2, 'place': 1, 'team': 0, 'score': 11},
          {'id': 'u3', 'username': 'P2', 'wins': 2, 'place': 1, 'team': 0, 'score': 0},
          {'id': 'u2', 'username': 'P1', 'wins': 1, 'place': 2, 'team': 1, 'score': 3},
        ],
        'xp': {
          'u1': {'xp': 60, 'level': 4, 'levelUps': 0, 'rewards': {}},
        },
        'rune': {
          'settings': {'size': 4, 'seconds': 90, 'min': 3, 'rounds': 3, 'teamScoring': 'pooled'},
          'history': [_end()],
          'words': {'u1': 2, 'u2': 1, 'u3': 0},
          'teamTotals': [11, 4],
          'teamWords': [2, 1],
        },
      })
      ..send(_lobby('results', mode: 'runeteam'));
    await until(() => session.seriesEnd != null);
    expect(session.finalRound, isTrue);
    expect(session.showingFinalRound, isTrue, reason: 'the last round shows a while first');
    final r = session.seriesEnd!;
    expect(r.isRune, isTrue);
    expect(r.isTeam, isTrue);
    expect(r.rune!.teamTotals, [11, 4]);
    expect(r.rune!.history.single.points['u1'], 7);
    session.seeResults();
    expect(session.showingFinalRound, isFalse);
  });

  test('back in the room mid-round: the grid, my words and the counts', () async {
    await until(() => room.sockets.isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    room.send({
      'op': 'SNAPSHOT',
      'lobby': _lobby('round'),
      'round': {
        ..._start(now),
        'mine': [
          {'word': 'CAT', 'by': 'u1', 'points': 1},
        ],
        'tally': {'u1': 1, 'u2': 3, 'u3': 0, 'u4': 2},
      },
      'chat': [],
    });
    await until(() => session.grid != null);
    expect(session.phase, 'round');
    expect(session.mine.single.word, 'CAT');
    expect(session.tally['u2'], 3);

    // And during the standings.
    room.send({'op': 'SNAPSHOT', 'lobby': _lobby('standings'), 'standings': _end(next: null), 'chat': []});
    await until(() => session.standings != null);
    expect(session.standings!.points['u1'], 7);
    expect(session.countRound, isNull, reason: 'ended before I came back: not counted again');
    expect(session.totals['u1'], 11);
  });
}
