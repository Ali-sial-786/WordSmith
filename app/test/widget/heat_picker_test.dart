import 'dart:convert';

import 'package:flutter/material.dart';
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

const _names = ['Ada', 'sam', 'Kit_the_Smith', 'Bo', 'Wren'];

/// Ada (u1, level 40) and friends at levels 3, 6, 9…; [heatChoice] is a tier or 'auto'.
RoomLobby _lobby({
  String mode = 'coop',
  String phase = 'lobby',
  String hostId = 'u1',
  Object heatChoice = 'auto',
  int autoHeat = 4,
  int players = 4,
}) => RoomLobby.fromJson({
  'code': 'K7Q2AB',
  'mode': mode,
  'phase': phase,
  'hostId': hostId,
  'heat': heatChoice is int ? heatChoice : autoHeat,
  'heatChoice': heatChoice,
  'autoHeat': autoHeat,
  'series': 5,
  'players': [
    for (var i = 1; i <= players; i++)
      {
        'id': 'u$i',
        'username': _names[i - 1],
        'avatar': 'avatar_0$i',
        'level': i == 1 ? 40 : 3 * i,
        'color': i - 1,
        'ready': i.isEven,
        'connected': true,
      },
  ],
});

/// A co-op session that keeps the host's heat picks instead of sending them.
class _CoopPicks extends CoopSession {
  _CoopPicks({required super.me})
    : super(
        client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't'),
      );

  final picks = <int?>[];

  @override
  void setHeat(int? tier) => picks.add(tier);
}

class _VsPicks extends VsSession {
  _VsPicks({required super.me})
    : super(
        client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't'),
      );

  final picks = <int?>[];

  @override
  void setHeat(int? tier) => picks.add(tier);
}

