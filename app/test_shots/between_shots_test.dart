// Renders the Forge Hall's leaderboard, the word history, the Forged! card's
// Scrap Bin words, the Versus standings with the ready button and the
// victory popup to PNGs with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots/between_shots_test.dart --update-goldens
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/auth/auth_service.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/history.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/board.dart';
import 'package:wordsmith/features/vs/victory_popup.dart';
import 'package:wordsmith/features/vs/vs_results_view.dart';
import 'package:wordsmith/features/vs/vs_standings_view.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/history_records.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/anvil/anvil_ring.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/forge_background.dart';

import '../test/fixtures/fake_backend.dart';
import '../test/fixtures/puzzles.dart';
import '../test/fixtures/vs_review.dart';
import 'shot_fonts.dart';

final _now = DateTime.now();
int _ago(Duration d) => _now.subtract(d).millisecondsSinceEpoch;

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

/// The whole app at [location], signed in when [server] is given.
Future<GoRouter> _app(
  WidgetTester tester,
  String location, {
  FakeServer? server,
  List<PlayRecord> history = const [],
  Campaign? campaign,
}) async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'uid-ali', 'totalXp': 2600, 'campaignStage': 40}),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
    'history.v1': jsonEncode([for (final r in history) r.toJson()]),
  });
  final store = await Store.open();
  final auth = FakeAuth(
    signedIn: server == null ? null : const AuthUser(uid: 'uid-ali', email: 'ali@example.com'),
  );
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(
        campaign ?? await tester.runAsync(Campaign.load) ?? (throw StateError('no campaign')),
      ),
      if (server != null) ...[
        authServiceProvider.overrideWithValue(auth),
        apiClientProvider.overrideWithValue(server.client(auth)),
      ],
    ],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(initialLocation: location, routes: appRouter.configuration.routes);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(router: router),
    ),
  );
  await _wait(tester);
  return router;
}

/// Just [child], on the hall's background.
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

Future<void> _swipe(WidgetTester tester, String word) async {
  Offset centerOf(String letter) =>
      tester.getCenter(find.descendant(of: find.byType(AnvilRing), matching: find.text(letter)));
  final gesture = await tester.startGesture(centerOf(word[0]));
  for (final letter in word.substring(1).split('')) {
    await gesture.moveTo(centerOf(letter));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 50));
}

List<PlayRecord> _history(Campaign campaign) {
  final c5 = campaign.puzzle(5);
  final c9 = campaign.puzzle(9);
  final vs = reviewSession();
  return [
    PlayRecord(
      id: 'campaign-9',
      kind: PlayKind.campaign,
      at: _ago(const Duration(minutes: 8)),
      title: campaign.chapterFor(9).name,
      subtitle: 'Puzzle 9',
      boards: [
        PlayedBoard.fromBoard(
          Board(c9, foundSlots: [for (final s in c9.slots) s.index], bonusFound: c9.bonus.take(2).toList()),
        ),
      ],
    ),
    vsRecord(vs, classicSeries(), at: _ago(const Duration(hours: 3)))!,
    PlayRecord(
      id: 'campaign-5',
      kind: PlayKind.campaign,
      at: _ago(const Duration(days: 1, hours: 2)),
      title: campaign.chapterFor(5).name,
      subtitle: 'Puzzle 5',
      boards: [
        PlayedBoard.fromBoard(
          Board(c5, foundSlots: [for (final s in c5.slots) s.index], bonusFound: c5.bonus.take(3).toList()),
        ),
      ],
    ),
  ];
}

RoomLobby _lobby(String phase, {Set<String> ready = const {}}) => RoomLobby.fromJson({
  'code': 'V5X7KQ',
  'mode': 'vs',
  'phase': phase,
  'hostId': 'u1',
  'heat': 3,
  'series': 5,
  'players': [
    for (var i = 1; i <= 4; i++)
      {
        'id': 'u$i',
        'username': reviewNames[i - 1],
        'avatar': 'avatar_${(i * 3 % 16 + 1).toString().padLeft(2, '0')}',
        'level': 3 * i + 2,
        'color': i - 1,
        'ready': ready.contains('u$i'),
        'connected': true,
      },
  ],
});

