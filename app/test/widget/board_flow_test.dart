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
import 'package:wordsmith/engine/hints.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/providers.dart';

import '../fixtures/fake_backend.dart';
import '../fixtures/puzzles.dart';

void main() {
  testWidgets('the Forge Board: stoke, claim and swap orders, gifts and the trials prize', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
    });
    final store = await Store.open();
    final auth = FakeAuth(signedIn: const AuthUser(uid: 'uid-ali', email: 'ali@example.com'));
    final server = FakeServer()
      ..username = 'Ali'
      ..stokeClaimed = false
      ..lastWeek = {
        'week': '2026-W41',
        'place': 1,
        'of': 2,
        'reward': FakeServer.reward(100, {'sparks': 1}),
      };
    server.friends.add({'id': 'uid-sam', 'username': 'sam', 'avatar': 'avatar_05', 'level': 3, 'rank': 'Apprentice'});
    server.giftsPending.add({
      'id': 1,
      'from': {'id': 'uid-sam', 'username': 'sam', 'avatar': 'avatar_05'},
      'sentAt': 0,
    });
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

    /// Waits for a reward popup to close itself.
    Future<void> popupGone() async {
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    }

    // The Hall offers today's Stoke.
    expect(find.text('Stoke the Forge · Day 1'), findsOneWidget);
    await tester.tap(find.text('Stoke!'));
    await popupGone();
    expect(container.read(profileProvider).totalXp, 15);
    expect(find.text('Stoke the Forge · Day 1'), findsNothing);

    // One order, the gifts and last week's prize are waiting.
    expect(find.text('3 rewards waiting'), findsOneWidget);
    await tester.tap(find.text('Forge Board'));
    await tester.pumpAndSettle();
    expect(find.text('Stoked for today. Come back tomorrow!'), findsOneWidget);

    // Claim the finished order.
    expect(find.text('Find 10 bonus words'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Claim').first);
    await popupGone();
    expect(container.read(profileProvider).hintCount(HintKind.hammer), 4);

    // Swap an unfinished one.
    await tester.tap(find.byTooltip('Swap this order').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Swap'));
    await tester.pumpAndSettle();
    expect(find.text('Forge 3 words of 6+ letters'), findsOneWidget);
    expect(find.byTooltip('Swap this order'), findsNothing, reason: 'one swap a day');

    // Gifts: collect sam's, send one back.
    await tester.scrollUntilVisible(find.text('Collect'), 200);
    await tester.ensureVisible(find.text('Collect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Collect'));
    await popupGone();
    expect(container.read(profileProvider).hintCount(HintKind.hammer), 5);
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(server.giftsSent, {'uid-sam'});
    expect(find.text('Sent'), findsOneWidget);

    // Last week's trials prize.
    await tester.scrollUntilVisible(find.text('Last week: 1st of 2!'), 200);
    await tester.ensureVisible(find.text('Last week: 1st of 2!'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Claim').last);
    await popupGone();
    expect(find.text('Last week: 1st of 2!'), findsNothing);
    expect(find.text('Ali (you)'), findsOneWidget);
  });
}
