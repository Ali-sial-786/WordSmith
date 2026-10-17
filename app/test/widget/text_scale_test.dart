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

/// Big system text on a small phone: every main screen must still fit.
void main() {
  for (final location in ['/', '/play/1', '/chapters', '/profile', '/settings', '/credits']) {
    testWidgets('$location fits with 130% text on a small phone', (tester) async {
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
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.binding.setSurfaceSize(const Size(360, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: WordsmithApp(router: GoRouter(initialLocation: location, routes: appRouter.configuration.routes)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
