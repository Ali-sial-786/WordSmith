// Renders screens in every colour scheme to PNGs with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots/scheme_shots_test.dart --update-goldens
// (one scheme: --plain-name gilded; one screen: --plain-name 'gilded hall')
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
import 'package:wordsmith/data/profile.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/coop/lobby_view.dart';
import 'package:wordsmith/features/coop/round_view.dart';
import 'package:wordsmith/features/settings/scheme_picker.dart';
import 'package:wordsmith/features/vs/vs_results_view.dart';
import 'package:wordsmith/features/vs/vs_round_view.dart';
import 'package:wordsmith/features/vs/vs_standings_view.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/coop_session.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/theme/appearance.dart';
import 'package:wordsmith/ui/theme/palette.dart';
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/forge_background.dart';
import 'package:wordsmith/ui/widgets/meaning_sheet.dart';

import '../test/fixtures/fake_backend.dart';
import '../test/fixtures/puzzles.dart';

import 'shot_fonts.dart';

String _settings(PaletteScheme scheme) =>
    jsonEncode({'reducedMotion': true, 'haptics': false, 'colorScheme': scheme.id});

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

Future<void> _size(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(412, 892));
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The whole app at [location], signed in with a friend and a campaign under way.
Future<void> _app(
  WidgetTester tester,
  PaletteScheme scheme,
  String location, {
  Campaign? campaign,
  bool signedIn = true,
}) async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'abc', 'totalXp': 2600, 'campaignStage': 132, 'masterworkPieces': 16}),
    'settings.v1': _settings(scheme),
  });
  final store = await Store.open();
  final auth = FakeAuth(
    signedIn: signedIn ? const AuthUser(uid: 'uid-ali', email: 'ali@example.com') : null,
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
    ..stokeClaimed = location != '/board';
  server.friends.add({'id': 'uid-sam', 'username': 'sam', 'avatar': 'avatar_05', 'level': 12, 'rank': 'Journeyman'});
  server.giftsPending.add({
    'id': 1,
    'from': {'id': 'uid-sam', 'username': 'sam', 'avatar': 'avatar_05'},
    'sentAt': 0,
  });
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(
        campaign ?? await tester.runAsync(Campaign.load) ?? (throw StateError('no campaign')),
      ),
      authServiceProvider.overrideWithValue(auth),
      apiClientProvider.overrideWithValue(server.client(auth)),
    ],
  );
  addTearDown(container.dispose);
  await _size(tester);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: location, routes: appRouter.configuration.routes),
      ),
    ),
  );
  await _wait(tester);
}

/// Scrolls Settings so the colour swatches start [top] down the screen.
Future<void> _toPicker(WidgetTester tester, double top) async {
  final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  final picker = tester.getTopLeft(find.byType(SchemePicker)).dy;
  position.jumpTo((position.pixels + picker - top).clamp(0, position.maxScrollExtent));
  await _wait(tester);
}

/// [child] in a room screen's background, as the room screen shows its views.
Future<void> _room(WidgetTester tester, PaletteScheme scheme, Widget Function() child) async {
  SharedPreferences.setMockInitialValues({'settings.v1': _settings(scheme)});
  final store = await Store.open();
  applyAppearance(Settings.fromJson(jsonDecode(_settings(scheme)) as Map<String, dynamic>));
  await _size(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWithValue(store)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: Scaffold(
          body: ForgeBackground(
            image: 'assets/images/bg_hall.webp',
            dim: 0.62,
            fire: 0,
            child: SafeArea(child: child()),
          ),
        ),
      ),
    ),
  );
  await _wait(tester);
}

const _slots = [
  {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 5},
  {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 4},
  {'slot': 2, 'x': 4, 'y': 0, 'd': 'd', 'len': 5},
  {'slot': 3, 'x': 0, 'y': 3, 'd': 'a', 'len': 3},
  {'slot': 4, 'x': 2, 'y': 2, 'd': 'a', 'len': 3},
];

const _answers = [
  {'slot': 0, 'word': 'STONE'},
  {'slot': 1, 'word': 'SEAT'},
  {'slot': 2, 'word': 'EATEN'},
  {'slot': 3, 'word': 'TON'},
  {'slot': 4, 'word': 'ONE'},
];

