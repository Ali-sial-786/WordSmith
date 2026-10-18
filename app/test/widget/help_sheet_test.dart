import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/hall/help_sheet.dart';
import 'package:wordsmith/game/providers.dart';

import '../fixtures/puzzles.dart';

Future<void> _pumpHall(WidgetTester tester, {Size size = const Size(412, 892)}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(
        Campaign.fromJson({
          'version': 1,
          'chapters': [
            {'id': 'tin', 'name': 'Tin', 'first': 1, 'count': 1},
          ],
          'puzzles': [tearJson()],
        }),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: '/', routes: appRouter.configuration.routes),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// [text] as a title in the guide (the Hall behind it has some of the same words).
Finder _inGuide(String text) => find.descendant(of: find.byType(HelpSheet), matching: find.text(text));

void main() {
  testWidgets('the Forge button says it is solo play', (tester) async {
    await _pumpHall(tester);
    expect(find.text('Forge (Solo play)'), findsOneWidget);
    expect(find.text('Tin · Puzzle 1 of 1'), findsOneWidget);
  });

  for (final size in [const Size(412, 892), const Size(360, 740)]) {
    testWidgets('the ? opens a guide to every mode and button at ${size.width.toInt()} wide', (tester) async {
      await _pumpHall(tester, size: size);
      await tester.tap(find.byType(HelpButton));
      await tester.pumpAndSettle();
      expect(find.text("The Smith's Guide"), findsOneWidget);

      final list = find.descendant(of: find.byType(HelpSheet), matching: find.byType(Scrollable)).first;
      for (final title in [
        'Forge (Solo play)',
        'Daily Commission',
        'The Crucible',
        'Chapters',
        'Co-op: The Guild Forge',
        'Versus: Anvil Clash',
        'Friends',
        'Daily Stoke',
        'Work Orders',
        'Weekly Trials',
        'Gifts',
        'Profile and ranks',
        'Armory and Masterworks',
        'Lore Book',
        'Settings',
        'Forging words',
        'Turn',
        'Hammer Strike',
        'Chisel',
        'Spark Shower',
        'Scrap Bin',
        'Embers',
        'Gilded cells',
        'Word meanings',
        'Why sign in?',
      ]) {
        await tester.scrollUntilVisible(_inGuide(title), 300, scrollable: list);
        expect(_inGuide(title), findsOneWidget, reason: title);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets("the guide explains Versus' Survival clash and the ranks", (tester) async {
    await _pumpHall(tester);
    await tester.tap(find.byTooltip('How to play'));
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byType(HelpSheet), matching: find.byType(Scrollable)).first;

    final survival = find.textContaining('Survival clash:', findRichText: true);
    await tester.scrollUntilVisible(survival, 300, scrollable: list);
    expect(survival, findsOneWidget);

    await tester.scrollUntilVisible(_inGuide('Legend'), 300, scrollable: list);
    expect(_inGuide('Level 120'), findsOneWidget);
  });

  testWidgets('the guide closes again', (tester) async {
    await _pumpHall(tester);
    await tester.tap(find.byType(HelpButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(HelpSheet), findsNothing);
    expect(find.text('Forge (Solo play)'), findsOneWidget);
  });
}
