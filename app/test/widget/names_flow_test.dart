import 'dart:async';
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
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/theme/palette.dart';
import 'package:wordsmith/ui/widgets/gold_field.dart';

import '../fixtures/fake_backend.dart';
import '../fixtures/fake_socket.dart';
import '../fixtures/puzzles.dart';

const _me = AuthUser(uid: 'uid-ali', email: 'ali@example.com');

Future<GoRouter> _pumpApp(WidgetTester tester, FakeServer server, String location, {FakeSocketChannel? room}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  final auth = FakeAuth(signedIn: _me);
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
      if (room != null)
        roomClientFactoryProvider.overrideWithValue(
          (code) => RoomClient(baseUrl: 'http://forge.test', code: code, token: auth.idToken, connect: (_, _) => room),
        ),
    ],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  final router = GoRouter(initialLocation: location, routes: appRouter.configuration.routes);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Map<String, Object> _sam() => {
  'id': 'uid-sam',
  'username': 'sam',
  'avatar': 'avatar_05',
  'level': 12,
  'rank': 'Journeyman',
};

Map<String, Object?> _lobby() => {
  'op': 'LOBBY',
  'code': 'K7Q2AB',
  'mode': 'coop',
  'phase': 'lobby',
  'hostId': 'uid-sam',
  'heat': 3,
  'players': [
    {
      'id': 'uid-sam',
      'username': 'sam',
      'avatar': 'avatar_05',
      'level': 12,
      'color': 0,
      'ready': true,
      'connected': true,
    },
    {
      'id': 'uid-ali',
      'username': 'Ali',
      'avatar': 'avatar_03',
      'level': 4,
      'color': 1,
      'ready': false,
      'connected': true,
    },
  ],
};