void main() {
  setUpAll(loadShotFonts);

  testWidgets('hall leaderboard', (tester) async {
    final server = FakeServer()
      ..username = 'Ali_Smith'
      ..avatar = 'avatar_03'
      ..totalXp = 2600;
    server.friends.addAll([
      {'id': 'uid-sam', 'username': 'sam', 'avatar': 'avatar_05', 'level': 12, 'rank': 'Journeyman'},
      {'id': 'uid-kit', 'username': 'Kit', 'avatar': 'avatar_09', 'level': 7, 'rank': 'Apprentice'},
      {'id': 'uid-wren', 'username': 'wren_99', 'avatar': 'avatar_12', 'level': 21, 'rank': 'Master'},
    ]);
    await _app(tester, '/', server: server);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('hall-leaderboard')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
    await _wait(tester);
    await _shot('hall_leaderboard');
    await tester.pumpWidget(const SizedBox());
  });

  for (final tab in ['game', 'scrap']) {
    testWidgets('word history $tab', (tester) async {
      final campaign = (await tester.runAsync(Campaign.load))!;
      await _app(tester, '/words', history: _history(campaign), campaign: campaign);
      if (tab == 'scrap') {
        await tester.tap(find.textContaining('Scrap Bin ('));
        await _wait(tester);
      }
      await _shot('words_$tab');
    });
  }

  testWidgets('forged scrap words', (tester) async {
    await _app(
      tester,
      '/play/1',
      campaign: Campaign.fromJson({
        'version': 1,
        'chapters': [
          {'id': 'tin', 'name': 'Tin', 'first': 1, 'count': 12},
        ],
        'puzzles': [tearJson()],
      }),
    );
    await _shot('puzzle_tools');
    for (final w in ['ART', 'TEA', 'EAT', 'TEAR', 'RATE']) {
      await _swipe(tester, w);
      await tester.pump(const Duration(milliseconds: 600));
    }
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await _wait(tester);
    await _shot('forged_scrap');
  });

  testWidgets('vs standings ready', (tester) async {
    final series = classicSeries();
    final start = RoundStart.fromJson({
      'round': 2,
      'heat': 3,
      'startsAt': 0,
      'endsAt': _now.millisecondsSinceEpoch + 90000,
      'serverNow': _now.millisecondsSinceEpoch,
      'letters': 'STONEA',
      'cols': 5,
      'rows': 6,
      'slots': reviewSlots,
      'pickups': [],
      'series': 5,
      'regular': 5,
      'suddenDeath': false,
      'players': ['u1', 'u2', 'u3', 'u4'],
      'tally': {'u1': 1, 'u2': 0, 'u3': 0, 'u4': 0},
    });
    final s = VsSession(
      client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'),
      me: 'u1',
    )..lobby = _lobby('standings', ready: {'u2', 'u4'});
    addTearDown(s.dispose);
    final end = VsRoundEnd.fromJson({
      ...reviewRound(
        2,
        winner: 'u3',
        molds: {
          'u1': [0, 1, 3],
          'u2': [4],
          'u3': [0, 1, 2, 3, 4],
          'u4': [2],
        },
      ),
      'tally': {'u1': 1, 'u2': 0, 'u3': 1, 'u4': 0},
      'next': {
        'round': 3,
        'suddenDeath': false,
        'players': ['u1', 'u2', 'u3', 'u4'],
      },
      'standingsEndsAt': _now.millisecondsSinceEpoch + 24000,
    });
    s
      ..round = start
      ..standings = end
      ..tally = end.tally
      ..mold = RemoteMold(start, () => s.lobby!);
    for (final slot in [0, 1, 3]) {
      s.mold!.claim(slot, reviewWords[slot], 'u1');
    }
    s.scrapWords.addAll(['NOTE', 'TOE', 'EAST']);
    expect(series.history, isNotEmpty);
    await _view(tester, VsStandingsView(session: s, cues: MoldCues(), onLeave: () {}));
    await tester.pump(const Duration(seconds: 7));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ready-next')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
    await _wait(tester);
    await _shot('vs_standings_ready');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('victory popup', (tester) async {
    final s = VsSession(
      client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'),
      me: 'u1',
    )..lobby = _lobby('results');
    addTearDown(s.dispose);
    s.seriesEnd = classicSeries();
    await _view(tester, VsResultsView(session: s, onLeave: () {}));
    final context = tester.element(find.byType(VsResultsView));
    showVictoryPopup(context, title: 'YOU WON!', line: 'Won the series 2–1', reducedMotion: true);
    await _wait(tester);
    await _shot('victory_popup');
    await tester.pumpWidget(const SizedBox());
  });
}
