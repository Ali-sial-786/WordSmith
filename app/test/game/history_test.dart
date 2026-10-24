import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/history.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/board.dart';
import 'package:wordsmith/game/coop_session.dart';
import 'package:wordsmith/game/history_records.dart';
import 'package:wordsmith/net/room_client.dart';

import '../fixtures/puzzles.dart';
import '../fixtures/vs_review.dart';

PlayRecord _solo(int at, {String? id}) => PlayRecord(
  id: id ?? 'campaign-c-0001-$at',
  kind: PlayKind.campaign,
  at: at,
  title: 'Tin',
  subtitle: 'Puzzle 1 of 12',
  boards: [
    PlayedBoard.fromBoard(Board(tearPuzzle(), foundSlots: [0, 2], autoSlots: [1], bonusFound: ['ART'])),
  ],
);

void main() {
  test('a board keeps its puzzle and what became of each word through JSON', () {
    final board = Board(tearPuzzle(), foundSlots: [0], revealed: [(x: 3, y: 1)], bonusFound: ['ART', 'TEA']);
    final played = PlayedBoard.fromBoard(board, melted: 2);
    final back = PlayedBoard.fromJson(jsonDecode(jsonEncode(played.toJson())) as Map<String, dynamic>);
    expect([for (final s in back.puzzle.slots) s.word], ['TEAR', 'EAT', 'RATE']);
    expect(back.puzzle.letterAt[(x: 3, y: 3)], 'E');
    expect(back.found, {0});
    expect([for (final s in back.missed) s.word], ['EAT', 'RATE']);
    expect(back.revealed, [(x: 3, y: 1)]);
    expect(back.bonus, ['ART', 'TEA']);
    expect(back.melted, 2);
    expect(back.complete, isFalse);
  });

  test('new entries go first, the same id replaces, and only the latest 150 are kept', () {
    var list = <PlayRecord>[];
    for (var i = 0; i < historyLimit + 5; i++) {
      list = withRecord(list, _solo(i));
    }
    expect(list, hasLength(historyLimit));
    expect(list.first.at, historyLimit + 4);
    expect(list.last.at, 5);
    list = withRecord(
      list,
      PlayRecord(
        id: list[3].id,
        kind: PlayKind.campaign,
        at: list[3].at,
        title: 'Tin',
        subtitle: 'again',
        result: {'xp': 12},
      ),
    );
    expect(list, hasLength(historyLimit));
    expect(list[3].subtitle, 'again');
    expect(list[3].get<int>('xp'), 12);
  });

  test('the store keeps the history and skips an entry it cannot read', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.open();
    await store.saveHistory([_solo(2), _solo(1)]);
    expect([for (final r in store.loadHistory()) r.at], [2, 1]);
    final raw = jsonDecode((await SharedPreferences.getInstance()).getString('history.v1')!) as List;
    SharedPreferences.setMockInitialValues({
      'history.v1': jsonEncode([
        raw[0],
        {'id': 'broken'},
        raw[1],
      ]),
    });
    final again = await Store.open();
    expect([for (final r in again.loadHistory()) r.at], [2, 1]);
    await again.clearAll();
    expect(again.loadHistory(), isEmpty);
  });

  test('a co-op round keeps who forged what, the team missed words and bonus words', () {
    final s = CoopSession(
      client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't'),
      me: 'u1',
    );
    addTearDown(s.dispose);
    s.lobby = reviewLobby(players: 2, phase: 'results');
    final start = RoundStart.fromJson({
      'round': 1,
      'heat': 3,
      'startsAt': 1000,
      'endsAt': 91000,
      'serverNow': 1000,
      'letters': 'STONEA',
      'cols': 5,
      'rows': 5,
      'slots': reviewSlots,
      'pickups': [],
    });
    s
      ..round = start
      ..mold = (RemoteMold(start, () => s.lobby!)
        ..claim(0, 'STONE', 'u1')
        ..claim(3, 'TONES', 'u2')
        ..claim(4, 'NET', null));
    s.bonusWords
      ..add(('NOTE', 'u2'))
      ..add(('ONE', 'u1'));
    final end = RoundEnd.fromJson({
      'reason': 'timeout',
      'teamScore': 112,
      'filled': 13,
      'total': 16,
      'stars': 1,
      'players': [
        {'id': 'u1', 'username': 'Ada', 'points': 50, 'words': 1, 'longest': 'STONE'},
        {'id': 'u2', 'username': 'sam', 'points': 62, 'words': 1, 'longest': 'TONES', 'bonus': 1},
      ],
      'mvp': 'u2',
      'answers': [
        for (final (i, w) in reviewWords.indexed) {'slot': i, 'word': w},
      ],
      'xp': {
        'u1': {'xp': 40, 'level': 5, 'levelUps': 0, 'rewards': {}},
      },
    });
    final record = coopRecord(s, end, at: 5000)!;
    expect(record.id, 'coop-V5X7KQ-1000');
    expect(record.kind, PlayKind.coop);
    expect(record.subtitle, 'With 1 smith');
    expect(record.get<int>('xp'), 40);
    expect(record.get<String>('mvp'), 'u2');
    expect(record.player('u2')?.username, 'sam');
    final board = record.boards.single;
    expect(board.owners, {0: 'u1', 3: 'u2'});
    expect(board.auto, {4});
    expect([for (final s in board.missed) s.word], ['SEAT', 'EATS']);
    expect(board.bonus, ['NOTE', 'ONE']);
    expect(record.result['scrap'], ['ONE'], reason: 'the bonus words I found myself');
    // And it reads back the same.
    final back = PlayRecord.fromJson(jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>);
    expect(back.boards.single.owners, {0: 'u1', 3: 'u2'});
    expect(back.result['points'], {'u1': 50, 'u2': 62});
  });

  test('a Versus series keeps the whole SERIES_END and my place', () {
    final s = reviewSession();
    addTearDown(s.dispose);
    final series = classicSeries();
    final record = vsRecord(s, series, at: 9000)!;
    expect(record.kind, PlayKind.vs);
    expect(record.subtitle, 'Against 3 smiths');
    expect(record.get<String>('winner'), 'u1');
    expect(record.get<int>('place'), 1);
    expect(record.series, same(series.json));
    final back = PlayRecord.fromJson(jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>);
    expect(SeriesEnd.fromJson(back.series!).history, hasLength(series.history.length));
    expect([for (final p in back.players) p.username], ['Ada', 'sam', 'Kit', 'Bo']);
  });
}