/// Finds the Change username button at the top of the profile.
Future<void> _scrollToAccount(WidgetTester tester) async {
  await tester.scrollUntilVisible(find.text('Change username'), 300, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(find.text('Change username'));
  await tester.pumpAndSettle();
}

/// Lets the room screen take its messages (its spinners never settle).
Future<void> _pumpRoom(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('changing my username from the profile, with its rules and errors, as often as I like', (tester) async {
    final server = FakeServer()..username = 'Ali';
    await _pumpApp(tester, server, '/profile');

    await _scrollToAccount(tester);
    // The profile shows who I am to friends.
    expect(find.text('Ali'), findsOneWidget);
    await tester.tap(find.text('Change username'));
    await tester.pumpAndSettle();
    expect(find.text('Friends know you as'), findsOneWidget);
    expect(find.text('Ali'), findsOneWidget);

    final field = find.byKey(const ValueKey('new-username'));
    Future<void> submit(String name) async {
      await tester.enterText(field, name);
      await tester.tap(find.text('Change name'));
      await tester.pumpAndSettle();
    }

    await submit('no');
    expect(find.text('Use 3–16 letters, numbers or _.'), findsOneWidget);
    await submit('Ali');
    expect(find.text("That's your name already."), findsOneWidget);
    await submit('Taken');
    expect(find.text('That name is taken. Try another.'), findsOneWidget);
    expect(server.username, 'Ali');

    await submit('Ali_Smith');
    expect(server.username, 'Ali_Smith');
    expect(find.text("You're now Ali_Smith."), findsOneWidget);
    // Back in Settings with the new name, and free to change it again straight away.
    expect(find.text('Ali_Smith'), findsOneWidget);
    await tester.tap(find.text('Change username'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.descendant(of: field, matching: find.byType(TextField))).enabled, isTrue);
    await submit('Ali_Again');
    expect(server.username, 'Ali_Again');
    expect(find.text('Ali_Again'), findsOneWidget);
  });

  testWidgets('the Forge Hall shows the friends leaderboard, and See all opens the whole of it', (tester) async {
    final server = FakeServer()
      ..username = 'Ali'
      ..totalXp = 340;
    server.friends.add(_sam());
    await _pumpApp(tester, server, '/');
    final board = find.byKey(const ValueKey('hall-leaderboard'));
    await tester.scrollUntilVisible(board, 200, scrollable: find.byType(Scrollable).first);
    expect(find.descendant(of: board, matching: find.text('You')), findsOneWidget);
    expect(find.descendant(of: board, matching: find.text('340 XP')), findsOneWidget);
    expect(find.descendant(of: board, matching: find.text('sam')), findsOneWidget);
    expect(server.calls.where((c) => c == 'GET /leaderboard'), hasLength(1));

    await tester.ensureVisible(find.descendant(of: board, matching: find.text('See all')));
    await tester.tap(find.descendant(of: board, matching: find.text('See all')));
    await tester.pumpAndSettle();
    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    expect(DefaultTabController.of(tester.element(find.byWidget(tabs))).index, 1, reason: 'on the leaderboard');
  });

  testWidgets('a nickname replaces the username in the friends list, the leaderboard and a room', (tester) async {
    final server = FakeServer()..username = 'Ali';
    server.friends.add(_sam());
    final room = FakeSocketChannel();
    server.rooms['K7Q2AB'] = {
      'code': 'K7Q2AB',
      'mode': 'coop',
      'phase': 'lobby',
      'players': 2,
      'maxPlayers': 4,
      'seated': true,
    };
    final router = await _pumpApp(tester, server, '/friends', room: room);

    expect(find.text('sam'), findsOneWidget);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Give a nickname'));
    await tester.pumpAndSettle();
    expect(find.text('Nickname for sam'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('nickname')), '  Big Sam ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(server.friends.single['nickname'], 'Big Sam');
    expect(find.text('Big Sam'), findsOneWidget);
    // The real username stays, small, underneath.
    expect(find.text('sam'), findsOneWidget);
    expect(tester.getTopLeft(find.text('sam')).dy, greaterThan(tester.getTopLeft(find.text('Big Sam')).dy));

    await tester.tap(find.text('Leaderboard'));
    await tester.pumpAndSettle();
    expect(find.text('Big Sam'), findsOneWidget);

    // In a room, the lobby names sam by my nickname too.
    unawaited(router.push('/room/K7Q2AB?mode=coop'));
    await _pumpRoom(tester);
    room.receive({
      'op': 'WELCOME',
      'you': 'uid-ali',
      'protocol': 1,
      'serverNow': DateTime.now().millisecondsSinceEpoch,
    });
    room.receive(_lobby());
    await _pumpRoom(tester);
    expect(find.text('Big Sam'), findsOneWidget);
    expect(find.textContaining('host Big Sam'), findsOneWidget);
    expect(find.text('Waiting for Big Sam to start…'), findsOneWidget);
    expect(find.text('Ali (you)'), findsOneWidget);
    expect(find.text('sam'), findsNothing);

    // Leaving tidies the socket away.
    router.pop();
    await tester.pumpAndSettle();

    // And clearing it brings the username back.
    await tester.tap(find.text('Friends').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear nickname'));
    await tester.pumpAndSettle();
    expect(server.friends.single.containsKey('nickname'), isFalse);
    expect(find.text('Big Sam'), findsNothing);
    expect(find.text('sam'), findsOneWidget);
  });

  testWidgets('the add-friend field is a clear gold box, brighter when focused', (tester) async {
    final server = FakeServer()..username = 'Ali';
    await _pumpApp(tester, server, '/friends');

    final box = find.byKey(const ValueKey('add-friend'));
    expect(
      find.descendant(of: box, matching: find.text("Friend's username")),
      findsOneWidget,
      reason: 'the hint',
    );
    final field = tester.widget<TextField>(find.descendant(of: box, matching: find.byType(TextField)));
    final decoration = field.decoration!;
    final enabled = (decoration.enabledBorder! as OutlineInputBorder).borderSide;
    final focused = (decoration.focusedBorder! as OutlineInputBorder).borderSide;
    expect(field.style!.color, Palette.gold, reason: 'gold text');
    expect(enabled.color.withValues(alpha: 1), Palette.gold, reason: 'a gold border');
    expect(enabled.width, greaterThanOrEqualTo(1.5));
    expect(focused.color, GoldTextField.focusedGold);
    expect(focused.width, greaterThan(enabled.width));
    expect(focused.color.computeLuminance(), greaterThan(Palette.gold.computeLuminance()), reason: 'brighter');
    expect(decoration.filled, isTrue);

    await tester.tap(box);
    await tester.pump();
    final decorator = tester.widget<InputDecorator>(find.descendant(of: box, matching: find.byType(InputDecorator)));
    expect(decorator.isFocused, isTrue);

    await tester.enterText(box, 'sam');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Request sent to sam.'), findsOneWidget);
  });

  test('room sessions name players by my nicknames, also after they leave', () {
    final s = VsSession(
      client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'),
      me: 'u1',
    )..lobby = RoomLobby.fromJson({..._lobby(), 'mode': 'vs'});
    addTearDown(s.dispose);
    expect(s.nameOf('uid-sam'), 'sam');
    s.nicknameOf = (id) => id == 'uid-sam' ? 'Big Sam' : null;
    expect(s.nameOf('uid-sam'), 'Big Sam');
    expect(s.nameOf('uid-ali'), 'Ali');
    s
      ..lobby = RoomLobby.fromJson({..._lobby(), 'mode': 'vs', 'players': <Object>[]})
      ..seriesEnd = SeriesEnd.fromJson({
        'winner': 'uid-sam',
        'rounds': 3,
        'podium': [
          {'id': 'uid-sam', 'username': 'sam', 'wins': 2, 'place': 1},
          {'id': 'uid-ali', 'username': 'Ali', 'wins': 1, 'place': 2},
        ],
        'xp': {},
      });
    expect(s.nameOf('uid-sam'), 'Big Sam', reason: 'the podium uses it too');
    expect(s.nameOf('uid-ali'), 'Ali');
  });
}
