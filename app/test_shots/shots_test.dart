// Renders key multiplayer screens to PNGs with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/auth/auth_service.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/masterworks.dart';
import 'package:wordsmith/game/daily_game.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/features/coop/lobby_view.dart';
import 'package:wordsmith/features/coop/room_video.dart';
import 'package:wordsmith/features/coop/round_view.dart';
import 'package:wordsmith/game/coop_session.dart';
import 'package:wordsmith/features/vs/vs_results_view.dart';
import 'package:wordsmith/features/vs/vs_round_view.dart';
import 'package:wordsmith/features/vs/vs_standings_view.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/meaning_sheet.dart';
import 'package:wordsmith/ui/widgets/forge_background.dart';
import 'package:wordsmith/video/video_call.dart';

import '../test/fixtures/fake_backend.dart';
import '../test/fixtures/fake_video.dart';
import '../test/fixtures/puzzles.dart';

const _names = ['Ada', 'sam', 'Kit', 'Bo', 'Wren'];

RoomLobby _lobby(String phase, {int players = 4}) => RoomLobby.fromJson({
  'code': 'V5X7KQ',
  'mode': 'vs',
  'phase': phase,
  'hostId': 'u1',
  'heat': 3,
  'series': 5,
  'players': [
    for (var i = 1; i <= players; i++)
      {
        'id': 'u$i',
        'username': _names[i - 1],
        'avatar': 'avatar_${(i * 3 % 16 + 1).toString().padLeft(2, '0')}',
        'level': 3 * i + 2,
        'color': i - 1,
        'ready': i != 3,
        'connected': true,
      },
  ],
});

final _slots = [
  {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 5},
  {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 4},
  {'slot': 2, 'x': 4, 'y': 0, 'd': 'd', 'len': 5},
  {'slot': 3, 'x': 0, 'y': 3, 'd': 'a', 'len': 3},
  {'slot': 4, 'x': 2, 'y': 2, 'd': 'a', 'len': 3},
];

RoundStart _start() => RoundStart.fromJson(_startJson());

Map<String, dynamic> _startJson() => {
  'round': 3,
  'heat': 3,
  'startsAt': 0,
  'endsAt': DateTime.now().millisecondsSinceEpoch + 71000,
  'serverNow': DateTime.now().millisecondsSinceEpoch,
  'letters': 'STONEA',
  'cols': 5,
  'rows': 5,
  'slots': _slots,
  'pickups': [],
  'series': 5,
  'regular': 3,
  'suddenDeath': false,
  'players': ['u1', 'u2', 'u3', 'u4'],
  'tally': {'u1': 1, 'u2': 1, 'u3': 0, 'u4': 0},
};

VsSession _session(String phase, {int players = 4}) => VsSession(
  client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'),
  me: 'u1',
)..lobby = _lobby(phase, players: players);

/// The fake call, with something like a camera picture in each bubble.
class _ShotVideoCall extends FakeVideoCall {
  _ShotVideoCall() : super(me: 'u1');

  static const _hues = [20.0, 205.0, 140.0, 275.0, 45.0];

  @override
  Widget? view(String userId) {
    if (!(peers[userId]?.camera ?? false)) return null;
    final hue = _hues[(int.tryParse(userId.substring(1)) ?? 1) % _hues.length];
    return DecoratedBox(
      key: ValueKey('video-$userId'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [HSLColor.fromAHSL(1, hue, 0.3, 0.55).toColor(), HSLColor.fromAHSL(1, hue, 0.3, 0.22).toColor()],
        ),
      ),
      child: const FittedBox(child: Icon(Icons.face, color: Color(0xDDF0CFB0))),
    );
  }
}

/// Video chat on: everyone's camera except [cameraOff]; [muted] and [speaking]
/// show their badges. My own camera and mic follow [mine].
Future<RoomVideo> _video({
  int players = 4,
  bool mine = true,
  Set<String> cameraOff = const {},
  Set<String> muted = const {},
  Set<String> speaking = const {},
}) async {
  final call = _ShotVideoCall();
  await call.join(url: 'wss://x', token: 't', camera: mine, mic: mine);
  call.peers = {
    for (var i = 2; i <= players; i++)
      'u$i': VideoPeer(
        id: 'u$i',
        camera: !cameraOff.contains('u$i'),
        mic: !muted.contains('u$i'),
        speaking: speaking.contains('u$i'),
      ),
  };
  return RoomVideo(available: true, call: call, onEnable: () {}, onDisable: () {}, onCamera: () {}, onMic: () {});
}

