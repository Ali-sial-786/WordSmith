// Renders Team Versus with the real fonts: the lobby, a round, the round's
// card and the standings, and the results.
// Not part of the suite: flutter test test_shots/team_shots_test.dart --update-goldens
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

const _names = ['Ada', 'sam', 'Kit', 'Bo'];
const _teams = {'u1': 0, 'u2': 1, 'u3': 0, 'u4': 1};

RoomLobby _lobby(String phase, {int players = 4, String rule = 'combined'}) => RoomLobby.fromJson({
  'code': 'T5X7KQ',
  'mode': 'team',
  'phase': phase,
  'hostId': 'u1',
  'heat': 2,
  'series': 5,
  'rule': rule,
  'players': [
    for (var i = 1; i <= players; i++)
      {
        'id': 'u$i',
        'username': _names[i - 1],
        'avatar': 'avatar_${(i * 3 % 16 + 1).toString().padLeft(2, '0')}',
        'level': 3 * i + 2,
        'color': i - 1,
        'ready': i != 4,
        'connected': true,
        'team': _teams['u$i'],
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
  'round': 2,
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
  'regular': 2,
  'suddenDeath': false,
  'players': ['u1', 'u2', 'u3', 'u4'],
  'tally': {'u1': 1, 'u3': 1, 'u2': 0, 'u4': 0},
  'teams': _teams,
  'teamTally': [1, 0],
  'rule': 'combined',
});

VsRoundEnd _end() => VsRoundEnd.fromJson({
  'round': 2,
  'reason': 'timeout',
  'winner': null,
  'how': 'timeout',
  'team': 1,
  'teamScores': [19, 23],
  'teamTally': [1, 1],
  'teams': _teams,
  'rule': 'combined',
  'progress': [
    {'id': 'u1', 'filled': 11, 'total': 16},
    {'id': 'u2', 'filled': 13, 'total': 16},
    {'id': 'u3', 'filled': 8, 'total': 16},
    {'id': 'u4', 'filled': 10, 'total': 16},
  ],
  'molds': {
    'u1': [0, 1, 3],
    'u2': [0, 2, 4],
    'u3': [0, 3],
    'u4': [1, 2],
  },
  'tally': {'u1': 1, 'u3': 1, 'u2': 1, 'u4': 1},
  'answers': [
    for (final (i, w) in _words.indexed) {'slot': i, 'word': w},
  ],
  'next': {
    'round': 3,
    'suddenDeath': false,
    'players': ['u1', 'u2', 'u3', 'u4'],
  },
  'standingsEndsAt': DateTime.now().millisecondsSinceEpoch + 8000,
});

SeriesEnd _seriesEnd() => SeriesEnd.fromJson({
  'winner': null,
  'team': 0,
  'rule': 'combined',
  'teamTally': [3, 1],
  'early': false,
  'forfeit': false,
  'rounds': 4,
  'podium': [
    for (final id in ['u1', 'u3', 'u2', 'u4'])
      {
        'id': id,
        'username': _names[int.parse(id.substring(1)) - 1],
        'wins': _teams[id] == 0 ? 3 : 1,
        'place': _teams[id] == 0 ? 1 : 2,
        'team': _teams[id],
      },
  ],
  'history': [],
  'xp': {
    'u1': {
      'xp': 96,
      'level': 6,
      'levelUps': 1,
      'rewards': {'hammer': 1},
      'scrapHammers': 0,
      'heatBonus': 16,
      'tiersAbove': 0,
    },
  },
});

VsSession _session(RoomLobby lobby) {
  final s = VsSession(
    client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'T5X7KQ', token: () async => 't'),
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

  testWidgets('team lobby', (tester) async {
    await _shot(tester, 'team_lobby', () => LobbyView(session: _session(_lobby('lobby', players: 3)), onLeave: () {}));
  });

  testWidgets('team round', (tester) async {
    final start = _start();
    await _shot(tester, 'team_round', () {
      final s = _session(_lobby('round'))
        ..round = start
        ..mold = RemoteMold(start, () => _lobby('round'))
        ..tally = start.tally
        ..teamTally = start.teamTally!
        ..progress = {
          'u1': RacerProgress('u1', 5, 16),
          'u2': RacerProgress('u2', 9, 16),
          'u3': RacerProgress('u3', 7, 16),
          'u4': RacerProgress('u4', 4, 16),
        };
      s.mold!.claim(0, 'STONE', 'u1');
      return VsRoundView(session: s, cues: MoldCues(), onLeave: () {});
    });
  });

  for (final (name, wait) in [('team_standings_card', 1500), ('team_standings', 7000)]) {
    testWidgets(name, (tester) async {
      final start = _start();
      final end = _end();
      await _shot(tester, name, waitMs: wait, () {
        final s = _session(_lobby('standings'))
          ..round = start
          ..mold = RemoteMold(start, () => _lobby('standings'))
          ..standings = end
          ..tally = end.tally
          ..teamTally = end.teamTally!;
        s.mold!.claim(0, 'STONE', 'u1');
        return VsStandingsView(session: s, cues: MoldCues(), onLeave: () {});
      });
    });
  }

  testWidgets('team results', (tester) async {
    await _shot(tester, 'team_results', () {
      final s = _session(_lobby('results'))..seriesEnd = _seriesEnd();
      return VsResultsView(session: s, onLeave: () {});
    });
  });
}
