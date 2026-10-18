// Renders room chat to PNGs with the real fonts, for eyeballing: a line
// popping up over the lobby, the chat open, and the chat button in a co-op
// and a Versus round, at 412 and 360 wide.
// Not part of the suite: flutter test test_shots/chat_shots_test.dart --update-goldens
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
const _names = ['Ali', 'sam', 'Kit_the_Smith', 'Bo'];

Map<String, Object?> _lobby(String mode, String phase) => {
  'code': 'K7Q2AB',
  'mode': mode,
  'phase': phase,
  'hostId': 'u2',
  'heat': 3,
  'series': 5,
  'players': [
    for (var i = 1; i <= 4; i++)
      {
        'id': 'u$i',
        'username': _names[i - 1],
        'avatar': 'avatar_0${i + 1}',
        'level': 4 * i,
        'color': i - 1,
        'ready': i != 3,
        'connected': true,
      },
  ],
};

Map<String, Object?> _line(int id, String from, String text) => {
  'id': id,
  'from': from,
  'username': _names[int.parse(from.substring(1)) - 1],
  'text': text,
  'at': id,
};

final _chat = [
  _line(1, 'u2', 'Welcome to the forge! Ready when you are'),
  _line(2, 'u1', 'Two minutes, getting a drink'),
  _line(3, 'u3', 'Can we do White Heat this time? 🔥🔥'),
  _line(4, 'u4', 'gg last round, that last word was brutal'),
  _line(5, 'u2', 'Starting once Kit is ready'),
];

Map<String, Object?> _roundStart(String mode) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'op': 'ROUND_START',
    'round': 2,
    'heat': 3,
    'startsAt': now - 1000,
    'endsAt': now + 75000,
    'serverNow': now,
    'letters': 'CATOE',
    'cols': 3,
    'rows': 3,
    'slots': [
      {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 3},
      {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 3},
      {'slot': 2, 'x': 2, 'y': 0, 'd': 'd', 'len': 3},
    ],
    'pickups': [],
    if (mode == 'vs') ...{
      'series': 5,
      'regular': 2,
      'suddenDeath': false,
      'players': ['u1', 'u2', 'u3', 'u4'],
      'tally': {'u1': 1, 'u2': 0, 'u3': 0, 'u4': 0},
    },
  };
}

Future<FakeSocketChannel> _room(WidgetTester tester, double width, String mode) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false, 'roomChat': false}),
  });
  final store = await Store.open();
  final auth = FakeAuth(signedIn: _me);
  final server = FakeServer()..username = 'Ali';
  server.rooms['K7Q2AB'] = {
    'code': 'K7Q2AB',
    'mode': mode,
    'phase': 'lobby',
    'players': 4,
    'maxPlayers': mode == 'vs' ? 5 : 4,
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
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: '/room/K7Q2AB?mode=$mode', routes: appRouter.configuration.routes),
      ),
    ),
  );
  await _wait(tester);
  room
    ..receive({'op': 'WELCOME', 'you': 'u1', 'protocol': 1, 'serverNow': DateTime.now().millisecondsSinceEpoch})
    ..receive({'op': 'SNAPSHOT', 'lobby': _lobby(mode, 'lobby'), 'chat': _chat});
  await _wait(tester);
  return room;
}

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

void main() {
  setUpAll(loadShotFonts);

  for (final width in [412.0, 360.0]) {
    final w = width.toInt();

    testWidgets('chat toast over the lobby, $w', (tester) async {
      final room = await _room(tester, width, 'coop');
      room
        ..receive({'op': 'CHAT', ..._line(6, 'u3', 'Ready! Sorry, my cat sat on the phone')})
        ..receive({'op': 'CHAT', ..._line(7, 'u2', "Right, let's forge something")});
      await _wait(tester);
      await _shot('chat_lobby_toast_$w');
    });

    testWidgets('chat open, $w', (tester) async {
      await _room(tester, width, 'coop');
      await tester.tap(find.byType(ChatButton));
      await _wait(tester);
      await _shot('chat_sheet_$w');
      await tester.longPress(find.text('gg last round, that last word was brutal'));
      await _wait(tester);
      await tester.tap(find.text('Mute'));
      await _wait(tester);
      await _shot('chat_sheet_muted_$w');
    });

    for (final mode in ['coop', 'vs']) {
      testWidgets('chat button in a $mode round, $w', (tester) async {
        final room = await _room(tester, width, mode);
        room
          ..receive(_roundStart(mode))
          ..receive({'op': 'LOBBY', ..._lobby(mode, 'round')})
          ..receive({'op': 'CHAT', ..._line(6, 'u4', 'This one is hard')});
        await _wait(tester);
        await _shot('chat_round_${mode}_$w');
      });
    }
  }
}
