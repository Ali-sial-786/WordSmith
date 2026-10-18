import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/coop/lobby_view.dart';
import 'package:wordsmith/features/coop/room_video.dart';
import 'package:wordsmith/features/coop/round_view.dart';
import 'package:wordsmith/game/coop_session.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/widgets/video_bubble.dart';
import 'package:wordsmith/video/video_call.dart';

import '../fixtures/fake_video.dart';

/// Four smiths, with video on for three of them.
RoomLobby _lobby(String phase) => RoomLobby.fromJson({
  'code': 'K7Q2AB',
  'mode': 'coop',
  'phase': phase,
  'hostId': 'u1',
  'heat': 3,
  'players': [
    for (var i = 1; i <= 4; i++)
      {
        'id': 'u$i',
        'username': ['Ada', 'sam', 'Kit_the_Smith', 'Bo'][i - 1],
        'avatar': 'avatar_0$i',
        'level': 3 * i,
        'color': i - 1,
        'ready': i.isEven,
        'connected': i != 4,
      },
  ],
});

final _start = RoundStart.fromJson({
  'round': 1,
  'heat': 3,
  'startsAt': 0,
  'endsAt': DateTime.now().millisecondsSinceEpoch + 90000,
  'serverNow': DateTime.now().millisecondsSinceEpoch,
  'letters': 'CATOE',
  'cols': 3,
  'rows': 3,
  'slots': [
    {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 3},
    {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 3},
    {'slot': 2, 'x': 2, 'y': 0, 'd': 'd', 'len': 3},
  ],
  'pickups': [],
});

/// Me (u1) with my [camera] on or off, and two teammates; Bo isn't in the call.
Future<FakeVideoCall> _call({bool camera = true}) async {
  final call = FakeVideoCall(me: 'u1');
  await call.join(url: 'wss://x', token: 't', camera: camera, mic: true);
  call.peers = {
    'u2': const VideoPeer(id: 'u2', camera: true, mic: false, speaking: true),
    'u3': const VideoPeer(id: 'u3', camera: true, mic: true),
  };
  return call;
}

RoomVideo _video(VideoCall call) =>
    RoomVideo(available: true, call: call, onEnable: () {}, onDisable: () {}, onCamera: () {}, onMic: () {});

Future<void> _pump(WidgetTester tester, Widget child) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(const Size(360, 740));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWithValue(store)],
      child: MaterialApp(
        home: Scaffold(body: SafeArea(child: child)),
      ),
    ),
  );
  await tester.pump();
}

/// My own bubble with my camera off: my avatar, marked.
final _myCameraOff = find.descendant(of: find.byType(VideoBubble), matching: find.byIcon(Icons.videocam_off));

CoopSession _session(String phase) {
  final session = CoopSession(
    client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't'),
    me: 'u1',
  )..lobby = _lobby(phase);
  addTearDown(session.dispose);
  return session;
}

void main() {
  testWidgets('the lobby fits four smiths with video bubbles on a small phone', (tester) async {
    final call = await _call();
    await _pump(tester, LobbyView(session: _session('lobby'), onLeave: () {}, video: _video(call)));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('video-u1')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-u3')), findsOneWidget);
    // The voice and video bar is further down the lobby.
    await tester.scrollUntilVisible(find.text('Video chat on'), 100);
    expect(find.text('Video chat on'), findsOneWidget);
    expect(_myCameraOff, findsNothing);
  });

  testWidgets('in the lobby my own bubble stays, marked, with my camera off', (tester) async {
    final call = await _call(camera: false);
    await _pump(tester, LobbyView(session: _session('lobby'), onLeave: () {}, video: _video(call)));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('video-u1')), findsNothing);
    expect(_myCameraOff, findsOneWidget);
    expect(find.byKey(const ValueKey('video-u2')), findsOneWidget);
  });

  testWidgets('the round shows teammates as video bubbles and fits on a small phone', (tester) async {
    final call = await _call();
    final session = _session('round')
      ..round = _start
      ..mold = RemoteMold(_start, () => _lobby('round'));
    await _pump(tester, RoundView(session: session, cues: MoldCues(), onLeave: () {}, video: _video(call)));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('video-u2')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-u1')), findsOneWidget, reason: 'my own bubble too');
    expect(find.text('You'), findsOneWidget);
    expect(find.byTooltip('Turn camera off'), findsOneWidget, reason: 'camera switch in the top strip');
  });

  for (final camera in [true, false]) {
    testWidgets('four smiths with big scores still fit, my camera ${camera ? 'on' : 'off'}', (tester) async {
      final call = await _call(camera: camera);
      final session = _session('round')
        ..round = _start
        ..mold = RemoteMold(_start, () => _lobby('round'))
        ..scores = {'u1': 1240, 'u2': 985, 'u3': 2310, 'u4': 460};
      await _pump(tester, RoundView(session: session, cues: MoldCues(), onLeave: () {}, video: _video(call)));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('video-u1')), camera ? findsOneWidget : findsNothing);
      expect(_myCameraOff, camera ? findsNothing : findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('2310'), findsOneWidget);
    });
  }
}