RoomLobby _lobby(String mode, String phase) => RoomLobby.fromJson({
  'code': 'V5X7KQ',
  'mode': mode,
  'phase': phase,
  'hostId': 'u1',
  'heat': 3,
  'series': 5,
  'players': [
    for (final (i, name) in ['Ada', 'sam', 'Kit', 'Bo'].indexed)
      {
        'id': 'u${i + 1}',
        'username': name,
        'avatar': 'avatar_0${i + 2}',
        'level': 3 * i + 5,
        'color': i,
        'ready': i != 2,
        'connected': true,
      },
  ],
});

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

RoundStart _start() => RoundStart.fromJson(_startJson());

RoomClient _client() => RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't');

VsSession _vs(String phase) => VsSession(client: _client(), me: 'u1')..lobby = _lobby('vs', phase);

/// A Versus round three words in.
VsSession _vsRound() {
  final start = _start();
  final s = _vs('round')
    ..round = start
    ..mold = RemoteMold(start, () => _lobby('vs', 'round'))
    ..tally = start.tally
    ..progress = {
      'u1': RacerProgress('u1', 8, 17),
      'u2': RacerProgress('u2', 13, 17),
      'u3': RacerProgress('u3', 5, 17),
      'u4': RacerProgress('u4', 10, 17),
    };
  s.mold!.claim(0, 'STONE', 'u1');
  s.mold!.claim(1, 'SEAT', 'u1');
  s.feed.add(FeedLine('sam is nearly done!', Palette.legible(Palette.player(1))));
  return s;
}

/// sam won round 3 of a Versus series.
VsSession _vsStandings() {
  final start = _start();
  final end = VsRoundEnd.fromJson({
    'round': 3,
    'reason': 'finished',
    'winner': 'u2',
    'how': 'finished',
    'progress': [
      {'id': 'u1', 'filled': 10, 'total': 16},
      {'id': 'u2', 'filled': 16, 'total': 16},
      {'id': 'u3', 'filled': 3, 'total': 16},
      {'id': 'u4', 'filled': 11, 'total': 16},
    ],
    'molds': {
      'u1': [0, 1, 3],
      'u2': [0, 1, 2, 3, 4],
      'u3': [3],
      'u4': [0, 2, 4],
    },
    'tally': {'u1': 1, 'u2': 2, 'u3': 0, 'u4': 0},
    'answers': _answers,
    'next': {
      'round': 4,
      'suddenDeath': false,
      'players': ['u1', 'u2', 'u3', 'u4'],
    },
    'standingsEndsAt': DateTime.now().millisecondsSinceEpoch + 7000,
  });
  final s = _vs('standings')
    ..round = start
    ..mold = RemoteMold(start, () => _lobby('vs', 'standings'))
    ..standings = end
    ..tally = end.tally;
  s.mold!.claim(0, 'STONE', 'u1');
  s.mold!.claim(1, 'SEAT', 'u1');
  s.mold!.claim(3, 'TON', 'u1');
  s.mold!.showAnswers(end.answers);
  return s;
}

/// Ada took the series 3–1.
VsSession _vsPodium() => _vs('results')
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

/// Four smiths forging together, a few words in.
CoopSession _coopRound() {
  final s = CoopSession(client: _client(), me: 'u1')..lobby = _lobby('coop', 'round');
  final start = RoundStart.fromJson({..._startJson(), 'players': null});
  s
    ..round = start
    ..mold = RemoteMold(start, () => s.lobby!)
    ..scores = {'u1': 50, 'u2': 30, 'u3': 0, 'u4': 20};
  s.mold!.claim(0, 'STONE', 'u1');
  s.mold!.claim(1, 'SEAT', 'u2');
  s.mold!.claim(3, 'TON', 'u4');
  s.feed.add(FeedLine('sam forged SEAT  +30', Palette.legible(Palette.player(1))));
  return s;
}

final _copper = Campaign.fromJson({
  'version': 1,
  'chapters': [
    {'id': 'copper', 'name': 'Copper', 'first': 1, 'count': 50},
  ],
  'puzzles': [tearJson()],
});

