// Renders Rune Grid's lobby, a round mid-swipe, the standings and the
// results to PNGs with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots/rune_shots_test.dart --update-goldens
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/coop/lobby_view.dart';
import 'package:wordsmith/features/rune/rune_results_view.dart';
import 'package:wordsmith/features/rune/rune_round_view.dart';
import 'package:wordsmith/features/rune/rune_standings_view.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/rune_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/forge_background.dart';

import 'shot_fonts.dart';

const _tiles = ['C', 'A', 'T', 'S', 'O', 'R', 'E', 'D', 'QU', 'I', 'L', 'T', 'N', 'M', 'P', 'H'];
const _names = ['Ada', 'sam', 'Kit_the_Smith', 'Bo'];
const _ids = ['u1', 'u2', 'u3', 'u4'];

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

Future<void> _view(WidgetTester tester, Widget child) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(const Size(412, 892));
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWithValue(store)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: Scaffold(
          body: ForgeBackground(
            image: 'assets/images/bg_hall.webp',
            dim: 0.6,
            fire: 0.0,
            child: SafeArea(child: child),
          ),
        ),
      ),
    ),
  );
  await _wait(tester);
}

RoomLobby _lobby(String phase, {String mode = 'rune'}) => RoomLobby.fromJson({
  'code': 'R5X7KQ',
  'mode': mode,
  'phase': phase,
  'hostId': 'u1',
  'heat': 2,
  'rune': {'size': 4, 'seconds': 120, 'min': 3, 'rounds': 3, 'teamScoring': 'pooled'},
  'players': [
    for (final (i, id) in _ids.indexed)
      {
        'id': id,
        'username': _names[i],
        'avatar': 'avatar_0${i + 1}',
        'level': 4 + i,
        'color': i,
        'ready': i.isEven,
        'connected': true,
        if (mode == 'runeteam') 'team': i % 2,
      },
  ],
});

RuneSession _session(RoomLobby lobby) {
  final s = RuneSession(
    client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'R5X7KQ', token: () async => 't'),
    me: 'u1',
  )..lobby = lobby;
  addTearDown(s.dispose);
  return s;
}

Map<String, Object?> _endJson({bool last = false}) => {
  'game': 'rune',
  'round': 2,
  'size': 4,
  'tiles': _tiles,
  'found': {
    'u1': [
      {'word': 'QUILT', 'points': 6, 'unique': true},
      {'word': 'CRATED', 'points': 8, 'unique': true},
      {'word': 'CAT', 'points': 1, 'unique': false},
      {'word': 'RATE', 'points': 2, 'unique': false},
    ],
    'u2': [
      {'word': 'CAT', 'points': 1, 'unique': false},
      {'word': 'RATE', 'points': 2, 'unique': false},
      {'word': 'TEAR', 'points': 4, 'unique': true},
    ],
    'u3': [
      {'word': 'ORE', 'points': 2, 'unique': true},
    ],
    'u4': <Object>[],
  },
  'points': {'u1': 17, 'u2': 7, 'u3': 2, 'u4': 0},
  'winner': 'u1',
  'words': ['CRATED', 'QUILT', 'CRATE', 'TRADE', 'CATS', 'RATE', 'TEAR', 'DEAR', 'CAT', 'ORE', 'ART', 'RAT', 'EAR'],
  'total': 13,
  'totals': {'u1': 29, 'u2': 18, 'u3': 9, 'u4': 3},
  'next': last ? null : {'round': 3, 'tiebreak': false, 'players': _ids},
  'standingsEndsAt': last ? null : DateTime.now().millisecondsSinceEpoch + 22000,
};

void main() {
  setUpAll(loadShotFonts);

  testWidgets('lobby', (tester) async {
    await _view(
      tester,
      LobbyView(
        session: _session(_lobby('lobby', mode: 'runeteam')),
        onLeave: () {},
      ),
    );
    await _shot('rune_lobby');
  });

  testWidgets('round, mid-swipe', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = _session(_lobby('round'))
      ..grid = RuneRoundStart.fromJson({
        'game': 'rune',
        'round': 2,
        'rounds': 3,
        'players': _ids,
        'size': 4,
        'tiles': _tiles,
        'min': 3,
        'seconds': 120,
        'startsAt': now - 30000,
        'endsAt': now + 84000,
        'serverNow': now,
        'heat': 2,
        'totals': {'u1': 12, 'u2': 11, 'u3': 7, 'u4': 3},
      })
      ..tally = {'u1': 5, 'u2': 7, 'u3': 2, 'u4': 1}
      ..totals = {'u1': 12, 'u2': 11, 'u3': 7, 'u4': 3};
    s.mine.addAll(const [
      RuneWord('QUILT', 'u1', 3),
      RuneWord('CAT', 'u1', 1),
      RuneWord('RATE', 'u1', 2),
      RuneWord('ORE', 'u1', 1),
      RuneWord('TEAR', 'u1', 2),
    ]);
    await _view(tester, RuneRoundView(session: s, onLeave: () {}));
    final board = tester.getRect(find.byKey(const ValueKey('rune-board')));
    Offset at(int i) => board.topLeft + Offset((i % 4 + 0.5) * board.width / 4, (i ~/ 4 + 0.5) * board.width / 4);
    final g = await tester.startGesture(at(0));
    for (final i in [5, 1, 2, 6]) {
      await g.moveTo(at(i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 200));
    await _shot('rune_round');
    await g.up();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('standings', (tester) async {
    final end = RuneRoundEnd.fromJson(_endJson());
    final s = _session(_lobby('standings'))
      ..standings = end
      ..totals = end.totals;
    await _view(tester, RuneStandingsView(session: s, onLeave: () {}));
    await _shot('rune_standings');
  });

  testWidgets('results', (tester) async {
    final s = _session(_lobby('results'))
      ..seriesEnd = SeriesEnd.fromJson({
        'game': 'rune',
        'winner': 'u1',
        'early': false,
        'forfeit': false,
        'rounds': 3,
        'scoring': 'total',
        'history': [],
        'podium': [
          for (final (i, id) in _ids.indexed)
            {
              'id': id,
              'username': _names[i],
              'wins': i == 0 ? 2 : (i == 1 ? 1 : 0),
              'place': i + 1,
              'score': 41 - i * 9,
            },
        ],
        'xp': {
          'u1': {'xp': 55, 'level': 6, 'levelUps': 0, 'rewards': {}, 'heatBonus': 8},
        },
        'rune': {
          'settings': {'size': 4, 'seconds': 120, 'min': 3, 'rounds': 3},
          'history': [
            for (final r in [1, 2, 3]) {..._endJson(), 'round': r},
          ],
          'words': {'u1': 14, 'u2': 11, 'u3': 6, 'u4': 2},
        },
      });
    await _view(tester, RuneResultsView(session: s, onLeave: () {}));
    await _shot('rune_results');
  });
}
