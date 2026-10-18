import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/game/providers.dart';

import '../fixtures/puzzles.dart';

/// The phone's bigger and bold text settings don't reach the game, whose
/// lettering is sized to its art: every main screen looks as it does at 100%.
void main() {
  for (final location in ['/', '/play/1', '/chapters', '/profile', '/settings', '/credits']) {
    testWidgets('$location ignores 200% bold system text on a small phone', (tester) async {
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
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(boldText: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.binding.setSurfaceSize(const Size(360, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: WordsmithApp(
            router: GoRouter(initialLocation: location, routes: appRouter.configuration.routes),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final text = tester.element(find.byType(Text).first);
      expect(MediaQuery.textScalerOf(text), TextScaler.noScaling);
      expect(MediaQuery.boldTextOf(text), isFalse);
    });
  }
}
