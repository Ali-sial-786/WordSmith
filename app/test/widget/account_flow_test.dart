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
import 'package:wordsmith/features/coop/room_screen.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/net/room_client.dart';

import '../fixtures/fake_backend.dart';
import '../fixtures/puzzles.dart';

Future<void> _pumpApp(
  WidgetTester tester,
  FakeAuth auth,
  FakeServer server, {
  FakePush? push,
  String? location,
  bool rooms = false,
}) async {
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
      apiClientProvider.overrideWithValue(server.client(auth, notInQuebec: () => store.notInQuebec)),
      if (push != null) pushServiceProvider.overrideWithValue(push),
      if (rooms)
        roomClientFactoryProvider.overrideWithValue(
          (code) => RoomClient(baseUrl: 'http://127.0.0.1:9', code: code, token: auth.idToken),
        ),
    ],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: location ?? '/', routes: appRouter.configuration.routes),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Picks the birth month and year on the setup screen.
Future<void> _pickBirth(WidgetTester tester, {required int year, String month = 'May'}) async {
  await tester.ensureVisible(find.text('Month'));
  await tester.tap(find.text('Month'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(month).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Year'));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text('$year'), 120, scrollable: find.byType(Scrollable).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('$year').last);
  await tester.pumpAndSettle();
}

/// Scrolls the setup form to its button and taps it.
Future<void> _tapStart(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Start forging').hitTestable(),
    200,
    scrollable: find.ancestor(of: find.text('When were you born?'), matching: find.byType(Scrollable)).first,
  );
  await tester.tap(find.text('Start forging'));
  await tester.pumpAndSettle();
}

Future<void> _signUp(WidgetTester tester) async {
  await tester.tap(find.text('Sign in'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('New here? Create an account'));
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, 'Email'), 'ali@example.com');
  await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret1');
  await tester.tap(find.text('Create account'));
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
    await _tapStart(tester);
    await tester.pumpAndSettle();
    expect(find.text('Use 3–16 letters, numbers or _.'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.widgetWithText(TextField, 'Smith name'),
      -200,
      scrollable: find.ancestor(of: find.text('When were you born?'), matching: find.byType(Scrollable)).first,
    );
    await tester.enterText(find.widgetWithText(TextField, 'Smith name'), 'Ali_Smith');
    await _tapStart(tester);
    await tester.pumpAndSettle();
    expect(find.text('Choose the month and year you were born.'), findsOneWidget, reason: 'the age is asked too');

    await _pickBirth(tester, year: 1998);
    await _tapStart(tester);
    await tester.pumpAndSettle();

    expect(find.text('Ali_Smith'), findsOneWidget, reason: 'the Forge Hall shows the name');
    expect(find.text('0 online'), findsOneWidget, reason: 'Friends is now available');
    expect(server.username, 'Ali_Smith');
    expect((server.birthYear, server.birthMonth), (1990, 5), reason: "the fake keeps its adult; it got 1998's month");
  });

  testWidgets('an under-13 is turned away: no account, and sign-in closed on this phone', (tester) async {
    final auth = FakeAuth();
    final server = FakeServer()..birthYear = null;
    await _pumpApp(tester, auth, server);
    await _signUp(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Smith name'), 'Kiddo');
    await _pickBirth(tester, year: DateTime.now().year - 10);
    await _tapStart(tester);
    await tester.pumpAndSettle();

    expect(find.text('Online play is for 13 and over'), findsOneWidget);
    expect(server.deletedMe, isTrue);
    expect(auth.deleted, isTrue, reason: 'the fresh sign-in is removed');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to keep your progress safe and play with friends.'), findsOneWidget);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Online play is closed on this phone'), findsOneWidget, reason: 'sign-in stays closed here');
    expect(find.text('Create account'), findsNothing);
  });

  testWidgets("from Quebec, sign-in says online play isn't offered, unless they live elsewhere", (tester) async {
    final auth = FakeAuth();
    final server = FakeServer()..quebec = true;
    await _pumpApp(tester, auth, server);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text("Online play isn't offered in Quebec"), findsOneWidget);
    expect(find.text('Create account'), findsNothing);
    expect(find.text('Your account is kept. You can delete it in Settings.'), findsNothing, reason: 'not signed in');

    await tester.tap(find.text("I don't live in Quebec"));
    await tester.pumpAndSettle();
    expect(find.text("Don't live in Quebec?"), findsOneWidget, reason: 'it asks first');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text("Online play isn't offered in Quebec"), findsOneWidget);

    await tester.tap(find.text("I don't live in Quebec"));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, "I don't live in Quebec").last);
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget, reason: 'sign-in opens');

    await tester.tap(find.text('New here? Create an account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'ali@example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a name'), findsOneWidget, reason: 'every call now says they live elsewhere');
    expect(server.calls.where((c) => c.contains('refused')), isEmpty);
  });

  testWidgets('a signed-in player in Quebec keeps their account, and gets in after saying they live elsewhere', (
    tester,
  ) async {
    final auth = FakeAuth(
      signedIn: const AuthUser(uid: 'u1', email: 'ali@example.com'),
    );
    final server = FakeServer()
      ..username = 'Ali'
      ..quebec = true;
    await _pumpApp(tester, auth, server);

    expect(find.text("Online play isn't offered in Quebec."), findsOneWidget);
    expect(server.calls, contains('GET /me (refused in Quebec)'));
    expect(server.deletedMe, isFalse, reason: 'an IP address can be wrong, so the account stays');

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Your account is kept. You can delete it in Settings.'), findsOneWidget);
    await tester.tap(find.text("I don't live in Quebec"));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, "I don't live in Quebec").last);
    await tester.pumpAndSettle();

    expect(find.text('Ali'), findsOneWidget, reason: 'back at the Forge Hall, signed in');
    expect(find.text("Online play isn't offered in Quebec."), findsNothing);
  });

  testWidgets('an account made before ages were asked confirms its age once', (tester) async {
    final auth = FakeAuth(
      signedIn: const AuthUser(uid: 'u1', email: 'ali@example.com'),
    );
    final server = FakeServer()
      ..username = 'Ali'
      ..birthYear = null;
    await _pumpApp(tester, auth, server);

    expect(find.text('Confirm your age to keep playing online.'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('One more thing'), findsOneWidget);
    expect(find.text('Pick a name'), findsNothing, reason: 'only the age is asked');

    await _pickBirth(tester, year: DateTime.now().year - 15, month: 'January');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(server.birthYear, DateTime.now().year - 15);
    expect(find.text('0 online'), findsOneWidget, reason: 'online play is open');
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

  testWidgets('tapping an invite notification opens that room', (tester) async {
    final push = FakePush();
    await _pumpApp(tester, FakeAuth(), FakeServer(), push: push);
    push.tap({'type': 'invite', 'code': 'K7Q2AB', 'mode': 'vs', 'from': 'u2'});
    await tester.pumpAndSettle();
    final room = tester.widget<RoomScreen>(find.byType(RoomScreen));
    expect((room.code, room.mode), ('K7Q2AB', 'vs'));
  });

  testWidgets('a room that is mid-round explains itself instead of spinning', (tester) async {
    final auth = FakeAuth(
      signedIn: const AuthUser(uid: 'uid-ali', email: 'ali@example.com'),
    );
    final server = FakeServer()..username = 'Ali';
    server.rooms['K7Q2AB'] = {
      'code': 'K7Q2AB',
      'mode': 'coop',
      'phase': 'round',
      'players': 2,
      'maxPlayers': 4,
      'seated': false,
    };
    await _pumpApp(tester, auth, server, location: '/room/K7Q2AB?mode=coop', rooms: true);
    expect(find.text("They're mid-round. Try again when it ends."), findsOneWidget);
    expect(find.text('Back to the Forge Hall'), findsOneWidget);
  });
}
