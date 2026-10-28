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
import 'package:wordsmith/features/coop/coop_entry.dart';
import 'package:wordsmith/features/hall/hall_screen.dart';
import 'package:wordsmith/game/party.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/net/room_client.dart';

import '../fixtures/fake_backend.dart';
import '../fixtures/fake_socket.dart';
import '../fixtures/puzzles.dart';

const _me = AuthUser(uid: 'uid-ali', email: 'ali@example.com');

Future<(GoRouter, ProviderContainer)> _pumpApp(
  WidgetTester tester,
  FakeSocketChannel room, {
  bool textChat = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false, 'roomChat': false, 'textChat': textChat}),
    'tips_seen.v1': ['chat_rules'],
  });
  final store = await Store.open();
  final auth = FakeAuth(signedIn: _me);
  final server = FakeServer()..username = 'Ali';
  // More friends than fit on a phone.
  for (var i = 1; i <= 14; i++) {
    server.friends.add({
      'id': 'uid-f$i',
      'username': 'friend$i',
      'avatar': 'avatar_05',
      'level': 3,
      'rank': 'Apprentice',
    });
  }
  server.rooms['K7Q2AB'] = {
    'code': 'K7Q2AB',
    'mode': 'coop',
    'phase': 'lobby',
    'players': 2,
    'maxPlayers': 4,
    'seated': true,
  };
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
      roomClientFactoryProvider.overrideWithValue(
        (code) => RoomClient(baseUrl: 'http://forge.test', code: code, token: auth.idToken, connect: (_, _) => room),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  tester.view
    ..physicalSize = const Size(412, 892)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(initialLocation: '/', routes: appRouter.configuration.routes);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  unawaited(router.push('/room/K7Q2AB?mode=coop'));
  await _pumpRoom(tester);
  return (router, container);
}

