// Renders the friends screen, nicknames, the add-friend box and changing your
// username to PNGs with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots/friends_shots_test.dart --update-goldens
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:wordsmith/net/hub_client.dart';
import 'package:wordsmith/net/room_client.dart';

import '../test/fixtures/fake_backend.dart';
import '../test/fixtures/fake_socket.dart';

import 'shot_fonts.dart';

FakeServer _server() {
  final server = FakeServer()
    ..username = 'Ali_Smith'
    ..avatar = 'avatar_03'
    ..totalXp = 2600;
  server.friends.addAll([
    {
      'id': 'uid-sam',
      'username': 'sam_hammerhand',
      'avatar': 'avatar_05',
      'level': 12,
      'rank': 'Journeyman',
      'nickname': 'Big Sam',
    },
    {'id': 'uid-kit', 'username': 'Kit', 'avatar': 'avatar_09', 'level': 7, 'rank': 'Apprentice'},
    {
      'id': 'uid-wren',
      'username': 'wren_99',
      'avatar': 'avatar_12',
      'level': 21,
      'rank': 'Master',
      'nickname': 'Auntie W',
    },
    {'id': 'uid-bo', 'username': 'Bo', 'avatar': 'avatar_14', 'level': 3, 'rank': 'Apprentice'},
  ]);
  server.incoming.add({
    'id': 'uid-rin',
    'username': 'Rin_Ember',
    'avatar': 'avatar_07',
    'level': 5,
    'rank': 'Apprentice',
  });
  return server;
}

/// The hub client of the app being shot, stopped by [_shot] so no timers are left.
HubClient? _hub;

/// The whole app at [location], signed in, with a hub that says who's online.
Future<GoRouter> _pump(WidgetTester tester, FakeServer server, String location, {FakeSocketChannel? room}) async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'uid-ali', 'totalXp': 2600, 'campaignStage': 40}),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  final auth = FakeAuth(
    signedIn: const AuthUser(uid: 'uid-ali', email: 'ali@example.com'),
  );
  final hub = FakeSocketChannel();
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(await tester.runAsync(Campaign.load) ?? (throw StateError('no campaign'))),
      authServiceProvider.overrideWithValue(auth),
      apiClientProvider.overrideWithValue(server.client(auth)),
      hubClientProvider.overrideWithValue(
        _hub = HubClient(baseUrl: 'http://forge.test', token: auth.idToken, connect: (_, _) => hub),
      ),
      if (room != null)
        roomClientFactoryProvider.overrideWithValue(
          (code) => RoomClient(baseUrl: 'http://forge.test', code: code, token: auth.idToken, connect: (_, _) => room),
        ),
    ],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(initialLocation: location, routes: appRouter.configuration.routes);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(router: router),
    ),
  );
  await _wait(tester);
  hub
    ..receive({'op': 'PRESENCE', 'userId': 'uid-sam', 'status': 'in_room:K7Q2AB'})
    ..receive({'op': 'PRESENCE', 'userId': 'uid-wren', 'status': 'online'})
    ..receive({'op': 'PRESENCE', 'userId': 'uid-kit', 'status': 'solo'});
  await _wait(tester);
  return router;
}

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

/// Closes the app, so its sockets stop their keep-alive timers.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _hub?.stop();
  await tester.pump();
}

void main() {
  setUpAll(loadShotFonts);

  testWidgets('friends with nicknames', (tester) async {
    await _pump(tester, _server(), '/friends');
    await _shot('friends_nicknames');
    await _close(tester);
  });

  testWidgets('friends leaderboard with nicknames', (tester) async {
    await _pump(tester, _server(), '/friends');
    await tester.tap(find.text('Leaderboard'));
    await _wait(tester);
    await _shot('friends_leaderboard');
    await _close(tester);
  });

  testWidgets('friend menu', (tester) async {
    await _pump(tester, _server(), '/friends');
    await tester.tap(find.byTooltip('More').first);
    await _wait(tester);
    await _shot('friends_menu');
    await _close(tester);
  });

  testWidgets('nickname editor', (tester) async {
    await _pump(tester, _server(), '/friends');
    await tester.tap(find.text('Kit'));
    await _wait(tester);
    await tester.enterText(find.byKey(const ValueKey('nickname')), 'Kit the Quick');
    await _wait(tester);
    await _shot('friends_nickname_editor');
    await _close(tester);
  });

  testWidgets('add friend box, empty and typing', (tester) async {
    final server = _server();
    server.friends.clear();
    server.incoming.clear();
    await _pump(tester, server, '/friends');
    await _shot('friends_add_box');
    await tester.tap(find.byKey(const ValueKey('add-friend')));
    await tester.enterText(find.byKey(const ValueKey('add-friend')), 'sam_hammerhand');
    await _wait(tester);
    await _shot('friends_add_box_focused');
    await _close(tester);
  });

  testWidgets('change username', (tester) async {
    await _pump(tester, _server(), '/profile');
    await tester.scrollUntilVisible(find.text('Change username'), 300, scrollable: find.byType(Scrollable).first);
    await _wait(tester);
    await _shot('profile_account');
    await tester.tap(find.text('Change username'));
    await _wait(tester);
    await tester.enterText(find.byKey(const ValueKey('new-username')), 'taken');
    await tester.tap(find.text('Change name'));
    await _wait(tester);
    await _shot('change_username_error');
    await _close(tester);
  });

  testWidgets('lobby with a nickname', (tester) async {
    final server = _server();
    server.rooms['K7Q2AB'] = {
      'code': 'K7Q2AB',
      'mode': 'coop',
      'phase': 'lobby',
      'players': 3,
      'maxPlayers': 4,
      'seated': true,
    };
    final room = FakeSocketChannel();
    final router = await _pump(tester, server, '/', room: room);
    unawaited(router.push('/room/K7Q2AB?mode=coop'));
    await _wait(tester);
    room
      ..receive({'op': 'WELCOME', 'you': 'uid-ali', 'protocol': 1, 'serverNow': DateTime.now().millisecondsSinceEpoch})
      ..receive({
        'op': 'LOBBY',
        'code': 'K7Q2AB',
        'mode': 'coop',
        'phase': 'lobby',
        'hostId': 'uid-sam',
        'heat': 3,
        'players': [
          for (final (i, (id, name, avatar, level)) in [
            ('uid-sam', 'sam_hammerhand', 'avatar_05', 12),
            ('uid-ali', 'Ali_Smith', 'avatar_03', 9),
            ('uid-kit', 'Kit', 'avatar_09', 7),
          ].indexed)
            {
              'id': id,
              'username': name,
              'avatar': avatar,
              'level': level,
              'color': i,
              'ready': i != 2,
              'connected': true,
            },
        ],
      });
    await _wait(tester);
    await _shot('lobby_nickname');
    await _close(tester);
  });
}
