// Renders Versus on the total score with the real fonts: the lobby, a round,
// the round's card and the standings, and a podium won on bonus words.
// Not part of the suite: flutter test test_shots/total_shots_test.dart --update-goldens
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/coop/lobby_view.dart';
import 'package:wordsmith/features/vs/vs_results_view.dart';
import 'package:wordsmith/features/vs/vs_round_view.dart';
import 'package:wordsmith/features/vs/vs_standings_view.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/avatar_badge.dart';
import 'package:wordsmith/ui/widgets/forge_background.dart';
import 'package:wordsmith/ui/widgets/forge_frame.dart';
import 'package:wordsmith/ui/widgets/game_icon.dart';

import 'shot_fonts.dart';

const _names = ['Ada', 'sam', 'Kit'];

RoomLobby _lobby(String phase) => RoomLobby.fromJson({
  'code': 'V5X7KQ',
  'mode': 'vs',
  'phase': phase,
  'hostId': 'u1',
  'heat': 2,
  'series': 5,
  'scoring': 'total',
  'players': [
    for (var i = 1; i <= 3; i++)
      {
        'id': 'u$i',
        'username': _names[i - 1],
        'avatar': 'avatar_${(i * 3 % 16 + 1).toString().padLeft(2, '0')}',
        'level': 3 * i + 2,
        'color': i - 1,
        'ready': i != 3,
        'connected': true,
      },
  ],
});

/// The shots' 5×5 mold: STONE, SEAT, EATEN, TON, ONE (16 letters).
final _slots = [
  {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 5},
  {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 4},
  {'slot': 2, 'x': 4, 'y': 0, 'd': 'd', 'len': 5},
  {'slot': 3, 'x': 0, 'y': 3, 'd': 'a', 'len': 3},
  {'slot': 4, 'x': 2, 'y': 2, 'd': 'a', 'len': 3},
];
const _words = ['STONE', 'SEAT', 'EATEN', 'TON', 'ONE'];

RoundStart _start() => RoundStart.fromJson({
  'round': 3,
  'heat': 2,
  'startsAt': 0,
  'endsAt': DateTime.now().millisecondsSinceEpoch + 74000,
  'serverNow': DateTime.now().millisecondsSinceEpoch,
  'letters': 'STONEA',
  'cols': 5,
  'rows': 5,
  'slots': _slots,
  'pickups': [],
  'series': 5,
  'regular': 3,
  'suddenDeath': false,
  'players': ['u1', 'u2', 'u3'],
  'tally': {'u1': 0, 'u2': 2, 'u3': 0},
  'scoring': 'total',
  'scores': {'u1': 27, 'u2': 32, 'u3': 18},
  'bonusTally': {'u1': 4, 'u2': 1, 'u3': 2},
});

VsRoundEnd _end() => VsRoundEnd.fromJson({
  'round': 3,
  'reason': 'finished',
  'winner': 'u2',
  'how': 'finished',
  'progress': [
    {'id': 'u1', 'filled': 13, 'total': 16},
    {'id': 'u2', 'filled': 16, 'total': 16},
    {'id': 'u3', 'filled': 8, 'total': 16},
  ],
  'molds': {
    'u1': [0, 1, 2, 4],
    'u2': [0, 1, 2, 3, 4],
    'u3': [0, 3],
  },
  'tally': {'u1': 0, 'u2': 3, 'u3': 0},
  'answers': [
    for (final (i, w) in _words.indexed) {'slot': i, 'word': w},
  ],
  'next': {
    'round': 4,
    'suddenDeath': false,
    'players': ['u1', 'u2', 'u3'],
  },
  'standingsEndsAt': DateTime.now().millisecondsSinceEpoch + 28000,
  'scoring': 'total',
  'scores': {'u1': 40, 'u2': 48, 'u3': 26},
  'bonusTally': {'u1': 5, 'u2': 1, 'u3': 2},
});

