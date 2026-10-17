import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/board.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/ui/anvil/anvil_ring.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/theme/palette.dart';

import '../fixtures/puzzles.dart';

Campaign _campaign() => Campaign.fromJson({
  'version': 1,
  'chapters': [
    {'id': 'tin', 'name': 'Tin', 'first': 1, 'count': 2},
  ],
  'puzzles': [tearJson(), tearJson()..['id'] = 'c-0002'],
});

Future<Store> _pumpApp(WidgetTester tester, String location) async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'abc'}),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  final container = ProviderContainer(
    overrides: [storeProvider.overrideWithValue(store), campaignProvider.overrideWithValue(_campaign())],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: location, routes: appRouter.configuration.routes),
      ),
    ),
  );
  // The heated word's countdown never settles: pump a moment instead.
  await tester.pump(const Duration(milliseconds: 500));
  return store;
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

void main() {
  testWidgets('the Crucible heats a word, and forging it saves it', (tester) async {
    final store = await _pumpApp(tester, '/crucible');
    expect(find.text('The Crucible'), findsOneWidget);
    expect(find.textContaining('Heated word:'), findsOneWidget);
    expect(find.byType(HeatOverlay), findsOneWidget);
    expect(find.text('Saved 0'), findsOneWidget);

    // The shortest word heats first.
    await _swipe(tester, 'EAT');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Saved 1'), findsOneWidget);
    expect(find.textContaining('Heated word:'), findsOneWidget);
    expect(store.loadSurvivalQueue(), isEmpty, reason: 'the run is still going');

    // Leaving ends the run and queues it for the server.
    await tester.tap(find.byTooltip('Leave'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Leave'));
    await tester.pump(const Duration(milliseconds: 500));
    final run = store.loadSurvivalQueue().single;
    expect(((run['puzzles'] as List).single as Map)['foundWords'], ['EAT']);
    expect(run['saved'], 1);
  });

  testWidgets('a melting word plays out and leaves scorched cells', (tester) async {
    final puzzle = tearPuzzle();
    final board = BoardMold(Board(puzzle));
    final cells = puzzle.slotByWord['EAT']!.cells;
    var left = 9000;
    Widget grid({MeltView? melt}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 360,
          child: MoldGrid(
            mold: board,
            metal: MetalStyle.forChapter('tin'),
            cues: MoldCues(),
            heat: HeatView(cells: cells, remainingMs: () => left, durationMs: 20000),
            melt: melt,
          ),
        ),
      ),
    );
    await tester.pumpWidget(grid());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(HeatOverlay), findsOneWidget);
    left = 0;
    await tester.pumpWidget(grid(melt: MeltView(cells: cells, id: 1)));
    expect(find.byType(HeatOverlay), findsNothing);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 220));
    }
    expect(find.byType(MeltOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
