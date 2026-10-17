import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_model.dart';

/// A local stand-in for a Versus room that records what the client sends.
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

Map<String, Object?> _lobby(String phase, {int series = 3}) => {
  'op': 'LOBBY',
  'code': 'V5X7KQ',
  'mode': 'vs',
  'phase': phase,
  'hostId': 'u1',
  'heat': 2,
  'series': series,
  'players': [
    {'id': 'u1', 'username': 'Ada', 'avatar': 'avatar_02', 'level': 8, 'color': 0, 'ready': true, 'connected': true},
    {'id': 'u2', 'username': 'sam', 'avatar': 'avatar_05', 'level': 6, 'color': 1, 'ready': true, 'connected': true},
    {'id': 'u3', 'username': 'Kit', 'avatar': 'avatar_07', 'level': 9, 'color': 4, 'ready': true, 'connected': true},
  ],
};

/// CAT across the top, COT down the left, TOE down the right: 7 letters.
Map<String, Object?> _roundStart(int now, {bool sudden = false, List<String> racers = const ['u1', 'u2', 'u3']}) => {
  'op': 'ROUND_START',
  'round': sudden ? 4 : 1,
  'heat': 2,
  'startsAt': now + 3000,
  'endsAt': now + 123000,
  'serverNow': now,
  'letters': 'CATOE',
  'cols': 3,
  'rows': 3,
  'slots': [
    {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 3},
    {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 3},
    {'slot': 2, 'x': 2, 'y': 0, 'd': 'd', 'len': 3},
  ],
  'pickups': [
    {'x': 2, 'y': 2},
  ],
  'series': 3,
  'regular': sudden ? null : 1,
  'suddenDeath': sudden,
  'players': racers,
  'tally': {'u1': 0, 'u2': 0, 'u3': 0},
};

