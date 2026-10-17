import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/auth/auth_service.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/ui/anvil/anvil_ring.dart';

import '../fixtures/fake_backend.dart';
import '../fixtures/puzzles.dart';

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
  testWidgets('the Daily Commission is played, sent to the server, and keeps a streak', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
    });
    final store = await Store.open();
    final auth = FakeAuth(signedIn: const AuthUser(uid: 'uid-ali', email: 'ali@example.com'));
    final server = FakeServer()
      ..username = 'Ali'
      ..dailyPuzzle = (tearJson()..['id'] = 'daily-2026-10-17')
      ..dailyStreak = 2;
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
        authServiceProvider.overrideWithValue(auth),
        apiClientProvider.overrideWithValue(server.client(auth)),
      ],
    );
    addTearDown(container.dispose);
    await tester.binding.setSurfaceSize(const Size(412, 892));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: WordsmithApp(router: GoRouter(routes: appRouter.configuration.routes)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Keep your 2-day streak going'), findsOneWidget);
    await tester.tap(find.text('Daily Commission'));
    await tester.pumpAndSettle();
    expect(find.text('Daily Commission'), findsOneWidget, reason: 'the puzzle screen title');

    for (final w in ['TEAR', 'EAT', 'RATE']) {
      await _swipe(tester, w);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Daily Commission forged'), findsOneWidget);
    expect(find.text('3-day streak'), findsOneWidget);
    expect(find.text('+25 XP'), findsOneWidget);
    final post = server.dailyPosts.single;
    expect(post['date'], '2026-10-17');
    expect((post['foundWords'] as List).toSet(), {'TEAR', 'EAT', 'RATE'});

    await tester.tap(find.text('Forge Hall').last);
    await tester.pumpAndSettle();
    expect(find.text('Forged today · 3-day streak'), findsOneWidget);
    expect(container.read(profileProvider).totalXp, 25, reason: 'XP comes from the server');
  });
}