Future<void> _pump(WidgetTester tester, Widget child, {double width = 360}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(Size(width, 740));
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

/// Scrolls the view by [dy] (up to its ends), so what's there is built.
Future<void> _scroll(WidgetTester tester, double dy) async {
  await tester.drag(find.byType(Scrollable).first, Offset(0, dy));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('the co-op host picks Auto or a tier, each named, at 360 wide', (tester) async {
    final s = _CoopPicks(me: 'u1')..lobby = _lobby();
    addTearDown(s.dispose);
    await _pump(tester, LobbyView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.byType(HeatPicker), findsOneWidget);
    // Auto shows what it gives now; every tier is there by name.
    expect(find.byKey(const ValueKey('heat-banner')), findsNothing, reason: 'the picker says it all for the host');
    expect(find.text('Orange heat · Auto · from your level · ×1.6 XP for you'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('heat-auto')), matching: find.text('Orange')), findsOneWidget);
    for (final word in ['Ember', 'Dull', 'Cherry', 'Yellow', 'White']) {
      expect(find.descendant(of: find.byType(HeatPicker), matching: find.text(word)), findsOneWidget);
    }
    expect(
      tester.getSemantics(find.byKey(const ValueKey('heat-auto'))),
      matchesSemantics(
        label: 'Auto heat, Orange now',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    // Everything fits the width.
    expect(tester.getRect(find.byKey(const ValueKey('heat-6'))).right, lessThanOrEqualTo(360 - 20 + 0.5));

    await tester.tap(find.byKey(const ValueKey('heat-6')));
    await tester.tap(find.byKey(const ValueKey('heat-auto')));
    expect(s.picks, [6, null]);
  });

  testWidgets('a guest sees the host\'s pick and what it pays them, but no picker', (tester) async {
    final s = _CoopPicks(me: 'u2')..lobby = _lobby(heatChoice: 6);
    addTearDown(s.dispose);
    await _pump(tester, LobbyView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.byType(HeatPicker), findsNothing);
    expect(find.text('White Heat'), findsOneWidget);
    // sam is level 6, Dull Red: ×2.0 plus 4 tiers up.
    expect(find.text('Picked by host Ada · ×2.8 XP for you'), findsOneWidget);
    await _scroll(tester, -3000);
    expect(find.text('Waiting for Ada to start…'), findsOneWidget);
    expect(find.text('Start the round'), findsNothing);
  });

  testWidgets('when the host role comes to me, the picker and the start button do too', (tester) async {
    final s = _CoopPicks(me: 'u2')..lobby = _lobby(hostId: 'u1');
    addTearDown(s.dispose);
    await _pump(tester, LobbyView(session: s, onLeave: () {}));
    expect(find.byType(HeatPicker), findsNothing);
    await _scroll(tester, -3000);
    expect(find.text('Waiting for Ada to start…'), findsOneWidget);
    expect(find.text('Start the round'), findsNothing);
    // Ada left: sam joined next, and now hosts; Auto follows sam's level.
    s.lobby = RoomLobby.fromJson({
      'code': 'K7Q2AB',
      'mode': 'coop',
      'phase': 'lobby',
      'hostId': 'u2',
      'heat': 2,
      'heatChoice': 'auto',
      'autoHeat': 2,
      'players': [
        {
          'id': 'u2',
          'username': 'sam',
          'avatar': 'avatar_02',
          'level': 6,
          'color': 1,
          'ready': false,
          'connected': true,
        },
      ],
    });
    await _pump(tester, LobbyView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    await _scroll(tester, -3000);
    expect(find.text('Start the round'), findsOneWidget);
    await _scroll(tester, 3000);
    expect(find.byType(HeatPicker), findsOneWidget);
    // sam is level 6, Dull Red: Auto is that, at ×1.2.
    expect(find.text('Dull Red heat · Auto · from your level · ×1.2 XP for you'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('heat-3')));
    expect(s.picks, [3]);
  });

  for (final width in [360.0, 412.0]) {
    testWidgets('the Versus lobby fits the heat, variant and series pickers at ${width.toInt()} wide', (tester) async {
      final s = _VsPicks(me: 'u1')..lobby = _lobby(mode: 'vs', players: 5, heatChoice: 3, autoHeat: 2);
      addTearDown(s.dispose);
      await _pump(
        tester,
        LobbyView(session: s, onLeave: () {}),
        width: width,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('heat-banner')), findsNothing);
      expect(find.text('Cherry Red heat · Picked by you · ×1.4 XP for you'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('heat-auto')), matching: find.text('Dull Red')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('heat-3'))),
        matchesSemantics(
          label: 'Cherry Red heat',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasTapAction: true,
        ),
      );
      expect(find.text('Best of how many rounds?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('heat-1')));
      expect(s.picks, [1]);
    });
  }

  testWidgets('a Versus guest sees Auto from the middle level', (tester) async {
    final s = _VsPicks(me: 'u3')..lobby = _lobby(mode: 'vs', players: 5, autoHeat: 2);
    addTearDown(s.dispose);
    await _pump(tester, LobbyView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.byType(HeatPicker), findsNothing);
    // Kit is level 9, Dull Red: ×1.2, nothing more.
    expect(find.text('Auto · from the middle level in the room · ×1.2 XP for you'), findsOneWidget);
  });

  testWidgets('co-op results show what the heat added, and the host can change it for the next round', (tester) async {
    final s = _CoopPicks(me: 'u2')
      ..lobby = _lobby(phase: 'results', heatChoice: 4)
      ..results = RoundEnd.fromJson({
        'reason': 'complete',
        'teamScore': 300,
        'filled': 7,
        'total': 7,
        'stars': 3,
        'players': [
          {'id': 'u2', 'username': 'sam', 'points': 150, 'words': 3, 'longest': 'TOE', 'bonus': 0},
        ],
        'mvp': 'u2',
        'answers': [],
        'xp': {
          'u2': {
            'xp': 130,
            'level': 7,
            'levelUps': 1,
            'rewards': {},
            'scrapHammers': 0,
            'heatBonus': 65,
            'tiersAbove': 2,
          },
        },
      });
    addTearDown(s.dispose);
    s.round = RoundStart.fromJson({
      'round': 1,
      'heat': 4,
      'startsAt': 0,
      'endsAt': 1,
      'letters': 'CATOE',
      'cols': 3,
      'rows': 3,
      'slots': [],
    });
    await _pump(tester, ResultsView(session: s, cues: MoldCues(), onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('Includes +65 for Orange heat, 2 tiers above yours'), findsOneWidget);
    await _scroll(tester, -3000);
    expect(find.text('Next round'), findsOneWidget);
    expect(find.text('Orange heat'), findsOneWidget);
    expect(find.text('Waiting for Ada to forge again…'), findsOneWidget);
    expect(find.byType(HeatPicker), findsNothing, reason: 'sam is not the host');

    // Ada left during the results: sam hosts now.
    s.lobby = _lobby(phase: 'results', heatChoice: 4, hostId: 'u2');
    await _pump(tester, ResultsView(session: s, cues: MoldCues(), onLeave: () {}));
    await _scroll(tester, -3000);
    expect(tester.takeException(), isNull);
    expect(find.byType(HeatPicker), findsOneWidget);
    expect(find.text('Forge again'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('heat-auto')));
    expect(s.picks, [null]);
  });
}
