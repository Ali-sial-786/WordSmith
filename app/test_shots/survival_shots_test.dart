// Renders Survival's screens to PNGs with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots/survival_shots_test.dart --update-goldens
import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/board.dart';
import 'package:wordsmith/features/coop/lobby_view.dart';
import 'package:wordsmith/features/coop/round_view.dart';
import 'package:wordsmith/game/coop_session.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/effects/sparks.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/theme/palette.dart';
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/forge_background.dart';

const _names = ['Ada', 'sam', 'Kit', 'Bo'];

Future<void> _font(String family, Future<ByteData> data) async {
  final loader = FontLoader(family)..addFont(data);
  await loader.load();
}

RoomLobby _lobby(String phase) => RoomLobby.fromJson({
  'code': 'K7Q2AB',
  'mode': 'coop',
  'phase': phase,
  'hostId': 'u1',
  'heat': 3,
  'variant': 'survival',
  'players': [
    for (var i = 1; i <= 3; i++)
      {
        'id': 'u$i',
        'username': _names[i - 1],
        'avatar': 'avatar_0${i + 2}',
        'level': 5 + i,
        'color': i - 1,
        'ready': i != 2,
        'connected': true,
      },
  ],
});

Future<Store> _store({bool reducedMotion = true}) async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({
      'userId': 'abc',
      'totalXp': 900,
      'campaignStage': 12,
      'hints': {'hammer': 3},
    }),
    'settings.v1': jsonEncode({'reducedMotion': reducedMotion, 'haptics': false}),
  });
  return Store.open();
}

