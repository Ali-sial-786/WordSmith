// Renders blocking, reporting and account deletion to PNGs with the real
// fonts, for eyeballing, at 412 and 360 wide.
// Not part of the suite: flutter test test_shots/safety_shots_test.dart --update-goldens
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

import '../test/fixtures/fake_backend.dart';
import '../test/fixtures/fake_socket.dart';
import 'shot_fonts.dart';

const _me = AuthUser(uid: 'u1', email: 'ali@example.com');

Future<(FakeSocketChannel, GoRouter)> _pump(
  WidgetTester tester,
  double width, {
  String location = '/',
  bool rulesSeen = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false, 'roomChat': false}),
    if (rulesSeen) 'tips_seen.v1': ['chat_rules'],
  });
  final store = await Store.open();
  final auth = FakeAuth(signedIn: _me);
  final server = FakeServer()..username = 'Ali';
  server.blocks.add({'id': 'u9', 'username': 'Grumpy_Gus', 'avatar': 'avatar_07', 'at': 1});
  server.rooms['K7Q2AB'] = {
    'code': 'K7Q2AB',
    'mode': 'coop',
    'phase': 'lobby',
    'players': 3,
    'maxPlayers': 4,
    'seated': true,
  };
  final room = FakeSocketChannel();
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(await tester.runAsync(Campaign.load) ?? (throw StateError('no campaign'))),
      authServiceProvider.overrideWithValue(auth),
      apiClientProvider.overrideWithValue(server.client(auth)),
      roomClientFactoryProvider.overrideWithValue(
        (code) => RoomClient(baseUrl: 'http://forge.test', code: code, token: auth.idToken, connect: (_, _) => room),
      ),
    ],
  );
  addTearDown(container.dispose);
  final size = Size(width, width == 360 ? 780 : 892);
  await tester.binding.setSurfaceSize(size);
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final router = GoRouter(initialLocation: location, routes: appRouter.configuration.routes);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(router: router),
    ),
  );
  await _wait(tester);
  return (room, router);
}

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _enterRoom(WidgetTester tester, FakeSocketChannel room, GoRouter router) async {
  unawaited(router.push('/room/K7Q2AB?mode=coop'));
  await _wait(tester);
  room
    ..receive({'op': 'WELCOME', 'you': 'u1', 'protocol': 1, 'serverNow': DateTime.now().millisecondsSinceEpoch})
    ..receive({
      'op': 'SNAPSHOT',
      'lobby': {
        'code': 'K7Q2AB',
        'mode': 'coop',
        'phase': 'lobby',
        'hostId': 'u2',
        'heat': 3,
        'players': [
          for (final (i, n) in ['Ali', 'sam', 'Grumpy_Gus'].indexed)
            {
              'id': i == 2 ? 'u9' : 'u${i + 1}',
              'username': n,
              'avatar': 'avatar_0${i + 3}',
              'level': 4 + i * 5,
              'color': i,
              'ready': i != 0,
              'connected': true,
            },
        ],
      },
      'chat': [
        {'id': 1, 'from': 'u2', 'username': 'sam', 'text': 'Ready when you are', 'at': 1},
        {'id': 2, 'from': 'u9', 'username': 'Grumpy_Gus', 'text': 'you lot are ****', 'at': 2},
      ],
    });
  await _wait(tester);
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

void main() {
  setUpAll(loadShotFonts);

  for (final width in [412.0, 360.0]) {
    final w = width.toInt();

    testWidgets('lobby with a blocked smith and the player menu, $w', (tester) async {
      final (room, router) = await _pump(tester, width);
      await _enterRoom(tester, room, router);
      await _shot('safety_lobby_$w');
      await tester.tap(find.byTooltip('Mute, block or report').first);
      await _wait(tester);
      await _shot('safety_actions_$w');
      await tester.tap(find.text('Report sam'));
      await _wait(tester);
      await tester.tap(find.text('Bullying or harassment'));
      await _wait(tester);
      await _shot('safety_report_$w');
    });

    testWidgets('chat rules, $w', (tester) async {
      final (room, router) = await _pump(tester, width, rulesSeen: false);
      await _enterRoom(tester, room, router);
      await tester.tap(find.byType(ChatButton));
      await _wait(tester);
      await _shot('safety_chat_rules_$w');
    });

    testWidgets('blocked smiths, $w', (tester) async {
      await _pump(tester, width, location: '/blocked');
      await _shot('safety_blocked_$w');
    });

    testWidgets('delete account on the web, $w', (tester) async {
      await _pump(tester, width, location: '/delete-account');
      await _shot('safety_delete_$w');
    });
  }
}
