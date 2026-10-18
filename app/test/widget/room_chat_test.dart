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
import 'package:wordsmith/features/coop/room_chat.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/net/room_client.dart';

import '../fixtures/fake_backend.dart';
import '../fixtures/fake_socket.dart';
import '../fixtures/puzzles.dart';

const _me = AuthUser(uid: 'uid-ali', email: 'ali@example.com');

Future<GoRouter> _pumpApp(WidgetTester tester, FakeSocketChannel room, {bool textChat = true}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false, 'roomChat': false, 'textChat': textChat}),
    'tips_seen.v1': ['chat_rules'],
  });
  final store = await Store.open();
  final auth = FakeAuth(signedIn: _me);
  final server = FakeServer()..username = 'Ali';
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
  return router;
}

Map<String, Object?> _lobby() => {
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

Map<String, Object?> _line(int id, String from, String text) => {
  'id': id,
  'from': from,
  'username': from == 'uid-sam' ? 'sam' : 'Ali',
  'text': text,
  'at': 1000 * id,
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

Finder get _badge => find.descendant(of: find.byType(ChatButton), matching: find.byType(Badge));

String? _badgeText(WidgetTester tester) {
  final badge = tester.widget<Badge>(_badge);
  return badge.isLabelVisible ? (badge.label as Text?)?.data : null;
}

void main() {
  testWidgets('chat in a room: what was said before is no news, new lines pop up and count, sending and muting', (
    tester,
  ) async {
    final room = FakeSocketChannel();
    await _pumpApp(tester, room);
    _join(room, chat: [_line(1, 'uid-sam', 'hi all')]);
    await _pumpRoom(tester);

    // The lobby has the chat button, nothing waiting.
    expect(find.byType(ChatButton), findsOneWidget);
    expect(_badgeText(tester), isNull);
    expect(find.text('hi all'), findsNothing);

    // A new line pops up over the room for a moment, and is counted.
    room.receive({'op': 'CHAT', ..._line(2, 'uid-sam', 'ready?')});
    await _pumpRoom(tester);
    expect(find.descendant(of: find.byType(ChatToast), matching: find.textContaining('ready?')), findsOneWidget);
    expect(_badgeText(tester), '1');
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300)); // its fade
    expect(find.byType(ChatToast), findsNothing);
    expect(_badgeText(tester), '1');

    // Opening the chat shows everything, history included, and clears the count.
    await tester.tap(find.byType(ChatButton));
    await tester.pumpAndSettle();
    expect(find.text('Forge chat'), findsOneWidget);
    expect(find.text('hi all'), findsOneWidget);
    expect(find.text('ready?'), findsOneWidget);
    expect(_badgeText(tester), isNull);

    // Sending goes to the room; the server's echo shows it as mine.
    await tester.enterText(find.byType(TextField), 'go go go');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(room.sent, contains(jsonEncode({'op': 'CHAT', 'text': 'go go go'})));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    room.receive({'op': 'CHAT', ..._line(3, 'uid-ali', 'go go go')});
    await _pumpRoom(tester);
    expect(find.text('go go go'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);

    // A quick phrase sends in one tap.
    await tester.tap(find.widgetWithText(ActionChip, 'Good luck!'));
    await tester.pump();
    expect(room.sent, contains(jsonEncode({'op': 'CHAT', 'text': 'Good luck!'})));

    // Writing too fast says so in the chat.
    room.receive({'op': 'ERROR', 'code': 'chat_limit'});
    await _pumpRoom(tester);
    expect(find.textContaining('Easy on the bellows'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.textContaining('Easy on the bellows'), findsNothing);

    // While the chat is open, new lines are read and don't pop up.
    room.receive({'op': 'CHAT', ..._line(4, 'uid-sam', 'lol')});
    await _pumpRoom(tester);
    expect(find.text('lol'), findsOneWidget);
    expect(find.byType(ChatToast), findsNothing);

    // Holding down sam's line mutes him for this room.
    await tester.longPress(find.text('lol'));
    await tester.pumpAndSettle();
    expect(find.text('Block sam'), findsOneWidget);
    expect(find.text('Report sam'), findsOneWidget);
    await tester.tap(find.text('Mute in this room'));
    await tester.pumpAndSettle();
    expect(find.text('lol'), findsNothing);
    expect(find.text('hi all'), findsNothing);
    expect(find.widgetWithText(InputChip, 'sam'), findsOneWidget);

    // Closed again: a muted player's lines neither pop up nor count.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    room.receive({'op': 'CHAT', ..._line(5, 'uid-sam', 'hello??')});
    await _pumpRoom(tester);
    expect(find.byType(ChatToast), findsNothing);
    expect(_badgeText(tester), isNull);

    // Unmuting brings him back.
    await tester.tap(find.byType(ChatButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Unmute'));
    await tester.pumpAndSettle();
    expect(find.text('hello??'), findsOneWidget);
    expect(find.text('hi all'), findsOneWidget);
  });

  testWidgets('a toast opens the chat with a tap', (tester) async {
    final room = FakeSocketChannel();
    await _pumpApp(tester, room);
    _join(room);
    await _pumpRoom(tester);
    room.receive({'op': 'CHAT', ..._line(1, 'uid-sam', 'join voice?')});
    await _pumpRoom(tester);
    await tester.tap(find.byType(ChatToast));
    await tester.pumpAndSettle();
    expect(find.text('Forge chat'), findsOneWidget);
    expect(find.descendant(of: find.byType(RoomChatSheet), matching: find.text('join voice?')), findsOneWidget);
    expect(find.byType(ChatToast), findsNothing);
  });

  testWidgets('with text chat turned off in Settings, there is no button and nothing pops up', (tester) async {
    final room = FakeSocketChannel();
    await _pumpApp(tester, room, textChat: false);
    _join(room);
    await _pumpRoom(tester);
    expect(find.byType(ChatButton), findsNothing);
    expect(find.byTooltip('Chat'), findsNothing);
    room.receive({'op': 'CHAT', ..._line(1, 'uid-sam', 'anyone?')});
    await _pumpRoom(tester);
    expect(find.byType(ChatToast), findsNothing);
    expect(find.text('anyone?'), findsNothing);
  });
}
