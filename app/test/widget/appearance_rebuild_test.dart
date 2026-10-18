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
import 'package:wordsmith/ui/theme/palette.dart';

import '../fixtures/puzzles.dart';

void main() {
  tearDown(() => Palette.scheme = PaletteScheme.forge);

  testWidgets('a new colour scheme reaches widgets that never rebuild by themselves', (tester) async {
    SharedPreferences.setMockInitialValues({
      'profile.v1': jsonEncode({'userId': 'abc'}),
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
    await tester.binding.setSurfaceSize(const Size(412, 892));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: WordsmithApp(
          router: GoRouter(initialLocation: '/', routes: appRouter.configuration.routes),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    // The Hall's ? is a const widget that colours itself from the palette.
    Color? questionMark() =>
        tester.widget<Text>(find.descendant(of: find.byType(HelpButton), matching: find.text('?'))).style?.color;
    expect(questionMark(), PaletteScheme.forge.molten);

    final starmetal = PaletteScheme.byId('starmetal');
    container.read(settingsProvider.notifier).update((s) => s.copyWith(colorScheme: starmetal.id));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(questionMark(), starmetal.molten);
    expect(questionMark(), isNot(PaletteScheme.forge.molten));
  });
}
