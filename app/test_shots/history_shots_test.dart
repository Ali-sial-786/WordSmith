// Renders the puzzle history to PNGs with the real fonts, for eyeballing:
// the list, and the look back at a campaign puzzle, a co-op round, a
// Crucible run and a Versus series, at 412 and 360 wide.
// Not part of the suite: flutter test test_shots/history_shots_test.dart --update-goldens
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
import 'package:wordsmith/game/history_records.dart';
import 'package:wordsmith/game/providers.dart';

import '../test/fixtures/vs_review.dart';
import 'shot_fonts.dart';

final _now = DateTime.now();
int _ago(Duration d) => _now.subtract(d).millisecondsSinceEpoch;

List<PlayRecord> _history(Campaign campaign) {
  final c5 = campaign.puzzle(5);
  final c9 = campaign.puzzle(9);
  final c12 = campaign.puzzle(12);
  final vs = reviewSession();
  return [
    PlayRecord(
      id: 'campaign-5',
      kind: PlayKind.campaign,
      at: _ago(const Duration(minutes: 12)),
      title: campaign.chapterFor(5).name,
      subtitle: 'Puzzle 5 of ${campaign.chapterFor(5).count}',
      look: campaign.chapterFor(5).id,
      boards: [
        PlayedBoard.fromBoard(
          Board(c5, foundSlots: [for (final s in c5.slots) s.index], bonusFound: c5.bonus.take(3).toList()),
        ),
      ],
      result: {'stage': 5, 'elapsedMs': 142000, 'hints': 1, 'xp': 14},
    ),
    PlayRecord(
      id: 'coop-1',
      kind: PlayKind.coop,
      at: _ago(const Duration(hours: 2)),
      title: 'Co-op',
      subtitle: 'With 2 smiths',
      look: 'bronze',
      boards: [
        PlayedBoard(
          puzzle: c12,
          found: {for (final s in c12.slots.skip(2)) s.index},
          owners: {
            for (final s in c12.slots.skip(2)) s.index: ['u1', 'u2', 'u3'][s.index % 3],
          },
          bonus: c12.bonus.take(2).toList(),
        ),
      ],
      players: const [
        PlayedPlayer(id: 'u1', username: 'Ali', color: 0),
        PlayedPlayer(id: 'u2', username: 'sam', color: 1),
        PlayedPlayer(id: 'u3', username: 'Kit_the_Smith', color: 2),
      ],
      me: 'u1',
      result: {
        'completed': false,
        'stars': 2,
        'teamScore': 310,
        'filled': 20,
        'total': 26,
        'mvp': 'u2',
        'points': {'u1': 90, 'u2': 140, 'u3': 80},
        'words': {'u1': 2, 'u2': 3, 'u3': 2},
        'xp': 48,
      },
    ),
    vsRecord(vs, classicSeries(), at: _ago(const Duration(days: 1, hours: 1)))!,
    PlayRecord(
      id: 'crucible-1',
      kind: PlayKind.crucible,
      at: _ago(const Duration(days: 1, hours: 3)),
      title: 'The Crucible',
      subtitle: 'Ended when a word melted',
      look: 'iron',
      boards: [
        PlayedBoard.fromBoard(Board(c5, foundSlots: [for (final s in c5.slots) s.index])),
        PlayedBoard.fromBoard(Board(c9, foundSlots: [0, 1]), melted: 2),
      ],
      result: {'cleared': 1, 'saved': 4, 'words': 7, 'melted': true, 'elapsedMs': 210000},
    ),
    PlayRecord(
      id: 'daily-1',
      kind: PlayKind.daily,
      at: _ago(const Duration(days: 3)),
      title: 'Daily Commission',
      subtitle: 'Cherry Red heat · 15 Oct',
      look: 'copper',
      boards: [
        PlayedBoard.fromBoard(Board(c9, foundSlots: [for (final s in c9.slots) s.index])),
      ],
      result: {'elapsedMs': 95000, 'xp': 30},
    ),
  ];
}

Future<void> _pump(WidgetTester tester, double width) async {
  final campaign = await tester.runAsync(Campaign.load) ?? (throw StateError('no campaign'));
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'abc'}),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
    'history.v1': jsonEncode([for (final r in _history(campaign)) r.toJson()]),
  });
  final store = await Store.open();
  final container = ProviderContainer(
    overrides: [storeProvider.overrideWithValue(store), campaignProvider.overrideWithValue(campaign)],
  );
  addTearDown(container.dispose);
  final size = Size(width, width == 360 ? 780 : 892);
  await tester.binding.setSurfaceSize(size);
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: '/history', routes: appRouter.configuration.routes),
      ),
    ),
  );
  await _wait(tester);
}

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

void main() {
  setUpAll(loadShotFonts);

  for (final width in [412.0, 360.0]) {
    final w = width.toInt();

    testWidgets('history list, $w', (tester) async {
      await _pump(tester, width);
      await _shot('history_list_$w');
    });

    for (final (name, tile) in [
      ('campaign', 'Puzzle 5 of'),
      ('coop', 'With 2 smiths'),
      ('vs', 'Against 3 smiths'),
      ('crucible', 'Ended when a word melted'),
    ]) {
      testWidgets('history $name, $w', (tester) async {
        await _pump(tester, width);
        await tester.tap(find.textContaining(tile).first);
        await _wait(tester);
        await _shot('history_${name}_$w');
      });
    }
  }
}
