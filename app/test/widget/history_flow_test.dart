import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/history.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/board.dart';
import 'package:wordsmith/features/history/history_screen.dart';
import 'package:wordsmith/features/vs/series_summary.dart';
import 'package:wordsmith/game/history_records.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/ui/anvil/anvil_ring.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';

import '../fixtures/puzzles.dart';
import '../fixtures/vs_review.dart';

Future<(ProviderContainer, GoRouter)> _pumpApp(
  WidgetTester tester,
  String location, {
  List<PlayRecord>? history,
}) async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'abc'}),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
    if (history != null) 'history.v1': jsonEncode([for (final r in history) r.toJson()]),
  });
  final store = await Store.open();
  final second = tearJson()..['id'] = 'c-0002';
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(
        Campaign.fromJson({
          'version': 1,
          'chapters': [
            {'id': 'tin', 'name': 'Tin', 'first': 1, 'count': 2},
          ],
          'puzzles': [tearJson(), second],
        }),
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(initialLocation: location, routes: appRouter.configuration.routes);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  tester.view
    ..physicalSize = const Size(412, 892)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  return (container, router);
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

final _now = DateTime.now();
int _ago(Duration d) => _now.subtract(d).millisecondsSinceEpoch;

void main() {
  testWidgets('a forged puzzle goes into the history, and its board can be looked back at from Profile', (
    tester,
  ) async {
    final (container, router) = await _pumpApp(tester, '/play/1');
    for (final w in ['EAT', 'ART', 'TEAR', 'RATE']) {
      await _swipe(tester, w);
      await tester.pumpAndSettle();
    }
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('FORGED!'), findsOneWidget);

    final history = container.read(historyProvider);
    expect(history, hasLength(1));
    final record = history.single;
    expect(record.kind, PlayKind.campaign);
    expect(record.title, 'Tin');
    expect(record.subtitle, 'Puzzle 1 of 2');
    expect(record.get<int>('stage'), 1);
    expect(record.get<int>('xp'), 11, reason: 'saved again with its XP');
    expect(record.boards.single.complete, isTrue);
    expect(record.boards.single.bonus, ['ART']);
    expect(container.read(storeProvider).loadHistory(), hasLength(1), reason: 'kept on the phone');

    await tester.tap(find.text('Forge Hall'));
    await tester.pumpAndSettle();
    router.go('/profile');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Puzzle history'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('1 puzzle · last: Tin'), findsOneWidget);
    await tester.tap(find.text('Puzzle history'));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Puzzle 1 of 2'), findsOneWidget);
    expect(find.textContaining('3 words · +1 bonus'), findsOneWidget);

    await tester.tap(find.text('Puzzle 1 of 2'));
    await tester.pumpAndSettle();
    expect(find.byType(MoldGrid), findsOneWidget);
    expect(find.text('Words (3)'), findsOneWidget);
    expect(find.text('TEAR'), findsOneWidget);
    expect(find.text('Bonus words (1)'), findsOneWidget);
    expect(find.text('ART'), findsOneWidget);
    expect(find.text('11 XP'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Play it again'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Play it again'));
    await tester.pumpAndSettle();
    expect(find.text('Replay · Puzzle 1 of 2'), findsOneWidget);
  });

  testWidgets('the history groups by day, filters by mode, and looks back at co-op and Versus', (tester) async {
    final board = Board(tearPuzzle(), foundSlots: [0], autoSlots: [], bonusFound: []);
    final vs = reviewSession();
    addTearDown(vs.dispose);
    final history = [
      PlayRecord(
        id: 'coop-1',
        kind: PlayKind.coop,
        at: _ago(const Duration(minutes: 5)),
        title: 'Co-op',
        subtitle: 'With 1 smith',
        look: 'bronze',
        boards: [
          PlayedBoard(puzzle: board.puzzle, found: {0, 2}, owners: {0: 'u2', 2: 'me'}, bonus: ['TEA']),
        ],
        players: const [
          PlayedPlayer(id: 'me', username: 'Ali', color: 0),
          PlayedPlayer(id: 'u2', username: 'sam', color: 1),
        ],
        me: 'me',
        result: {
          'completed': false,
          'stars': 2,
          'teamScore': 140,
          'filled': 7,
          'total': 9,
          'mvp': 'u2',
          'points': {'me': 40, 'u2': 100},
          'words': {'me': 1, 'u2': 1},
        },
      ),
      vsRecord(vs, classicSeries(), at: _ago(const Duration(days: 1)))!,
      PlayRecord(
        id: 'daily-1',
        kind: PlayKind.daily,
        at: _ago(const Duration(days: 1, minutes: 3)),
        title: 'Daily Commission',
        subtitle: 'Cherry Red heat · Oct 17',
        boards: [
          PlayedBoard.fromBoard(Board(tearPuzzle(), foundSlots: [0, 1, 2])),
        ],
        result: {'elapsedMs': 95000},
      ),
    ];
    await _pumpApp(tester, '/history', history: history);

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('2 of 3 stars · Team 140'), findsOneWidget);
    expect(find.text('You won · 2 wins'), findsOneWidget);
    expect(find.text('3 words · 1:35'), findsOneWidget);

    // Filters.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Versus'));
    await tester.pumpAndSettle();
    expect(find.text('With 1 smith'), findsNothing);
    expect(find.text('Against 3 smiths'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Crucible'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing here yet for Crucible.'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();

    // Co-op: the team, who forged what, and the words the team missed.
    await tester.tap(find.text('With 1 smith'));
    await tester.pumpAndSettle();
    expect(find.text('Team 140'), findsOneWidget);
    expect(find.text('sam'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Glowing letters are the words the team missed.'), findsOneWidget);
    expect(find.text('Words: 2 of 3 forged'), findsOneWidget);
    expect(find.text('Bonus words (1)'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Versus: the series summary, a round opening its look back.
    await tester.tap(find.text('Against 3 smiths'));
    await tester.pumpAndSettle();
    expect(find.byType(SeriesSummary), findsOneWidget);
    expect(find.byType(PlayDetailScreen), findsOneWidget);
  });
}
