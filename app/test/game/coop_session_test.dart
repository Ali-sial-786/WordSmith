import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/game/coop_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_model.dart';
import 'package:wordsmith/ui/theme/palette.dart';

/// A local stand-in for a co-op room that records what the client sends.
class _LocalRoom {
  late HttpServer server;
  final paths = <String>[];
  final received = <Map<String, dynamic>>[];
  final sockets = <WebSocket>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      paths.add(req.uri.path);
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

Map<String, Object?> _lobby({String phase = 'lobby', bool samReady = false}) => {
  'op': 'LOBBY',
  'code': 'K7Q2AB',
  'mode': 'coop',
  'phase': phase,
  'hostId': 'u1',
  'heat': 3,
  'players': [
    {'id': 'u1', 'username': 'Ada', 'avatar': 'avatar_02', 'level': 12, 'color': 0, 'ready': true, 'connected': true},
    {'id': 'u2', 'username': 'sam', 'avatar': 'avatar_05', 'level': 4, 'color': 1, 'ready': samReady, 'connected': true},
  ],
};

/// A 3×3 mold: CAT across the top, COT down the left, TOE down the right.
Map<String, Object?> _roundStart(int now) => {
  'op': 'ROUND_START',
  'round': 1,
  'heat': 3,
  'startsAt': now + 3000,
  'endsAt': now + 93000,
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
};

void main() {
  late _LocalRoom room;
  late CoopSession session;

  setUp(() async {
    room = _LocalRoom();
    await room.start();
    final client = RoomClient(baseUrl: room.base, code: 'K7Q2AB', token: () async => 'tok');
    session = CoopSession(client: client, me: 'u1');
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

  test('joins the room, shows the lobby and sends ready and start', () async {
    await until(() => room.sockets.isNotEmpty);
    expect(room.paths.single, '/v1/ws/room/K7Q2AB');
    room
      ..send({'op': 'WELCOME', 'you': 'u1', 'serverNow': DateTime.now().millisecondsSinceEpoch})
      ..send(_lobby());
    await until(() => session.lobby != null);
    expect(session.isHost, isTrue);
    expect(session.phase, 'lobby');
    expect(session.connection, RoomConnection.live);
    expect(session.lobby!.player('u2')!.username, 'sam');

    session
      ..setReady(true)
      ..startRound();
    await until(() => room.received.length == 2);
    expect(room.received[0], {'op': 'READY', 'ready': true});
    expect(room.received[1], {'op': 'START'});
  });

  test('fills the shared mold as teammates forge words, then shows results', () async {
    final effects = <RoomEvent>[];
    session.effects.listen(effects.add);
    await until(() => room.sockets.isNotEmpty);
    // The server's clock is 5 s ahead of ours.
    final now = DateTime.now().millisecondsSinceEpoch + 5000;
    room
      ..send({'op': 'WELCOME', 'you': 'u1', 'serverNow': now})
      ..send(_lobby(phase: 'countdown'))
      ..send(_roundStart(now));
    await until(() => session.mold != null);
    final mold = session.mold!;
    expect(mold.cells, hasLength(7));
    expect(mold.letterAt((x: 1, y: 0)), '', reason: 'letters stay hidden until forged');
    expect(mold.pickupAt((x: 2, y: 2)), 'ember');
    expect(session.countdownLeft.inMilliseconds, inInclusiveRange(2000, 3000));
    expect(session.timeLeft.inSeconds, inInclusiveRange(91, 93));

    session.submit('CAT');
    await until(() => room.received.isNotEmpty);
    expect(room.received.single, {'op': 'SUBMIT', 'word': 'CAT', 'seq': 1});

    room
      ..send({'op': 'WORD_RESULT', 'seq': 1, 'word': 'CAT', 'result': 'claimed', 'points': 30})
      ..send({
        'op': 'CLAIMED',
        'slot': 0,
        'word': 'CAT',
        'by': 'u1',
        'points': 30,
        'scores': {'u1': 30},
        'auto': [],
      })
      // sam forges TOE and picks up the ember; COT still needs its O.
      ..send({
        'op': 'CLAIMED',
        'slot': 2,
        'word': 'TOE',
        'by': 'u2',
        'points': 30,
        'scores': {'u1': 30, 'u2': 30},
        'auto': [],
        'pickup': 'hammer',
      });
    await until(() => session.scores['u2'] == 30);
    expect(mold.letterAt((x: 1, y: 0)), 'A');
    expect(mold.letterAt((x: 2, y: 2)), 'E');
    expect(mold.fillOf((x: 0, y: 0)), CellFill.filled);
    expect(mold.fillOf((x: 0, y: 1)), CellFill.empty);
    expect(mold.ownerColor((x: 1, y: 0)), Palette.players[0]);
    expect(mold.ownerColor((x: 2, y: 2)), Palette.players[1]);
    expect(mold.ownerInitial((x: 2, y: 0)), 'S', reason: "TOE starts at (2,0), so sam's initial goes there");
    expect(mold.pickupAt((x: 2, y: 2)), isNull, reason: 'the ember was picked up');
    expect(session.feed.first.text, 'sam forged TOE  +30');
    expect(effects.whereType<WordResult>().single.result, 'claimed');

    room
      ..send(_lobby(phase: 'results'))
      ..send({
        'op': 'ROUND_END',
        'reason': 'timeout',
        'teamScore': 60,
        'filled': 6,
        'total': 7,
        'stars': 2,
        'players': [
          {'id': 'u1', 'username': 'Ada', 'points': 30, 'words': 1, 'longest': 'CAT', 'bonus': 0},
          {'id': 'u2', 'username': 'sam', 'points': 30, 'words': 1, 'longest': 'TOE', 'bonus': 0},
          // Left mid-round: only the results know the name.
          {'id': 'u3', 'username': 'Kit', 'points': 0, 'words': 0, 'longest': '', 'bonus': 2},
        ],
        'mvp': 'u1',
        'answers': [
          {'slot': 0, 'word': 'CAT'},
          {'slot': 1, 'word': 'COT'},
          {'slot': 2, 'word': 'TOE'},
        ],
        'xp': {
          'u1': {'xp': 85, 'level': 13, 'levelUps': 1, 'rewards': {'hammer': 1}, 'scrapHammers': 1},
        },
      });
    await until(() => session.results != null);
    expect(session.phase, 'results');
    expect(session.results!.completed, isFalse);
    expect(session.results!.xp['u1']!.levelUps, 1);
    expect(session.results!.xp['u1']!.scrapHammers, 1);
    expect(session.nameOf('u3'), 'Kit');
    expect(session.results!.players.last.bonus, 2);
    expect(mold.letterAt((x: 0, y: 1)), 'O', reason: 'missed words are shown after the round');
    expect(mold.fillOf((x: 0, y: 1)), CellFill.revealed);
    expect(effects.last, isA<RoundEnd>());
  });

  test('a snapshot after a reconnect restores the round in progress', () async {
    await until(() => room.sockets.isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    room.send({
      'op': 'SNAPSHOT',
      'lobby': _lobby(phase: 'round'),
      'round': {
        ..._roundStart(now - 10000),
        'serverNow': now,
        'claims': [
          {'slot': 1, 'word': 'COT', 'by': 'u2'},
        ],
        'auto': [],
        'bonus': [],
        'revealed': [
          {'x': 1, 'y': 0, 'letter': 'A'},
        ],
        'scores': {'u2': 30},
      },
    });
    await until(() => session.mold != null);
    final mold = session.mold!;
    expect(session.phase, 'round');
    expect(mold.letterAt((x: 0, y: 2)), 'T');
    expect(mold.fillOf((x: 0, y: 2)), CellFill.filled);
    expect(mold.letterAt((x: 1, y: 0)), 'A');
    expect(mold.fillOf((x: 1, y: 0)), CellFill.revealed);
    expect(mold.fillOf((x: 2, y: 0)), CellFill.empty);
    expect(session.scores, {'u2': 30});
    expect(session.countdownLeft, Duration.zero);
  });

  test('leaving tells the room and stops reconnecting', () async {
    await until(() => room.sockets.isNotEmpty);
    room.send(_lobby());
    await until(() => session.lobby != null);
    await session.leave();
    await until(() => room.received.isNotEmpty);
    expect(room.received.last, {'op': 'LEAVE'});
    await until(() => session.connection == RoomConnection.closed);
    expect(room.sockets, hasLength(1));
  });

  test('a room that closes on us is final', () async {
    await until(() => room.sockets.isNotEmpty);
    await room.sockets.single.close(4004, 'room_closed');
    await until(() => session.connection == RoomConnection.closed);
    expect(session.closeCode, 4004);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(room.sockets, hasLength(1), reason: 'no reconnect after a 4xxx close');
  });

  test('a round that starts before its LOBBY arrives already counts as the countdown', () async {
    await until(() => room.sockets.isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    room
      ..send(_lobby(phase: 'results'))
      ..send(_roundStart(now));
    await until(() => session.round != null);
    expect(session.phase, 'countdown', reason: 'no flash of the lobby between results and the next round');
    room.send(_lobby(phase: 'round'));
    await until(() => session.lobby!.phase == 'round');
    expect(session.phase, 'round');
  });

  test('survival: the heated word, saves, then a melt holds the results back for the animation', () async {
    final effects = <RoomEvent>[];
    session.effects.listen(effects.add);
    await until(() => room.sockets.isNotEmpty);
    final now = DateTime.now().millisecondsSinceEpoch;
    room
      ..send({'op': 'WELCOME', 'you': 'u1', 'serverNow': now})
      ..send({..._lobby(phase: 'countdown'), 'variant': 'survival'})
      ..send({
        ..._roundStart(now),
        'variant': 'survival',
        'heated': {'slot': 1, 'startsAt': now + 3000, 'deadline': now + 24600, 'durationMs': 21600, 'saved': 0},
      });
    await until(() => session.mold != null);
    expect(session.survival, isTrue);
    expect(session.lobby!.survival, isTrue);
    expect(session.heated!.slot, 1);
    expect(session.heatRemainingMs, inInclusiveRange(23000, 24600));

    room.send({
      'op': 'HEATED',
      'slot': 2,
      'startsAt': now + 5000,
      'deadline': now + 26600,
      'durationMs': 20952,
      'saved': 1,
      'serverNow': now + 5000,
    });
    await until(() => session.heated?.slot == 2);
    expect(session.saved, 1);

    room
      ..send({'op': 'MELT', 'slot': 2})
      ..send({
        'op': 'ROUND_END',
        'reason': 'melted',
        'teamScore': 30,
        'filled': 3,
        'total': 7,
        'stars': 0,
        'players': [],
        'mvp': null,
        'answers': [
          {'slot': 2, 'word': 'TOE'},
        ],
        'xp': {},
        'saved': 1,
        'variant': 'survival',
        'melted': {'slot': 2},
      })
      ..send(_lobby(phase: 'results'));
    await until(() => session.results != null && session.phase == 'results');
    expect(session.results!.melted, isTrue);
    expect(session.results!.saved, 1);
    expect(session.heated, isNull);
    expect(session.melt!.slot, 2);
    expect(session.melting, isTrue, reason: 'the round view stays up while it melts');
    expect(effects.whereType<Melted>(), hasLength(1));
  });

  test('the host picks the variant', () async {
    await until(() => room.sockets.isNotEmpty);
    room.send(_lobby());
    await until(() => session.lobby != null);
    expect(session.survival, isFalse);
    session.setVariant('survival');
    await until(() => room.received.isNotEmpty);
    expect(room.received.single, {'op': 'CONFIG', 'variant': 'survival'});
  });
}