/// Four smiths in a co-op room.
RoomLobby _coopLobby(String phase) => RoomLobby.fromJson({
  ...{'code': 'K7Q2AB', 'mode': 'coop', 'phase': phase, 'hostId': 'u1', 'heat': 3},
  'players': [
    for (var i = 1; i <= 4; i++)
      {
        'id': 'u$i',
        'username': _names[i - 1],
        'avatar': 'avatar_0${i + 2}',
        'level': 5 + i,
        'color': i - 1,
        'ready': true,
        'connected': true,
      },
  ],
});

CoopSession _coop(String phase) => CoopSession(
  client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't'),
  me: 'u1',
)..lobby = _coopLobby(phase);

/// Four smiths forging together, a few words in.
CoopSession _coopRound({Map<String, int> scores = const {'u1': 50, 'u2': 30, 'u3': 0, 'u4': 20}}) {
  final s = _coop('round');
  final lobby = s.lobby!;
  final start = RoundStart.fromJson({..._startJson(), 'players': null});
  s
    ..round = start
    ..mold = RemoteMold(start, () => lobby)
    ..scores = {...scores};
  s.mold!.claim(0, 'STONE', 'u1');
  s.mold!.claim(1, 'SEAT', 'u2');
  s.mold!.claim(3, 'TON', 'u4');
  s.feed.add(const FeedLine('sam forged SEAT  +30', Color(0xFFE1B53B)));
  return s;
}

/// A small phone, for the tightest video layouts.
const _small = Size(360, 740);

Future<void> _font(String family, Future<ByteData> data) async {
  final loader = FontLoader(family)..addFont(data);
  await loader.load();
}

