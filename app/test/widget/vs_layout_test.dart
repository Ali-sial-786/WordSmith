import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/coop/lobby_view.dart';
import 'package:wordsmith/features/coop/room_video.dart';
import 'package:wordsmith/features/vs/vs_results_view.dart';
import 'package:wordsmith/features/vs/vs_round_view.dart';
import 'package:wordsmith/features/vs/vs_standings_view.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/video/video_call.dart';

import '../fixtures/fake_video.dart';

const _names = ['Ada', 'sam', 'Kit_the_Smith', 'Bo', 'Wren'];

RoomLobby _lobby(String phase) => RoomLobby.fromJson({
  'code': 'V5X7KQ',
  'mode': 'vs',
  'phase': phase,
  'hostId': 'u1',
  'heat': 3,
  'series': 5,
  'players': [
    for (var i = 1; i <= 5; i++)
      {
        'id': 'u$i',
        'username': _names[i - 1],
        'avatar': 'avatar_0$i',
        'level': 3 * i,
        'color': i - 1,
        'ready': true,
        'connected': i != 5,
      },
  ],
});

RoundStart _start({bool sudden = false}) => RoundStart.fromJson({
  'round': 3,
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
  'series': 5,
  'regular': sudden ? null : 3,
  'suddenDeath': sudden,
  'players': sudden ? ['u2', 'u3'] : ['u1', 'u2', 'u3', 'u4', 'u5'],
  'tally': {'u1': 1, 'u2': 1, 'u3': 0, 'u4': 0, 'u5': 0},
});

final _end = VsRoundEnd.fromJson({
  'reason': 'timeout',
  'winner': 'u3',
  'how': 'timeout',
  'progress': [
    for (var i = 1; i <= 5; i++) {'id': 'u$i', 'filled': i, 'total': 7},
  ],
  'tally': {'u1': 1, 'u2': 1, 'u3': 1, 'u4': 0, 'u5': 0},
  'answers': [
    {'slot': 0, 'word': 'CAT'},
    {'slot': 1, 'word': 'COT'},
    {'slot': 2, 'word': 'TOE'},
  ],
  'next': {'round': 4, 'suddenDeath': false, 'players': ['u1', 'u2', 'u3', 'u4']},
  'standingsEndsAt': DateTime.now().millisecondsSinceEpoch + 8000,
});

final _seriesEnd = SeriesEnd.fromJson({
  'winner': 'u1',
  'early': true,
  'forfeit': false,
  'rounds': 4,
  'podium': [
    {'id': 'u1', 'username': 'Ada', 'wins': 3, 'place': 1},
    {'id': 'u3', 'username': 'Kit_the_Smith', 'wins': 1, 'place': 2},
    {'id': 'u2', 'username': 'sam', 'wins': 0, 'place': 3},
    {'id': 'u4', 'username': 'Bo', 'wins': 0, 'place': 3},
    {'id': 'u5', 'username': 'Wren', 'wins': 0, 'place': 3},
  ],
  'xp': {
    'u1': {
      'xp': 70,
      'level': 4,
      'levelUps': 1,
      'rewards': {'hammer': 1},
      'scrapHammers': 1,
      'pickups': {'chisel': 1},
    },
  },
});

VsSession _session(String phase) {
  final s = VsSession(client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'), me: 'u1')
    ..lobby = _lobby(phase);
  addTearDown(s.dispose);
  return s;
}

Future<FakeVideoCall> _call() async {
  final call = FakeVideoCall();
  await call.join(url: 'wss://x', token: 't', camera: true, mic: true);
  call.peers = {for (var i = 1; i <= 4; i++) 'u$i': VideoPeer(id: 'u$i', camera: true, mic: i.isOdd)};
  return call;
}

RoomVideo _video(VideoCall? call) =>
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
      child: MaterialApp(home: Scaffold(body: SafeArea(child: child))),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the Versus lobby fits five smiths and the series picker', (tester) async {
    await _pump(tester, LobbyView(session: _session('lobby'), onLeave: () {}, video: _video(null)));
    expect(tester.takeException(), isNull);
    expect(find.text('Anvil Clash'), findsOneWidget);
    expect(find.text('Smiths 5/5'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
  });

  for (final withVideo in [false, true]) {
    testWidgets('a Versus round fits four rivals on a small phone${withVideo ? ' with video' : ''}', (tester) async {
      final start = _start();
      final s = _session('round')
        ..round = start
        ..mold = RemoteMold(start, () => _lobby('round'))
        ..tally = start.tally
        ..progress = {for (var i = 1; i <= 5; i++) 'u$i': RacerProgress('u$i', i, 7)};
      final call = withVideo ? await _call() : null;
      await _pump(tester, VsRoundView(session: s, cues: MoldCues(), onLeave: () {}, video: _video(call)));
      expect(tester.takeException(), isNull);
      expect(find.text('Round 3 of up to 5'), findsOneWidget);
      expect(find.text('1/7'), findsNothing, reason: 'my count comes from my own mold');
      expect(find.text('0/7'), findsOneWidget);
    });
  }

  testWidgets('someone sitting out sudden death watches the racers', (tester) async {
    final start = _start(sudden: true);
    final s = _session('round')
      ..round = start
      ..mold = RemoteMold(start, () => _lobby('round'));
    await _pump(tester, VsRoundView(session: s, cues: MoldCues(), onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('Sudden death!'), findsOneWidget);
    expect(find.textContaining("You're watching"), findsOneWidget);
  });

  testWidgets('the standings between rounds fit and say what comes next', (tester) async {
    final start = _start();
    final s = _session('standings')
      ..round = start
      ..mold = RemoteMold(start, () => _lobby('standings'))
      ..standings = _end
      ..tally = _end.tally;
    await _pump(tester, VsStandingsView(session: s, cues: MoldCues(), onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('Kit_the_Smith wins on time'), findsOneWidget);
    expect(find.text('Round 4 of up to 5'), findsOneWidget);
  });

  testWidgets('the podium fits five smiths', (tester) async {
    final s = _session('results')..seriesEnd = _seriesEnd;
    await _pump(tester, VsResultsView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('YOU WIN THE SERIES!'), findsOneWidget);
    expect(find.text('Embers: +1 Chisel'), findsOneWidget);
    expect(find.text('Rematch'), findsOneWidget);
  });
}
