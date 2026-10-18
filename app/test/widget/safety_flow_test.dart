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

Future<(FakeServer, ProviderContainer, GoRouter)> _pumpApp(
  WidgetTester tester, {
  String location = '/',
  FakeSocketChannel? room,
  bool signedIn = true,
  bool rulesSeen = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false, 'roomChat': false}),
    if (rulesSeen) 'tips_seen.v1': ['chat_rules'],
  });
  final store = await Store.open();
  final auth = FakeAuth(signedIn: signedIn ? _me : null);
  final server = FakeServer()..username = 'Ali';
  server.friends.add({'id': 'uid-sam', 'username': 'sam', 'avatar': 'avatar_05', 'level': 12, 'rank': 'Journeyman'});
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
      if (room != null)
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
  final router = GoRouter(initialLocation: location, routes: appRouter.configuration.routes);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  return (server, container, router);
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

Future<void> _pumpRoom(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _enterRoom(WidgetTester tester, GoRouter router, FakeSocketChannel room) async {
  unawaited(router.push('/room/K7Q2AB?mode=coop'));
  await _pumpRoom(tester);
  room
    ..receive({'op': 'WELCOME', 'you': 'uid-ali', 'protocol': 1, 'serverNow': DateTime.now().millisecondsSinceEpoch})
    ..receive({
      'op': 'SNAPSHOT',
      'lobby': _lobby(),
      'chat': [_line(1, 'uid-sam', 'hi'), _line(2, 'uid-sam', 'buy cheap coins at spam.example')],
    });
  await _pumpRoom(tester);
}

void main() {
  testWidgets('reporting from the chat sends the reason, details and their lines in this room', (tester) async {
    final room = FakeSocketChannel();
    final (server, _, router) = await _pumpApp(tester, room: room);
    await _enterRoom(tester, router, room);

    await tester.tap(find.byType(ChatButton));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('buy cheap coins at spam.example'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report sam'));
    await tester.pumpAndSettle();
    expect(find.text('Send report'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Send report')).onPressed,
      isNull,
      reason: 'a reason first',
    );
    expect(find.textContaining('Their 2 messages in this room will be sent'), findsOneWidget);
    await tester.tap(find.text('Spam'));
    await tester.enterText(find.byType(TextField).last, 'Keeps posting links');
    await tester.pump();
    await tester.tap(find.text('Send report'));
    await _pumpRoom(tester);
    await tester.pumpAndSettle();

    expect(server.reports, hasLength(1));
    final report = server.reports.single;
    expect(report['userId'], 'uid-sam');
    expect(report['reason'], 'spam');
    expect(report['details'], 'Keeps posting links');
    expect(report['room'], 'K7Q2AB');
    expect([for (final l in report['lines'] as List) (l as Map)['text']], ['hi', 'buy cheap coins at spam.example']);
    expect(find.textContaining('Report sent'), findsOneWidget);
  });

  testWidgets('blocking hides their chat everywhere until unblocked in Settings', (tester) async {
    final room = FakeSocketChannel();
    final (server, container, router) = await _pumpApp(tester, room: room);
    await _enterRoom(tester, router, room);

    // From the lobby's menu next to sam.
    await tester.tap(find.byTooltip('Mute, block or report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block sam'));
    await tester.pumpAndSettle();
    expect(find.text('Block sam?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Block'));
    await _pumpRoom(tester);
    await tester.pumpAndSettle();
    expect(server.blocks.single['id'], 'uid-sam');
    expect(container.read(accountProvider).blocked.single.id, 'uid-sam');
    expect(server.friends, isEmpty, reason: 'blocking ends the friendship');
    expect(find.textContaining('Blocked'), findsWidgets);

    // Their new lines neither pop up nor count, and the chat doesn't show them.
    room.receive({'op': 'CHAT', ..._line(3, 'uid-sam', 'hey')});
    await _pumpRoom(tester);
    expect(find.byType(ChatToast), findsNothing);
    await tester.tap(find.byType(ChatButton));
    await tester.pumpAndSettle();
    expect(find.text('hey'), findsNothing);
    expect(find.text('hi'), findsNothing);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    // Settings › Blocked smiths › Unblock.
    router.go('/settings');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Blocked smiths'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('1 blocked · their chat is hidden'), findsOneWidget);
    await tester.ensureVisible(find.text('Blocked smiths'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Blocked smiths'));
    await tester.pumpAndSettle();
    expect(find.text('sam'), findsOneWidget);
    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();
    expect(server.blocks, isEmpty);
    expect(find.textContaining("You haven't blocked anyone"), findsOneWidget);
    expect(container.read(accountProvider).blocked, isEmpty);

    // Further down Settings: the privacy policy, terms, the contact form and deleting on the web.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Contact us'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Terms and chat rules'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Delete your account on the web'), findsOneWidget);
    expect(find.text('play.wordsmith-forge.workers.dev/delete-account'), findsOneWidget);
  });

  testWidgets('the chat rules show the first time the chat opens, until Got it', (tester) async {
    final room = FakeSocketChannel();
    final (_, container, router) = await _pumpApp(tester, room: room, rulesSeen: false);
    await _enterRoom(tester, router, room);
    await tester.tap(find.byType(ChatButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('Be kind in the forge'), findsOneWidget);
    expect(find.text('Chat rules'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Be kind in the forge'), findsNothing);
    expect(container.read(storeProvider).seenTip('chat_rules'), isTrue);
  });

  testWidgets('the account can be deleted from the web route, after signing in', (tester) async {
    final (_, _, _) = await _pumpApp(tester, location: '/delete-account', signedIn: false);
    expect(find.text('Delete your account'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('signed in, the web route shows who will be deleted and asks to confirm', (tester) async {
    await _pumpApp(tester, location: '/delete-account');
    expect(find.text('Signed in as Ali.'), findsOneWidget);
    await tester.tap(find.text('Delete my account'));
    await tester.pumpAndSettle();
    expect(find.text('Delete your account?'), findsOneWidget);
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(find.text('Signed in as Ali.'), findsOneWidget);
  });
}
