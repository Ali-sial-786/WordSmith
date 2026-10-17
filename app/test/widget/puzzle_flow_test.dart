import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/hints.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/ui/anvil/anvil_ring.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';

import '../fixtures/puzzles.dart';

Campaign _campaign() {
  final second = tearJson()..['id'] = 'c-0002';
  return Campaign.fromJson({
    'version': 1,
    'chapters': [
      {'id': 'tin', 'name': 'Tin', 'first': 1, 'count': 2},
    ],
    'puzzles': [tearJson(), second],
  });
}

Future<ProviderContainer> _pumpApp(WidgetTester tester, String location) async {
  SharedPreferences.setMockInitialValues({
    // 'abc' has no pickups in c-0001 (shared/pickups.md), and reduced
    // motion turns off the endless ember drift so the UI can settle.
    'profile.v1': jsonEncode({'userId': 'abc'}),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(_campaign()),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(initialLocation: location, routes: appRouter.configuration.routes);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _swipe(WidgetTester tester, String word) async {
  Offset centerOf(String letter) => tester.getCenter(
    find.descendant(of: find.byType(AnvilRing), matching: find.text(letter)),
  );
  final gesture = await tester.startGesture(centerOf(word[0]));
  for (final letter in word.substring(1).split('')) {
    await gesture.moveTo(centerOf(letter));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 50));
}

Finder _moldLetter(String letter) =>
    find.descendant(of: find.byType(MoldGrid), matching: find.text(letter));

void main() {
  testWidgets('swiping words fills the mold and forging grants XP', (tester) async {
    final container = await _pumpApp(tester, '/play/1');

    expect(_moldLetter('A'), findsNothing, reason: 'the mold starts empty');

    await _swipe(tester, 'EAT');
    await tester.pumpAndSettle();
    expect(_moldLetter('A'), findsOneWidget);
    expect(_moldLetter('T'), findsOneWidget);

    await _swipe(tester, 'ART');
    await tester.pumpAndSettle();
    expect(container.read(profileProvider).scrapBin, 1, reason: 'bonus word');

    await _swipe(tester, 'TEAR');
    await _swipe(tester, 'RATE');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('FORGED!'), findsOneWidget);
    final profile = container.read(profileProvider);
    expect(profile.totalXp, 11, reason: '10 + 1 bonus word');
    expect(profile.campaignStage, 2);
    expect(container.read(storeProvider).loadSavedPuzzle(), isNull);
    expect(container.read(storeProvider).loadSyncQueue(), hasLength(1));

    await tester.tap(find.text('Next puzzle'));
    await tester.pumpAndSettle();
    expect(find.text('Puzzle 2 of 2'), findsOneWidget);
    expect(find.text('FORGED!'), findsNothing);
  });

  testWidgets('progress is saved mid-puzzle and restored', (tester) async {
    final container = await _pumpApp(tester, '/play/1');
    await _swipe(tester, 'EAT');
    await tester.pumpAndSettle();
    final saved = container.read(storeProvider).loadSavedPuzzle()!;
    expect(saved.stage, 1);
    expect(saved.foundSlots, [1]);
  });

  testWidgets('the Hammer Strike hint reveals a letter and is spent', (tester) async {
    final container = await _pumpApp(tester, '/play/1');
    expect(container.read(profileProvider).hintCount(HintKind.hammer), 3);
    await tester.tap(find.byTooltip('Hammer Strike'));
    await tester.pumpAndSettle();
    expect(container.read(profileProvider).hintCount(HintKind.hammer), 2);
    final revealed = container.read(storeProvider).loadSavedPuzzle()!.revealed;
    expect(revealed, hasLength(1));
  });

  testWidgets('the Forge Hall shows level and the next puzzle', (tester) async {
    await _pumpApp(tester, '/');
    expect(find.text('WORDSMITH'), findsOneWidget);
    expect(find.text('Apprentice'), findsOneWidget);
    expect(find.text('Tin · Puzzle 1 of 2'), findsOneWidget);
  });
}