SeriesEnd _seriesEnd() => SeriesEnd.fromJson({
  'winner': 'u1',
  'scoring': 'total',
  'early': false,
  'forfeit': false,
  'rounds': 5,
  'podium': [
    {'id': 'u1', 'username': 'Ada', 'wins': 1, 'place': 1, 'score': 71, 'bonus': 7},
    {'id': 'u2', 'username': 'sam', 'wins': 4, 'place': 2, 'score': 71, 'bonus': 3},
    {'id': 'u3', 'username': 'Kit', 'wins': 0, 'place': 3, 'score': 44, 'bonus': 2},
  ],
  'history': [],
  'xp': {
    'u1': {'xp': 80, 'level': 6, 'levelUps': 0, 'rewards': {}, 'scrapHammers': 1, 'heatBonus': 13, 'tiersAbove': 0},
  },
});

VsSession _session(RoomLobby lobby) {
  final s = VsSession(
    client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'),
    me: 'u1',
  )..lobby = lobby;
  addTearDown(s.dispose);
  return s;
}

Widget _app(Store store, Widget child) => ProviderScope(
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
);

class _WarmUp extends StatelessWidget {
  const _WarmUp();

  @override
  Widget build(BuildContext context) => Wrap(
    children: [
      for (final kind in ForgeFrameKind.values) SizedBox(width: 120, height: 70, child: ForgeFrame(kind: kind)),
      for (final icon in ['crown', 'anvil', 'trophy', 'flame', 'turn']) GameIcon(icon),
      for (var i = 1; i <= 16; i++) AvatarBadge(avatar: 'avatar_${i.toString().padLeft(2, '0')}', size: 20),
    ],
  );
}

Future<void> _shot(WidgetTester tester, String name, Widget Function() view, {int waitMs = 0}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(const Size(412, 892));
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(store, const _WarmUp()));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
  await tester.pump();
  await tester.pumpWidget(_app(store, view()));
  await tester.pump();
  for (var at = 0; at < waitMs; at += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pump();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
  await tester.pumpWidget(const SizedBox());
}

void main() {
  setUpAll(loadShotFonts);

  testWidgets('total lobby', (tester) async {
    await _shot(tester, 'total_lobby', () => LobbyView(session: _session(_lobby('lobby')), onLeave: () {}));
  });

  testWidgets('total round', (tester) async {
    final start = _start();
    await _shot(tester, 'total_round', () {
      final s = _session(_lobby('round'))
        ..round = start
        ..mold = RemoteMold(start, () => _lobby('round'))
        ..tally = start.tally
        ..scores = start.scores
        ..bonusTally = start.bonusTally
        ..progress = {
          'u1': RacerProgress('u1', 5, 16),
          'u2': RacerProgress('u2', 9, 16),
          'u3': RacerProgress('u3', 7, 16),
        };
      s.mold!.claim(0, 'STONE', 'u1');
      return VsRoundView(session: s, cues: MoldCues(), onLeave: () {});
    });
  });

  for (final (name, wait) in [('total_standings_card', 1500), ('total_standings', 7000)]) {
    testWidgets(name, (tester) async {
      final start = _start();
      final end = _end();
      await _shot(tester, name, waitMs: wait, () {
        final s = _session(_lobby('standings'))
          ..round = start
          ..mold = RemoteMold(start, () => _lobby('standings'))
          ..standings = end
          ..tally = end.tally
          ..scores = end.scores
          ..bonusTally = end.bonusTally;
        s.mold!.claim(0, 'STONE', 'u1');
        return VsStandingsView(session: s, cues: MoldCues(), onLeave: () {});
      });
    });
  }

  testWidgets('total results', (tester) async {
    await _shot(tester, 'total_results', () {
      final s = _session(_lobby('results'))..seriesEnd = _seriesEnd();
      return VsResultsView(session: s, onLeave: () {});
    });
  });
}