Future<void> _shoot(WidgetTester tester, String name, Widget child, {Size size = const Size(412, 892)}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(size);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWithValue(store)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: Scaffold(
          body: ForgeBackground(
            image: 'assets/images/bg_hall.webp',
            dim: 0.6,
            fire: 0.0,
            child: SafeArea(child: child),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
  await tester.pump(const Duration(milliseconds: 1200));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pump(const Duration(milliseconds: 100));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await _font('Cinzel', rootBundle.load('assets/fonts/Cinzel-Variable.ttf'));
    await _font('RobotoSlab', rootBundle.load('assets/fonts/RobotoSlab-Variable.ttf'));
    await _font('NunitoSans', rootBundle.load('assets/fonts/NunitoSans-Variable.ttf'));
    final icons = File('/opt/sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
        .readAsBytesSync();
    await _font('MaterialIcons', Future.value(ByteData.view(icons.buffer)));
  });

  testWidgets('vs lobby', (tester) async {
    await _shoot(tester, 'vs_lobby', LobbyView(session: _session('lobby'), onLeave: () {}));
  });

  testWidgets('vs round', (tester) async {
    final start = _start();
    final s = _session('round')
      ..round = start
      ..mold = RemoteMold(start, () => _lobby('round'))
      ..tally = start.tally
      ..progress = {
        'u1': RacerProgress('u1', 8, 17),
        'u2': RacerProgress('u2', 13, 17),
        'u3': RacerProgress('u3', 5, 17),
        'u4': RacerProgress('u4', 10, 17),
      };
    s.mold!.claim(0, 'STONE', 'u1');
    s.mold!.claim(1, 'SEAT', 'u1');
    s.feed.add(const FeedLine('sam is nearly done!', Color(0xFFE1B53B)));
    await _shoot(tester, 'vs_round', VsRoundView(session: s, cues: MoldCues(), onLeave: () {}));
  });

  testWidgets('vs lobby video, my camera off', (tester) async {
    final video = await _video(players: 5, mine: false, cameraOff: {'u4'}, muted: {'u3'});
    await _shoot(
      tester,
      'vs_lobby_video_camera_off',
      LobbyView(session: _session('lobby', players: 5), onLeave: () {}, video: video),
      size: _small,
    );
  });

  for (final mine in [true, false]) {
    testWidgets('vs round video${mine ? '' : ', my camera off'}', (tester) async {
      final start = RoundStart.fromJson({
        ..._startJson(),
        'players': ['u1', 'u2', 'u3', 'u4', 'u5'],
      });
      final s = _session('round', players: 5)
        ..round = start
        ..mold = RemoteMold(start, () => _lobby('round', players: 5))
        ..tally = start.tally
        ..progress = {
          'u1': RacerProgress('u1', 8, 17),
          'u2': RacerProgress('u2', 13, 17),
          'u3': RacerProgress('u3', 5, 17),
          'u4': RacerProgress('u4', 10, 17),
          'u5': RacerProgress('u5', 2, 17),
        };
      s.mold!.claim(0, 'STONE', 'u1');
      s.mold!.claim(1, 'SEAT', 'u1');
      s.feed.add(const FeedLine('sam is nearly done!', Color(0xFFE1B53B)));
      final video = await _video(players: 5, mine: mine, cameraOff: {'u4'}, muted: {'u3'}, speaking: {'u2'});
      await _shoot(
        tester,
        'vs_round_video${mine ? '' : '_camera_off'}',
        VsRoundView(session: s, cues: MoldCues(), onLeave: () {}, video: video),
        size: _small,
      );
    });
  }

  testWidgets('vs watching video', (tester) async {
    final start = RoundStart.fromJson({
      ..._startJson(),
      'regular': null,
      'suddenDeath': true,
      'players': ['u2', 'u3'],
    });
    final s = _session('round', players: 5)
      ..round = start
      ..mold = RemoteMold(start, () => _lobby('round', players: 5))
      ..tally = start.tally
      ..progress = {'u2': RacerProgress('u2', 9, 17), 'u3': RacerProgress('u3', 6, 17)};
    final video = await _video(players: 5, cameraOff: {'u3'});
    await _shoot(
      tester,
      'vs_watching_video',
      VsRoundView(session: s, cues: MoldCues(), onLeave: () {}, video: video),
      size: _small,
    );
  });

  testWidgets('vs standings', (tester) async {
    final start = _start();
    final end = VsRoundEnd.fromJson({
      'reason': 'finished',
      'winner': 'u2',
      'how': 'finished',
      'progress': [
        {'id': 'u1', 'filled': 12, 'total': 17},
        {'id': 'u2', 'filled': 17, 'total': 17},
        {'id': 'u3', 'filled': 6, 'total': 17},
        {'id': 'u4', 'filled': 11, 'total': 17},
      ],
      'tally': {'u1': 1, 'u2': 2, 'u3': 0, 'u4': 0},
      'answers': [
        {'slot': 0, 'word': 'STONE'},
        {'slot': 1, 'word': 'SEAT'},
        {'slot': 2, 'word': 'EATEN'},
        {'slot': 3, 'word': 'TON'},
        {'slot': 4, 'word': 'ONE'},
      ],
      'next': {
        'round': 4,
        'suddenDeath': false,
        'players': ['u1', 'u2', 'u3', 'u4'],
      },
      'standingsEndsAt': DateTime.now().millisecondsSinceEpoch + 7000,
    });
    final s = _session('standings')
      ..round = start
      ..mold = RemoteMold(start, () => _lobby('standings'))
      ..standings = end
      ..tally = end.tally;
    s.mold!.claim(0, 'STONE', 'u1');
    s.mold!.showAnswers(end.answers);
    await _shoot(tester, 'vs_standings', VsStandingsView(session: s, cues: MoldCues(), onLeave: () {}));
  });

  testWidgets('vs podium', (tester) async {
    final s = _session('results')
      ..seriesEnd = SeriesEnd.fromJson({
        'winner': 'u1',
        'early': true,
        'forfeit': false,
        'rounds': 4,
        'podium': [
          {'id': 'u1', 'username': 'Ada', 'wins': 3, 'place': 1},
          {'id': 'u2', 'username': 'sam', 'wins': 1, 'place': 2},
          {'id': 'u4', 'username': 'Bo', 'wins': 0, 'place': 3},
          {'id': 'u3', 'username': 'Kit', 'wins': 0, 'place': 3},
        ],
        'xp': {
          'u1': {
            'xp': 70,
            'level': 6,
            'levelUps': 1,
            'rewards': {'hammer': 1},
            'scrapHammers': 1,
            'pickups': {'chisel': 1},
          },
        },
      });
    await _shoot(tester, 'vs_podium', VsResultsView(session: s, onLeave: () {}));
  });

  for (final location in [
    '/',
    '/daily',
    '/chapters',
    '/profile',
    '/settings',
    '/board',
    '/armory',
    '/daily/calendar',
    '/lore',
    '/chapters/copper',
  ]) {
    testWidgets('hall signed in $location', (tester) async {
      SharedPreferences.setMockInitialValues({
        'profile.v1': jsonEncode({'userId': 'abc', 'totalXp': 2600, 'campaignStage': 132, 'masterworkPieces': 16}),
        'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
      });
      final store = await Store.open();
      final auth = FakeAuth(
        signedIn: const AuthUser(uid: 'uid-ali', email: 'ali@example.com'),
      );
      final server = FakeServer()
        ..username = 'Ali_Smith'
        ..avatar = 'avatar_03'
        ..totalXp = 2600
        ..completed = 131
        ..dailyPuzzle = (tearJson()..['id'] = 'daily-2026-10-17')
        ..dailyStreak = 4
        ..masterworkPieces = 16
        ..stokeDay = 3
        ..stokeClaimed = location != '/board'
        ..lastWeek = {
          'week': '2026-W41',
          'place': 2,
          'of': 3,
          'reward': FakeServer.reward(50, {'chisel': 1}),
        };
      final now = DateTime.now().toUtc();
      for (final d in [1, 2, 4, 5, 6, 8, 9, 10]) {
        if (d < now.day) server.dailyDays.add(todayUtc(DateTime.utc(now.year, now.month, d)));
      }
      server.friends.addAll([
        {'id': 'uid-sam', 'username': 'sam', 'avatar': 'avatar_05', 'level': 12, 'rank': 'Journeyman'},
        {'id': 'uid-kit', 'username': 'Kit', 'avatar': 'avatar_09', 'level': 7, 'rank': 'Apprentice'},
      ]);
      server.giftsPending.add({
        'id': 1,
        'from': {'id': 'uid-sam', 'username': 'sam', 'avatar': 'avatar_05'},
        'sentAt': 0,
      });
      server.giftsSent.add('uid-kit');
      final container = ProviderContainer(
        overrides: [
          storeProvider.overrideWithValue(store),
          campaignProvider.overrideWithValue(await tester.runAsync(Campaign.load) ?? (throw StateError('no campaign'))),
          authServiceProvider.overrideWithValue(auth),
          apiClientProvider.overrideWithValue(server.client(auth)),
        ],
      );
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(412, 892));
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: WordsmithApp(
            router: GoRouter(initialLocation: location, routes: appRouter.configuration.routes),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pump(const Duration(milliseconds: 500));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/hall${location.replaceAll('/', '_')}.png'));
    });
  }

  testWidgets('coop round', (tester) async {
    await _shoot(tester, 'coop_round', RoundView(session: _coopRound(), cues: MoldCues(), onLeave: () {}));
  });

  testWidgets('coop round video', (tester) async {
    final s = _coopRound(scores: {'u1': 120, 'u2': 245, 'u3': 85, 'u4': 160});
    final video = await _video(cameraOff: {'u4'}, muted: {'u2'}, speaking: {'u2'});
    await _shoot(
      tester,
      'coop_round_video',
      RoundView(session: s, cues: MoldCues(), onLeave: () {}, video: video),
      size: _small,
    );
  });

  testWidgets('coop round video, my camera off', (tester) async {
    final s = _coopRound(scores: {'u1': 120, 'u2': 245, 'u3': 85, 'u4': 160});
    final video = await _video(mine: false, cameraOff: {'u4'});
    await _shoot(
      tester,
      'coop_round_video_camera_off',
      RoundView(session: s, cues: MoldCues(), onLeave: () {}, video: video),
      size: _small,
    );
  });

  testWidgets('coop lobby video', (tester) async {
    await _shoot(
      tester,
      'coop_lobby_video',
      LobbyView(
        session: _coop('lobby'),
        onLeave: () {},
        video: await _video(cameraOff: {'u3'}),
      ),
      size: _small,
    );
  });

  for (final chapter in ['silver', 'starmetal', 'gold', 'damascus']) {
    testWidgets('puzzle in $chapter', (tester) async {
      SharedPreferences.setMockInitialValues({
        'profile.v1': jsonEncode({'userId': 'abc', 'totalXp': 900, 'campaignStage': 1}),
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
                {'id': chapter, 'name': chapter[0].toUpperCase() + chapter.substring(1), 'first': 1, 'count': 70},
              ],
              'puzzles': [tearJson()],
            }),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(412, 892));
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: WordsmithApp(
            router: GoRouter(initialLocation: '/play/1', routes: appRouter.configuration.routes),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pump(const Duration(milliseconds: 500));
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/puzzle_$chapter.png'));
    });
  }

  testWidgets('meaning sheet', (tester) async {
    await _shoot(tester, 'meaning', const MeaningView(word: 'TEMPER'));
  });

  testWidgets('puzzle with a gilded cell', (tester) async {
    // A player whose first puzzle hides a gilded cell.
    var user = 0;
    while (gildedCellFor(userId: 'u$user', puzzleId: 'c-0001', cellCount: 9, pickups: const []) == null) {
      user++;
    }
    SharedPreferences.setMockInitialValues({
      'profile.v1': jsonEncode({'userId': 'u$user', 'totalXp': 900, 'campaignStage': 1}),
      'settings.v1': jsonEncode({'reducedMotion': false, 'haptics': false}),
    });
    final store = await Store.open();
    final container = ProviderContainer(
      overrides: [
        storeProvider.overrideWithValue(store),
        campaignProvider.overrideWithValue(
          Campaign.fromJson({
            'version': 1,
            'chapters': [
              {'id': 'copper', 'name': 'Copper', 'first': 1, 'count': 50},
            ],
            'puzzles': [tearJson()],
          }),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.binding.setSurfaceSize(const Size(412, 892));
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: WordsmithApp(
          router: GoRouter(initialLocation: '/play/1', routes: appRouter.configuration.routes),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 500));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/puzzle_gilded.png'));
    await tester.pump(const Duration(seconds: 5));
  });
}