Future<void> _frame(WidgetTester tester, Store store, Widget child) async {
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
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(() async {
    await _font('Cinzel', rootBundle.load('assets/fonts/Cinzel-Variable.ttf'));
    await _font('RobotoSlab', rootBundle.load('assets/fonts/RobotoSlab-Variable.ttf'));
    await _font('NunitoSans', rootBundle.load('assets/fonts/NunitoSans-Variable.ttf'));
    await _font('VollkornSC', rootBundle.load('assets/fonts/VollkornSC-Bold.ttf'));
    await _font('Arvo', rootBundle.load('assets/fonts/Arvo-Bold.ttf'));
    final icons = File('/opt/sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
        .readAsBytesSync();
    await _font('MaterialIcons', Future.value(ByteData.view(icons.buffer)));
  });

  testWidgets('crucible', (tester) async {
    final store = await _store();
    final campaign = (await tester.runAsync(Campaign.load))!;
    final container = ProviderContainer(
      overrides: [storeProvider.overrideWithValue(store), campaignProvider.overrideWithValue(campaign)],
    );
    addTearDown(container.dispose);
    await tester.binding.setSurfaceSize(const Size(412, 892));
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: WordsmithApp(
          router: GoRouter(initialLocation: '/crucible', routes: appRouter.configuration.routes),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 500));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/crucible.png'));
  });

  testWidgets('coop survival lobby', (tester) async {
    final store = await _store();
    final s = CoopSession(
      client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't'),
      me: 'u1',
    )..lobby = _lobby('lobby');
    await _frame(tester, store, LobbyView(session: s, onLeave: () {}));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/survival_lobby.png'));
  });

  testWidgets('coop survival round, nearly melting', (tester) async {
    final store = await _store();
    final now = DateTime.now().millisecondsSinceEpoch;
    final lobby = _lobby('round');
    final start = RoundStart.fromJson({
      'round': 2,
      'heat': 3,
      'startsAt': 0,
      'endsAt': now + 600000,
      'serverNow': now,
      'letters': 'STONEA',
      'cols': 5,
      'rows': 5,
      'variant': 'survival',
      'slots': [
        {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 5},
        {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 4},
        {'slot': 2, 'x': 4, 'y': 0, 'd': 'd', 'len': 5},
        {'slot': 3, 'x': 0, 'y': 3, 'd': 'a', 'len': 3},
        {'slot': 4, 'x': 2, 'y': 2, 'd': 'a', 'len': 3},
      ],
      'pickups': [],
    });
    final s =
        CoopSession(
            client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't'),
            me: 'u1',
          )
          ..lobby = lobby
          ..round = start
          ..mold = RemoteMold(start, () => lobby)
          ..scores = {'u1': 50, 'u2': 30, 'u3': 0}
          ..saved = 3
          ..heated = HeatedSlot(slot: 2, startsAt: now - 15000, deadline: now + 4500, durationMs: 19500, saved: 3);
    s.mold!.claim(0, 'STONE', 'u1');
    s.mold!.claim(1, 'SEAT', 'u2');
    await _frame(tester, store, RoundView(session: s, cues: MoldCues(), onLeave: () {}));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/survival_round.png'));
  });

  for (final (i, ms) in [(1, 300), (2, 900), (3, 1300), (4, 1700), (5, 2500)].indexed) {
    testWidgets('melt frame ${i + 1}', (tester) async {
      final store = await _store(reducedMotion: false);
      final puzzle = (await tester.runAsync(Campaign.load))!.puzzle(40);
      final board = Board(puzzle);
      final slots = [...puzzle.slots]..sort((a, b) => b.length - a.length);
      board.submit(slots[1].word);
      final heated = slots.firstWhere((s) => s.cells.every((c) => !board.isFilled(c)) || s == slots.last);
      await _frame(
        tester,
        store,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 80, 16, 200),
          child: MoldGrid(
            mold: BoardMold(board),
            metal: MetalStyle.forChapter('steel'),
            cues: MoldCues(),
            melt: MeltView(
              cells: [
                for (final c in heated.cells)
                  if (!board.isFilled(c)) c,
              ],
              id: 1,
            ),
          ),
        ),
      );
      await tester.pump(Duration(milliseconds: ms.$2));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/melt_${ms.$1}.png'));
    });
  }

  testWidgets('hammer strike frames', (tester) async {
    final store = await _store(reducedMotion: false);
    final puzzle = (await tester.runAsync(Campaign.load))!.puzzle(40);
    final board = Board(puzzle);
    final cues = MoldCues();
    late StateSetter rebuild;
    await _frame(
      tester,
      store,
      SparkField(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 80, 16, 200),
          child: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return MoldGrid(mold: BoardMold(board), metal: MetalStyle.forChapter('steel'), cues: cues);
            },
          ),
        ),
      ),
    );
    await tester.runAsync(() => HammerStrike.precache(tester.element(find.byType(MoldGrid))));
    final target = board.hammerTarget(Random(2))!;
    rebuild(() {
      board.reveal([target]);
      cues.strike(target);
    });
    await tester.pump();
    var at = 0;
    for (final ms in [60, 200, 330, 380, 430, 640]) {
      await tester.pump(Duration(milliseconds: ms - at));
      at = ms;
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/hammer_$ms.png'));
    }
  });

  for (final left in [0.95, 0.7, 0.45, 0.25, 0.1, 0.02]) {
    testWidgets('heat at $left left', (tester) async {
      final store = await _store();
      final puzzle = (await tester.runAsync(Campaign.load))!.puzzle(40);
      final board = Board(puzzle);
      final slots = [...puzzle.slots]..sort((a, b) => b.length - a.length);
      board.submit(slots[1].word);
      final heated = slots.firstWhere((s) => s.cells.every((c) => !board.isFilled(c)) || s == slots.last);
      await _frame(
        tester,
        store,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 80, 16, 200),
          child: MoldGrid(
            mold: BoardMold(board),
            metal: MetalStyle.forChapter('steel'),
            cues: MoldCues(),
            heat: HeatView(cells: heated.cells, remainingMs: () => (20000 * left).round(), durationMs: 20000),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/heat_${(left * 100).round()}.png'));
    });
  }
}