/// Shots in every scheme: name → how to get there.
final _screens = <String, Future<void> Function(WidgetTester, PaletteScheme)>{
  'hall': (t, s) => _app(t, s, '/'),
  'puzzle': (t, s) => _app(t, s, '/play/1', campaign: _copper),
  // Scrolled to the colour swatches.
  'settings': (t, s) async {
    await _app(t, s, '/settings');
    await _toPicker(t, 140);
  },
  'vs_round': (t, s) => _room(t, s, () => VsRoundView(session: _vsRound(), cues: MoldCues(), onLeave: () {})),
  'chapters': (t, s) => _app(t, s, '/chapters'),
  'chapter_map': (t, s) => _app(t, s, '/chapters/copper'),
  'profile': (t, s) => _app(t, s, '/profile'),
  'board': (t, s) => _app(t, s, '/board'),
  'armory': (t, s) => _app(t, s, '/armory'),
  'daily': (t, s) => _app(t, s, '/daily'),
  'sign_in': (t, s) async {
    await _app(t, s, '/sign-in', signedIn: false);
    await t.enterText(find.byType(TextField).first, 'ali@example.com');
    await _wait(t);
  },
  'room_code': (t, s) async {
    await _app(t, s, '/');
    await t.tap(find.text('Co-op'));
    await _wait(t);
    await t.enterText(find.byType(TextField), 'K7Q2');
    await _wait(t);
  },
  'delete_dialog': (t, s) async {
    await _app(t, s, '/settings');
    await t.scrollUntilVisible(find.text('Delete account'), 300);
    await t.tap(find.text('Delete account'));
    await _wait(t);
    // A password account confirms with its password (Google ones don't).
    if (find.byType(TextField).evaluate().isNotEmpty) {
      await t.enterText(find.byType(TextField).last, 'hunter2');
      await _wait(t);
    }
  },
  'vs_lobby': (t, s) => _room(t, s, () => LobbyView(session: _vs('lobby'), onLeave: () {})),
  'vs_standings': (t, s) =>
      _room(t, s, () => VsStandingsView(session: _vsStandings(), cues: MoldCues(), onLeave: () {})),
  'vs_podium': (t, s) => _room(t, s, () => VsResultsView(session: _vsPodium(), onLeave: () {})),
  'coop_round': (t, s) => _room(t, s, () => RoundView(session: _coopRound(), cues: MoldCues(), onLeave: () {})),
  'meaning': (t, s) => _room(t, s, () => const MeaningView(word: 'TEMPER')),
};

void main() {
  setUpAll(loadShotFonts);
  tearDown(() => Palette.scheme = PaletteScheme.forge);

  // The Hall after picking a scheme in Settings and going back: should match scheme_<id>_hall.
  for (final scheme in [PaletteScheme.gilded, PaletteScheme.steelBlue]) {
    testWidgets('${scheme.id} hall after switching', (tester) async {
      await _app(tester, PaletteScheme.forge, '/');
      GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/settings');
      await _wait(tester);
      await tester.scrollUntilVisible(find.byType(SchemePicker), 200);
      await tester.tap(find.descendant(of: find.byType(SchemePicker), matching: find.text(scheme.name)));
      await _wait(tester);
      await tester.pageBack();
      await _wait(tester);
      await _shot('scheme_${scheme.id}_hall_switched');
    });
  }

  // The swatches on the narrowest phones, where the longest names shrink to fit.
  for (final scheme in [PaletteScheme.forge, PaletteScheme.frost]) {
    testWidgets('${scheme.id} picker small phone', (tester) async {
      await _app(tester, scheme, '/settings');
      await tester.binding.setSurfaceSize(const Size(320, 640));
      await _wait(tester);
      await _toPicker(tester, 100);
      await _shot('scheme_${scheme.id}_picker_small');
    });
  }

  for (final scheme in PaletteScheme.all) {
    for (final MapEntry(key: name, value: open) in _screens.entries) {
      testWidgets('${scheme.id} ${name.replaceAll('_', ' ')}', (tester) async {
        await open(tester, scheme);
        await _shot('scheme_${scheme.id}_$name');
      });
    }
  }
}
