import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/providers.dart';

import '../fixtures/fake_backend.dart';
import '../fixtures/puzzles.dart';

Future<void> _pumpApp(WidgetTester tester, FakeAuth auth, FakeServer server) async {
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
}

void main() {
  testWidgets('sign up from the Forge Hall, pick a name, and see it at home', (tester) async {
    final auth = FakeAuth();
    final server = FakeServer();
    await _pumpApp(tester, auth, server);

    expect(find.text('Sign in to keep your progress safe and play with friends.'), findsOneWidget);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'ali@example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Pick a name'), findsOneWidget, reason: 'new accounts pick a name');
    await tester.enterText(find.widgetWithText(TextField, 'Smith name'), 'no');
    await tester.tap(find.text('Start forging'));
    await tester.pumpAndSettle();
    expect(find.text('Use 3–16 letters, numbers or _.'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Smith name'), 'Ali_Smith');
    await tester.ensureVisible(find.text('Start forging'));
    await tester.tap(find.text('Start forging'));
    await tester.pumpAndSettle();

    expect(find.text('Ali_Smith'), findsOneWidget, reason: 'the Forge Hall shows the name');
    expect(find.text('0 online'), findsOneWidget, reason: 'Friends is now available');
    expect(server.username, 'Ali_Smith');
  });

  testWidgets('Continue with Google goes straight to picking a name', (tester) async {
    final auth = FakeAuth()..googleEmail = 'sam@gmail.com';
    final server = FakeServer();
    await _pumpApp(tester, auth, server);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a name'), findsOneWidget);
  });

  testWidgets('builds without Google settings show only email sign-in', (tester) async {
    final auth = FakeAuth()..googleAvailableFlag = false;
    await _pumpApp(tester, auth, FakeServer());

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.widgetWithText(TextField, 'Email'), findsOneWidget);
  });
}
