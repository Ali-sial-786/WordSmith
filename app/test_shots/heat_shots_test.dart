// Renders the lobby's heat picker (host) and heat banner (guest) to PNGs with
// the real fonts, for eyeballing, in co-op and Versus at 412 and 360 wide.
// Not part of the suite: flutter test test_shots/heat_shots_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/coop/lobby_view.dart';
import 'package:wordsmith/features/coop/results_view.dart';
import 'package:wordsmith/game/coop_session.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/forge_background.dart';

const _names = ['Ali', 'sam', 'Kit_the_Smith', 'Bo', 'Wren'];
const _levels = [62, 3, 14, 8, 27];

Future<void> _font(String family, Future<ByteData> data) async {
  final loader = FontLoader(family)..addFont(data);
  await loader.load();
}

/// Ali (level 62) hosts newcomers; [heatChoice] is a tier or 'auto'.
RoomLobby _lobby(String mode, {Object heatChoice = 'auto', int autoHeat = 5, String phase = 'lobby'}) =>
    RoomLobby.fromJson({
      'code': mode == 'vs' ? 'V5X7KQ' : 'K7Q2AB',
      'mode': mode,
      'phase': phase,
      'hostId': 'u1',
      'heat': heatChoice is int ? heatChoice : autoHeat,
      'heatChoice': heatChoice,
      'autoHeat': autoHeat,
      'series': 5,
      'players': [
        for (var i = 1; i <= (mode == 'vs' ? 5 : 3); i++)
          {
            'id': 'u$i',
            'username': _names[i - 1],
            'avatar': 'avatar_0${i + 1}',
            'level': _levels[i - 1],
            'color': i - 1,
            'ready': i != 2,
            'connected': true,
          },
      ],
    });

RoomClient _client() => RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't');

Future<Store> _store() async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({
      'userId': 'abc',
      'totalXp': 900,
      'campaignStage': 12,
      'hints': {'hammer': 3},
    }),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  return Store.open();
}

Future<void> _frame(WidgetTester tester, Widget child, double width) async {
  final store = await _store();
  await tester.binding.setSurfaceSize(Size(width, width == 360 ? 780 : 892));
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
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pump(const Duration(milliseconds: 100));
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

  for (final width in [412.0, 360.0]) {
    final w = width.toInt();

    testWidgets('coop host on auto, $w', (tester) async {
      final s = CoopSession(client: _client(), me: 'u1')..lobby = _lobby('coop');
      await _frame(tester, LobbyView(session: s, onLeave: () {}), width);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/heat_coop_host_$w.png'));
    });

    testWidgets('coop guest, host picked Orange, $w', (tester) async {
      final s = CoopSession(client: _client(), me: 'u2')..lobby = _lobby('coop', heatChoice: 4);
      await _frame(tester, LobbyView(session: s, onLeave: () {}), width);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/heat_coop_guest_$w.png'));
    });

    testWidgets('vs host picked White Heat, $w', (tester) async {
      final s = VsSession(client: _client(), me: 'u1')..lobby = _lobby('vs', heatChoice: 6, autoHeat: 3);
      await _frame(tester, LobbyView(session: s, onLeave: () {}), width);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/heat_vs_host_$w.png'));
    });

    testWidgets('vs guest on auto, $w', (tester) async {
      final s = VsSession(client: _client(), me: 'u2')..lobby = _lobby('vs', autoHeat: 3);
      await _frame(tester, LobbyView(session: s, onLeave: () {}), width);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/heat_vs_guest_$w.png'));
    });
  }

  testWidgets('coop results with the heat bonus, the host picking the next heat', (tester) async {
    final s = CoopSession(client: _client(), me: 'u1')
      ..lobby = _lobby('coop', heatChoice: 5, phase: 'results')
      ..round = RoundStart.fromJson({
        'round': 1,
        'heat': 5,
        'startsAt': 0,
        'endsAt': 1,
        'letters': 'STONEA',
        'cols': 3,
        'rows': 3,
        'slots': [],
      })
      ..results = RoundEnd.fromJson({
        'reason': 'complete',
        'teamScore': 410,
        'filled': 24,
        'total': 24,
        'stars': 3,
        'players': [
          {'id': 'u1', 'username': 'Ali', 'points': 230, 'words': 6, 'longest': 'STONES', 'bonus': 1},
          {'id': 'u2', 'username': 'sam', 'points': 120, 'words': 3, 'longest': 'TONE', 'bonus': 0},
          {'id': 'u3', 'username': 'Kit_the_Smith', 'points': 60, 'words': 2, 'longest': 'NOTE', 'bonus': 2},
        ],
        'mvp': 'u1',
        'answers': [],
        'xp': {
          'u1': {'xp': 131, 'level': 62, 'levelUps': 0, 'rewards': {}, 'heatBonus': 58, 'tiersAbove': 0},
        },
      });
    await _frame(tester, ResultsView(session: s, cues: MoldCues(), onLeave: () {}), 360);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/heat_coop_results_360.png'));
  });

  testWidgets('coop results for a newcomer playing up', (tester) async {
    final s = CoopSession(client: _client(), me: 'u2')
      ..lobby = _lobby('coop', heatChoice: 5, phase: 'results')
      ..round = RoundStart.fromJson({
        'round': 1,
        'heat': 5,
        'startsAt': 0,
        'endsAt': 1,
        'letters': 'STONEA',
        'cols': 3,
        'rows': 3,
        'slots': [],
      })
      ..results = RoundEnd.fromJson({
        'reason': 'complete',
        'teamScore': 410,
        'filled': 24,
        'total': 24,
        'stars': 3,
        'players': [
          {'id': 'u1', 'username': 'Ali', 'points': 230, 'words': 6, 'longest': 'STONES', 'bonus': 1},
          {'id': 'u2', 'username': 'sam', 'points': 120, 'words': 3, 'longest': 'TONE', 'bonus': 0},
        ],
        'mvp': 'u1',
        'answers': [],
        'xp': {
          'u2': {
            'xp': 135,
            'level': 4,
            'levelUps': 1,
            'rewards': {'hammer': 1},
            'heatBonus': 83,
            'tiersAbove': 4,
          },
        },
      });
    await _frame(tester, ResultsView(session: s, cues: MoldCues(), onLeave: () {}), 360);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/heat_coop_results_guest_360.png'));
  });
}