Map<String, Object?> _lobby({String mode = 'coop'}) => {
  'code': 'K7Q2AB',
  'mode': mode,
  'phase': 'lobby',
  'hostId': 'uid-ali',
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

/// Joins the room: WELCOME, then a SNAPSHOT carrying the chat said so far.
void _join(FakeSocketChannel room, {List<Map<String, Object?>> chat = const []}) {
  room
    ..receive({'op': 'WELCOME', 'you': 'uid-ali', 'protocol': 1, 'serverNow': DateTime.now().millisecondsSinceEpoch})
    ..receive({'op': 'SNAPSHOT', 'lobby': _lobby(), 'chat': chat});
}

/// Lets the room screen take its messages (its spinners never settle).
Future<void> _pumpRoom(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder get _bar => find.byKey(const ValueKey('party-bar'));

void main() {
  testWidgets('home keeps the room: the bar leads back, the host switches mode from the hall, Leave leaves', (
    tester,
  ) async {
    final room = FakeSocketChannel();
    final (router, container) = await _pumpApp(tester, room);
    _join(room);
    await _pumpRoom(tester);
    expect(find.text('The Guild Forge'), findsOneWidget);
    expect(_bar, findsNothing);

    // Home, still in the room: no LEAVE, and the bar at the top.
    await tester.tap(find.byKey(const ValueKey('room-home')));
    await _pumpRoom(tester);
    expect(find.byType(HallScreen), findsOneWidget);
    expect(room.sent.any((m) => m.contains('LEAVE')), isFalse);
    expect(_bar, findsOneWidget);
    expect(find.text('Co-op · K7Q2AB'), findsOneWidget);

    // Picking Team Versus in the hall, as the host, takes the room there.
    showRoomEntry(tester.element(find.byType(HallScreen)), 'team');
    await _pumpRoom(tester);
    expect(room.sent, contains(jsonEncode({'op': 'CONFIG', 'mode': 'team'})));
    room.receive({'op': 'LOBBY', ..._lobby(mode: 'team')});
    await _pumpRoom(tester);
    expect(container.read(partyProvider).session, isA<VsSession>());
    expect(find.text('Team Clash'), findsOneWidget);
    expect(_bar, findsNothing);

    // The host can switch from the lobby too.
    await tester.scrollUntilVisible(find.byKey(const ValueKey('mode-coop')), 200);
    await tester.tap(find.byKey(const ValueKey('mode-coop')));
    await tester.pump();
    expect(room.sent, contains(jsonEncode({'op': 'CONFIG', 'mode': 'coop'})));

    // Back home and Leave from the bar: asked first, then gone.
    await tester.tap(find.byKey(const ValueKey('room-home')));
    await _pumpRoom(tester);
    expect(_bar, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('party-leave')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'Leave')));
    await _pumpRoom(tester);
    expect(room.sent.last, jsonEncode({'op': 'LEAVE'}));
    expect(_bar, findsNothing);
    expect(container.read(partyProvider).session, isNull);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
  });

  testWidgets('away from the room, a round starting brings me back; only the host picks the mode', (tester) async {
    final room = FakeSocketChannel();
    final (router, _) = await _pumpApp(tester, room);
    room
      ..receive({'op': 'WELCOME', 'you': 'uid-ali', 'protocol': 1, 'serverNow': DateTime.now().millisecondsSinceEpoch})
      ..receive({
        'op': 'SNAPSHOT',
        'lobby': {..._lobby(), 'hostId': 'uid-sam'},
        'chat': <Object>[],
      });
    await _pumpRoom(tester);
    await tester.tap(find.byKey(const ValueKey('room-home')));
    await _pumpRoom(tester);
    expect(_bar, findsOneWidget);

    // Not the host: Versus from the hall just goes back to the room.
    showRoomEntry(tester.element(find.byType(HallScreen)), 'vs');
    await _pumpRoom(tester);
    expect(room.sent.any((m) => m.contains('"mode"')), isFalse);
    expect(find.text('Only the host picks the mode: back to your room.'), findsOneWidget);
    expect(router.state.uri.path, '/room/K7Q2AB');

    // Home again; the host starts a round and I'm taken back.
    await tester.tap(find.byKey(const ValueKey('room-home')));
    await _pumpRoom(tester);
    expect(router.state.uri.path, '/');
    final now = DateTime.now().millisecondsSinceEpoch;
    room
      ..receive({
        'op': 'ROUND_START',
        'round': 1,
        'heat': 3,
        'startsAt': now + 3000,
        'endsAt': now + 93000,
        'serverNow': now,
        'letters': 'CATOE',
        'cols': 3,
        'rows': 3,
        'slots': [
          {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 3},
          {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 3},
          {'slot': 2, 'x': 2, 'y': 0, 'd': 'd', 'len': 3},
        ],
        'pickups': <Object>[],
      })
      ..receive({'op': 'LOBBY', ..._lobby(), 'hostId': 'uid-sam', 'phase': 'countdown'});
    await _pumpRoom(tester);
    expect(router.state.uri.path, '/room/K7Q2AB');
    expect(_bar, findsNothing);
    expect(find.byKey(const ValueKey('room-home')), findsNothing);
  });

  testWidgets('after a Versus series, the host picking Versus again sets up the next one in the lobby', (tester) async {
    final room = FakeSocketChannel();
    final (router, container) = await _pumpApp(tester, room);
    room
      ..receive({'op': 'WELCOME', 'you': 'uid-ali', 'protocol': 1, 'serverNow': DateTime.now().millisecondsSinceEpoch})
      ..receive({
        'op': 'SNAPSHOT',
        'lobby': {..._lobby(mode: 'vs'), 'phase': 'results', 'series': 3},
        'chat': <Object>[],
      });
    await _pumpRoom(tester);
    await tester.tap(find.byKey(const ValueKey('room-home')));
    await _pumpRoom(tester);
    final before = container.read(partyProvider).session;

    // The same mode, from the hall: back to the lobby, not the podium.
    showRoomEntry(tester.element(find.byType(HallScreen)), 'vs');
    await _pumpRoom(tester);
    expect(room.sent, contains(jsonEncode({'op': 'CONFIG', 'mode': 'vs'})));
    room.receive({'op': 'LOBBY', ..._lobby(mode: 'vs'), 'series': 3});
    await _pumpRoom(tester);
    final after = container.read(partyProvider).session;
    expect(after, isA<VsSession>());
    expect(after, isNot(same(before)));
    expect(router.state.uri.path, '/room/K7Q2AB');
    expect(find.text('Anvil Clash'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Start the series'), 200);
    expect(find.text('Start the series'), findsOneWidget);
  });

  testWidgets('a long friend list scrolls in the invite sheet, down to the last friend', (tester) async {
    final room = FakeSocketChannel();
    await _pumpApp(tester, room);
    _join(room);
    await _pumpRoom(tester);
    await tester.scrollUntilVisible(find.text('Invite friends'), 200);
    await tester.tap(find.text('Invite friends'));
    await tester.pumpAndSettle();
    final sheet = find.byType(DraggableScrollableSheet);
    expect(sheet, findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('friend14'),
      200,
      scrollable: find.descendant(of: sheet, matching: find.byType(Scrollable)),
    );
    // Right to the end: nothing below it is cut off.
    await tester.drag(find.text('friend14'), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'friend14'), matching: find.text('Invite')));
    await tester.pump();
    expect(find.text('Invited friend14'), findsOneWidget);
  });
}
