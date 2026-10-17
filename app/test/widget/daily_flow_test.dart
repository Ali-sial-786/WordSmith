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
import 'package:wordsmith/game/daily_game.dart';
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
    expect(post['date'], todayUtc());
    expect((post['foundWords'] as List).toSet(), {'TEAR', 'EAT', 'RATE'});

    await tester.tap(find.text('Forge Hall').last);
    await tester.pumpAndSettle();
    expect(find.text('Forged today · 3-day streak'), findsOneWidget);
    expect(container.read(profileProvider).totalXp, 25, reason: 'XP comes from the server');
  });

  testWidgets('the calendar shows done days, and a missed day can be played late', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
    });
    final store = await Store.open();
    final auth = FakeAuth(signedIn: const AuthUser(uid: 'uid-ali', email: 'ali@example.com'));
    final now = DateTime.now().toUtc();
    final yesterday = todayUtc(now.subtract(const Duration(days: 1)));
    final twoAgo = todayUtc(now.subtract(const Duration(days: 2)));
    final server = FakeServer()
      ..username = 'Ali'
      ..dailyPuzzle = tearJson()
      ..dailyStreak = 1
      ..dailyDone = true;
    server.dailyDays.add(twoAgo);
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
    final router = GoRouter(routes: appRouter.configuration.routes);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: WordsmithApp(router: router)),
    );
    await tester.pumpAndSettle();

    router.push('/daily/calendar');
    await tester.pumpAndSettle();
    if (now.day <= 2) {
      // The missed day is last month.
      await tester.tap(find.byType(ButtonSegment<bool>).first, warnIfMissed: false);
      await tester.tap(find.textContaining(RegExp('January|February|March|April|May|June|July|August|September|October|November|December')).first);
      await tester.pumpAndSettle();
    }
    expect(find.text('Trophy case'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    await tester.tap(find.bySemanticsLabel(RegExp('^$yesterday, missed: play late')));
    semantics.dispose();
    await tester.pumpAndSettle();
    expect(find.text('Daily Commission'), findsWidgets);
    for (final w in ['TEAR', 'EAT', 'RATE']) {
      await _swipe(tester, w);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // The Forged! card waits for the pour to finish.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Late commission forged'), findsOneWidget);
    expect(find.text('Played late, so your streak is unchanged.'), findsOneWidget);
    expect(server.dailyPosts.single['date'], yesterday);
    expect(container.read(profileProvider).totalXp, 15);
  });
}