void main() {
  late _LocalRoom room;
  late VsSession session;

  setUp(() async {
    room = _LocalRoom();
    await room.start();
    session = VsSession(client: RoomClient(baseUrl: room.base, code: 'V5X7KQ', token: () async => 'tok'), me: 'u1');
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

  test('the host picks the series length and starts', () async {
    await until(() => room.sockets.isNotEmpty);
    room.send(_lobby('lobby'));
    await until(() => session.lobby != null);
    expect(session.lobby!.isVs, isTrue);
    expect(session.lobby!.maxPlayers, 5);
    session
      ..config(7)
      ..startRound();
    await until(() => room.received.length == 2);
    expect(room.received[0], {'op': 'CONFIG', 'series': 7});
    expect(room.received[1], {'op': 'START'});
  });

  test('my own mold fills from my claims; rivals only show progress', () async {
    await until(() => room.sockets.isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    room
      ..send({'op': 'WELCOME', 'you': 'u1', 'serverNow': now})
      ..send(_lobby('round'))
      ..send(_roundStart(now));
    await until(() => session.mold != null);
    expect(session.racing, isTrue);
    expect(session.total, 7);
    expect(session.progress.keys, ['u1', 'u2', 'u3']);

    session.submit('CAT');
    await until(() => room.received.isNotEmpty);
    expect(room.received.single, {'op': 'SUBMIT', 'word': 'CAT', 'seq': 1});
    room
      ..send({
        'op': 'WORD_RESULT',
        'seq': 1,
        'word': 'TOE',
        'result': 'claimed',
        'slot': 2,
        'auto': [],
        'pickup': 'hammer',
      })
      ..send({'op': 'WORD_RESULT', 'seq': 2, 'word': 'TACO', 'result': 'bonus'})
      ..send({'op': 'PROGRESS', 'id': 'u2', 'filled': 6, 'total': 7});
    await until(() => session.progress['u2']?.filled == 6);
    expect(session.mold!.letterAt((x: 2, y: 2)), 'E');
    expect(session.mold!.fillOf((x: 0, y: 0)), CellFill.empty);
    expect(session.myFilled, 3);
    expect(session.bonusWords, 1);
    expect(session.feed.first.text, 'sam is nearly done!');

    room
      ..send({
        'op': 'ROUND_END',
        'reason': 'finished',
        'winner': 'u2',
        'how': 'finished',
        'progress': [
          {'id': 'u1', 'filled': 3, 'total': 7},
          {'id': 'u2', 'filled': 7, 'total': 7},
          {'id': 'u3', 'filled': 0, 'total': 7},
        ],
        'tally': {'u1': 0, 'u2': 1, 'u3': 0},
        'answers': [
          {'slot': 0, 'word': 'CAT'},
          {'slot': 1, 'word': 'COT'},
          {'slot': 2, 'word': 'TOE'},
        ],
        'next': {'round': 2, 'suddenDeath': false, 'players': ['u1', 'u2', 'u3']},
        'standingsEndsAt': now + 10000,
      })
      ..send(_lobby('standings'));
    await until(() => session.phase == 'standings');
    expect(session.standings!.winner, 'u2');
    expect(session.standings!.next!.round, 2);
    expect(session.tally['u2'], 1);
    expect(session.standingsOrder.first, 'u2');
    expect(session.mold!.letterAt((x: 0, y: 1)), 'O', reason: 'missed words are shown');
    expect(session.mold!.fillOf((x: 0, y: 1)), CellFill.revealed);
  });

  test('sudden death leaves the others watching, and the series ends on a podium', () async {
    await until(() => room.sockets.isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    room
      ..send({'op': 'WELCOME', 'you': 'u1', 'serverNow': now})
      ..send(_lobby('round'))
      ..send(_roundStart(now, sudden: true, racers: ['u2', 'u3']));
    await until(() => session.round != null);
    expect(session.racing, isFalse);
    expect(session.round!.suddenDeath, isTrue);

    room
      ..send({
        'op': 'SERIES_END',
        'winner': 'u3',
        'early': false,
        'forfeit': false,
        'rounds': 4,
        'podium': [
          {'id': 'u3', 'username': 'Kit', 'wins': 2, 'place': 1},
          {'id': 'u2', 'username': 'sam', 'wins': 1, 'place': 2},
          {'id': 'u1', 'username': 'Ada', 'wins': 1, 'place': 2},
        ],
        'xp': {
          'u1': {
            'xp': 25,
            'level': 9,
            'levelUps': 0,
            'rewards': {'hammer': 0},
            'scrapHammers': 1,
            'pickups': {'hammer': 1},
          },
        },
      })
      ..send(_lobby('results'));
    await until(() => session.seriesEnd != null && session.phase == 'results');
    final end = session.seriesEnd!;
    expect(end.podium.map((p) => p.place), [1, 2, 2]);
    expect(end.xp['u1']!.pickups, {'hammer': 1});
    expect(end.xp['u1']!.scrapHammers, 1);
  });

  test('a rejoin snapshot restores my mold, progress and the tally', () async {
    await until(() => room.sockets.isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    room.send({
      'op': 'SNAPSHOT',
      'lobby': _lobby('round'),
      'round': {
        ..._roundStart(now - 20000),
        'serverNow': now,
        'tally': {'u1': 1, 'u2': 0, 'u3': 0},
        'mine': {
          'claims': [
            {'slot': 0, 'word': 'CAT'},
          ],
          'auto': [],
        },
        'progress': [
          {'id': 'u1', 'filled': 3, 'total': 7},
          {'id': 'u2', 'filled': 5, 'total': 7},
        ],
      },
    });
    await until(() => session.mold != null);
    expect(session.mold!.letterAt((x: 1, y: 0)), 'A');
    expect(session.progress['u2']!.filled, 5);
    expect(session.tally['u1'], 1);
    expect(session.countdownLeft, Duration.zero);
  });

  test('back during the standings, my mold shows that round\'s missed words', () async {
    await until(() => room.sockets.isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    room
      ..send({'op': 'WELCOME', 'you': 'u1', 'serverNow': now})
      ..send(_lobby('round'))
      ..send(_roundStart(now));
    await until(() => session.mold != null);
    room.send({
      'op': 'SNAPSHOT',
      'lobby': _lobby('standings'),
      'standings': {
        'reason': 'timeout',
        'round': 1,
        'winner': 'u2',
        'how': 'timeout',
        'progress': [],
        'tally': {'u2': 1},
        'answers': [
          {'slot': 0, 'word': 'CAT'},
          {'slot': 1, 'word': 'COT'},
          {'slot': 2, 'word': 'TOE'},
        ],
        'next': {
          'round': 2,
          'suddenDeath': false,
          'players': ['u1', 'u2', 'u3'],
        },
        'standingsEndsAt': now + 5000,
      },
    });
    await until(() => session.standings != null);
    expect(session.mold!.letterAt((x: 0, y: 1)), 'O');
    expect(session.standings!.round, 1);
  });
}
