// Renders the puzzle screen and the hall in every font choice, and the font picker, to PNGs
// with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots/font_shots_test.dart --update-goldens
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/masterworks.dart';
import 'package:wordsmith/engine/pickups.dart';
import 'package:wordsmith/engine/puzzle.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/ui/anvil/anvil_ring.dart';
import 'package:wordsmith/ui/theme/theme.dart';

import 'shot_fonts.dart';

/// A full-size 10×10 campaign puzzle with C and G all over its anvil and
/// mold, so the mold tiles are as small as they get:
///
///     . . R A C I N G . .
///     . . . . H . . A R C
///     . . R . A . . N . A
///     C H A R G I N G . R
///     H . N . R . I . . I
///     A R C H I N G . . N
///     R . H . N . H A N G
///     . . . . . C . I . .
///     . . . C H A I R . .
///     . . . . . R . . . .
///
/// (Stage 504 of the campaign before the puzzles' words were picked by
/// quality; kept here so the shots don't change with the campaign.)
Map<String, dynamic> _chargingJson() => {
  'id': 'c-0504',
  'letters': 'AHIRGNGC',
  'heat': 6,
  'cols': 10,
  'rows': 10,
  'words': [
    {'w': 'CHARGING', 'x': 0, 'y': 3, 'd': 'a'},
    {'w': 'CHAR', 'x': 0, 'y': 3, 'd': 'd'},
    {'w': 'ARCHING', 'x': 0, 'y': 5, 'd': 'a'},
    {'w': 'RANCH', 'x': 2, 'y': 2, 'd': 'd'},
    {'w': 'CHAGRIN', 'x': 4, 'y': 0, 'd': 'd'},
    {'w': 'RACING', 'x': 2, 'y': 0, 'd': 'a'},
    {'w': 'GANG', 'x': 7, 'y': 0, 'd': 'd'},
    {'w': 'NIGH', 'x': 6, 'y': 3, 'd': 'd'},
    {'w': 'HANG', 'x': 6, 'y': 6, 'd': 'a'},
    {'w': 'CARING', 'x': 9, 'y': 1, 'd': 'd'},
    {'w': 'ARC', 'x': 7, 'y': 1, 'd': 'a'},
    {'w': 'AIR', 'x': 7, 'y': 6, 'd': 'd'},
    {'w': 'CHAIR', 'x': 3, 'y': 8, 'd': 'a'},
    {'w': 'CAR', 'x': 5, 'y': 7, 'd': 'd'},
  ],
  'bonus': [
    'ACHING',
    'ACING',
    'AGIN',
    'AGING',
    'AIN',
    'AIRN',
    'ANI',
    'ARCH',
    'ARCING',
    'CAGING',
    'CAIRN',
    'CAN',
    'CARN',
    'CHA',
    'CHAIN',
    'CHARING',
    'CHI',
    'CHIA',
    'CHIN',
    'CHINA',
    'CHING',
    'CIG',
    'CIGAR',
    'CRAG',
    'GAG',
    'GAIN',
    'GAN',
    'GAR',
    'GARNI',
    'GHI',
    'GIG',
    'GIGA',
    'GIN',
    'GIRN',
    'GNAR',
    'GRACING',
    'GRAIN',
    'GRAN',
    'GRIG',
    'GRIN',
    'GRINCH',
    'HAG',
    'HAIR',
    'HARING',
    'HIC',
    'HIN',
    'ICH',
    'INARCH',
    'INCH',
    'NAG',
    'NAH',
    'NARC',
    'NARIC',
    'RAG',
    'RAGI',
    'RAGING',
    'RAH',
    'RAIN',
    'RAN',
    'RANG',
    'RANI',
    'RIA',
    'RICH',
    'RIG',
    'RIN',
    'RING',
  ],
};

Future<void> _pump(WidgetTester tester, String location, {String font = 'forge'}) async {
  final json = _chargingJson();
  final cells = Puzzle.fromJson(json).letterCount;
  // A player with no pickups or gilded cell in this puzzle, so every cell is plain.
  var user = 0;
  while (pickupsFor(userId: 'u$user', puzzleId: 'c-0504', cellCount: cells, level: 1).isNotEmpty ||
      gildedCellFor(userId: 'u$user', puzzleId: 'c-0504', cellCount: cells, pickups: const []) != null) {
    user++;
  }
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'u$user', 'campaignStage': 1}),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false, 'font': font}),
  });
  final store = await Store.open();
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(
        Campaign.fromJson({
          'version': 1,
          'chapters': [
            {'id': 'bronze', 'name': 'Bronze', 'first': 1, 'count': 60},
          ],
          'puzzles': [json],
        }),
      ),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(() => Fonts.choice = FontChoice.forge);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: location, routes: appRouter.configuration.routes),
      ),
    ),
  );
  await _wait(tester);
}

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 500));
  }
}

/// Swipes [word] across the anvil, taking a fresh tile for a repeated letter.
Future<void> _swipe(WidgetTester tester, String word) async {
  final used = <Offset>{};
  Offset centerOf(String letter) {
    final tiles = find.descendant(of: find.byType(AnvilRing), matching: find.text(letter));
    final at = tiles
        .evaluate()
        .map((e) => tester.getCenter(find.byWidget(e.widget)))
        .firstWhere((c) => !used.contains(c));
    used.add(at);
    return at;
  }

  final gesture = await tester.startGesture(centerOf(word[0]));
  for (final letter in word.substring(1).split('')) {
    await gesture.moveTo(centerOf(letter));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

void main() {
  setUpAll(loadShotFonts);

  for (final font in FontChoice.all) {
    testWidgets('puzzle in the ${font.name} fonts', (tester) async {
      await _pump(tester, '/play/1', font: font.id);
      for (final word in ['CHARGING', 'RACING', 'CHAIR']) {
        await _swipe(tester, word);
        await _wait(tester);
      }
      await _shot('fonts_puzzle_${font.id}');
    });

    testWidgets('hall in the ${font.name} fonts', (tester) async {
      await _pump(tester, '/', font: font.id);
      await _shot('fonts_hall_${font.id}');
    });
  }

  testWidgets('font picker', (tester) async {
    await _pump(tester, '/settings');
    await tester.scrollUntilVisible(find.text('Foundry'), 300);
    await Scrollable.ensureVisible(tester.element(find.text('Font')), alignment: 0.1);
    await _wait(tester);
    await _shot('fonts_picker');
    // Picking a font applies it at once and keeps the picker in view.
    await tester.tap(find.text('Clear'));
    await _wait(tester);
    await _shot('fonts_picker_clear');
  });

  testWidgets('font credits', (tester) async {
    await _pump(tester, '/credits');
    final heading = find.text('Art, sound and fonts');
    await tester.scrollUntilVisible(heading, 300);
    await Scrollable.ensureVisible(tester.element(heading), alignment: 0.05);
    await _wait(tester);
    await _shot('fonts_credits');
  });
}
