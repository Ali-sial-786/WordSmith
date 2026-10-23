import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/coop/lobby_view.dart';
import 'package:wordsmith/features/coop/room_video.dart';
import 'package:wordsmith/features/vs/team_widgets.dart';
import 'package:wordsmith/features/vs/vs_results_view.dart';
import 'package:wordsmith/features/vs/vs_round_view.dart';
import 'package:wordsmith/features/vs/vs_standings_view.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/widgets/metal_button.dart';

const _names = ['Ada', 'sam', 'Kit_the_Smith', 'Bo', 'Wren', 'Juniper'];

/// Six smiths: u1, u3 and u5 on Copper, u2, u4 and u6 on Cobalt; I'm u1, the host.
const _teams = {'u1': 0, 'u2': 1, 'u3': 0, 'u4': 1, 'u5': 0, 'u6': 1};

RoomLobby _lobby(String phase, {int players = 6, String rule = 'combined', String hostId = 'u1'}) =>
    RoomLobby.fromJson({
      'code': 'T5X7KQ',
      'mode': 'team',
      'phase': phase,
      'hostId': hostId,
      'heat': 2,
      'series': 5,
      'rule': rule,
      'players': [
        for (var i = 1; i <= players; i++)
          {
            'id': 'u$i',
            'username': _names[i - 1],
            'avatar': 'avatar_0$i',
            'level': 3 * i,
            'color': i - 1,
            'ready': i.isOdd,
            'connected': true,
            'team': _teams['u$i'],
          },
      ],
    });

RoundStart _start() => RoundStart.fromJson({
  'round': 2,
  'heat': 2,
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
  'regular': 2,
  'suddenDeath': false,
  'players': [for (var i = 1; i <= 6; i++) 'u$i'],
  'tally': {for (var i = 1; i <= 6; i++) 'u$i': _teams['u$i'] == 0 ? 1 : 0},
  'teams': _teams,
  'teamTally': [1, 0],
  'rule': 'combined',
});

VsRoundEnd _end({int? team = 0, String? winner, String how = 'timeout'}) => VsRoundEnd.fromJson({
  'round': 2,
  'reason': 'timeout',
  'winner': winner,
  'how': how,
  'team': team,
  'teamScores': [12, 9],
  'teamTally': [team == 0 ? 2 : 1, team == 1 ? 1 : 0],
  'teams': _teams,
  'rule': winner == null ? 'combined' : 'first',
  'progress': [
    for (var i = 1; i <= 6; i++) {'id': 'u$i', 'filled': i, 'total': 7},
  ],
  'tally': {for (var i = 1; i <= 6; i++) 'u$i': _teams['u$i'] == 0 ? 2 : 0},
  'answers': [
    {'slot': 0, 'word': 'CAT'},
    {'slot': 1, 'word': 'COT'},
    {'slot': 2, 'word': 'TOE'},
  ],
  'next': {
    'round': 3,
    'suddenDeath': false,
    'players': [for (var i = 1; i <= 6; i++) 'u$i'],
  },
  'standingsEndsAt': DateTime.now().millisecondsSinceEpoch + 8000,
});

SeriesEnd _seriesEnd({int? team = 0}) => SeriesEnd.fromJson({
  'winner': null,
  'team': team,
  'rule': 'combined',
  'teamTally': [3, 1],
  'early': true,
  'forfeit': false,
  'rounds': 4,
  'podium': [
    for (final id in ['u1', 'u3', 'u5', 'u2', 'u4', 'u6'])
      {
        'id': id,
        'username': _names[int.parse(id.substring(1)) - 1],
        'wins': _teams[id] == 0 ? 3 : 1,
        'place': _teams[id] == team ? 1 : 2,
        'team': _teams[id],
      },
  ],
  'history': [],
  'xp': {
    'u1': {'xp': 90, 'level': 4, 'levelUps': 0, 'rewards': {}, 'scrapHammers': 0, 'heatBonus': 18, 'tiersAbove': 0},
  },
});

VsSession _session(RoomLobby lobby) {
  final s = VsSession(
    client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'T5X7KQ', token: () async => 't'),
    me: 'u1',
  )..lobby = lobby;
  addTearDown(s.dispose);
  return s;
}

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

void main() {
  testWidgets('the Team Versus lobby shows both teams of three, the rule and the start', (tester) async {
    await _pump(tester, LobbyView(session: _session(_lobby('lobby')), onLeave: () {}, video: RoomVideo.none));
    expect(tester.takeException(), isNull);
    expect(find.text('Team Clash'), findsOneWidget);
    expect(find.text('Smiths 6/6'), findsOneWidget);
    expect(find.text('Combined'), findsOneWidget);
    expect(find.text('First to finish'), findsOneWidget);
    expect(find.text('Survival'), findsNothing, reason: 'teams play classic rounds');
    expect(find.text('Copper'), findsOneWidget);
    expect(find.text('Cobalt'), findsOneWidget);
    expect(find.text('3/3'), findsNWidgets(2));
    // Both full: nobody can join either; the host can't move anyone across.
    expect(find.byKey(const ValueKey('join-team-1')), findsNothing);
    final move = tester.widget<IconButton>(find.byKey(const ValueKey('move-u2')));
    expect(move.onPressed, isNull);
    expect(find.text('Teams are even'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Start the series'), 200, scrollable: find.byType(Scrollable).first);
    final start = tester.widget<PlateButton>(find.widgetWithText(PlateButton, 'Start the series'));
    expect(start.onPressed, isNotNull);
  });

  testWidgets('uneven teams can\'t start, and the other team can be joined', (tester) async {
    await _pump(
      tester,
      LobbyView(session: _session(_lobby('lobby', players: 3)), onLeave: () {}, video: RoomVideo.none),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Teams need the same number of smiths'), findsOneWidget);
    expect(find.byKey(const ValueKey('join-team-1')), findsOneWidget, reason: "I'm on Copper; Cobalt has room");
    expect(find.byKey(const ValueKey('join-team-0')), findsNothing);
    await tester.scrollUntilVisible(find.text('Start the series'), 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<PlateButton>(find.widgetWithText(PlateButton, 'Start the series')).onPressed, isNull);
    expect(find.text('Teams must be the same size'), findsOneWidget);
  });

  testWidgets('a guest sees the rule but can\'t change it, nor move anyone', (tester) async {
    await _pump(
      tester,
      LobbyView(
        session: _session(_lobby('lobby', hostId: 'u2', rule: 'first')),
        onLeave: () {},
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('How a round is won · the host picks'), findsOneWidget);
    expect(find.text(ruleBlurb('first')), findsOneWidget);
    expect(find.byIcon(Icons.swap_vert), findsNothing);
  });

  testWidgets('a Team Versus round shows both teams\' letters added up under the rivals', (tester) async {
    final start = _start();
    final s = _session(_lobby('round'))
      ..round = start
      ..mold = RemoteMold(start, () => _lobby('round'))
      ..tally = start.tally
      ..teamTally = start.teamTally!
      ..progress = {for (var i = 1; i <= 6; i++) 'u$i': RacerProgress('u$i', i, 7)};
    await _pump(tester, VsRoundView(session: s, cues: MoldCues(), onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.byType(TeamScoreBar), findsOneWidget);
    expect(find.text('Copper · you'), findsOneWidget);
    // Copper: 1 + 3 + 5; Cobalt: 2 + 4 + 6.
    expect(find.text('9 letters'), findsOneWidget);
    expect(find.text('12 letters'), findsOneWidget);
  });

  for (final (label, end, headline) in [
    ('combined, my team', _end(), 'Your team wins on letters, 12–9'),
    ('first, the other team', _end(team: 1, winner: 'u4', how: 'finished'), 'Bo forged it first for Cobalt!'),
    ('nobody', _end(team: null), 'No winner this round'),
  ]) {
    testWidgets('the standings after a team round: $label', (tester) async {
      final start = _start();
      final s = _session(_lobby('standings'))
        ..round = start
        ..mold = RemoteMold(start, () => _lobby('standings'))
        ..standings = end
        ..tally = end.tally
        ..teamTally = end.teamTally!;
      await _pump(tester, VsStandingsView(session: s, cues: MoldCues(), onLeave: () {}));
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(find.byType(TeamTally), findsOneWidget);
      expect(teamRoundHeadline(s, end), headline);
    });
  }

  for (final team in [0, 1]) {
    testWidgets('the results of a Team Versus series ${team == 0 ? 'my team won' : 'the other team won'}', (
      tester,
    ) async {
      final s = _session(_lobby('results'))..seriesEnd = _seriesEnd(team: team);
      await _pump(tester, VsResultsView(session: s, onLeave: () {}));
      expect(tester.takeException(), isNull);
      expect(find.text(team == 0 ? 'YOUR TEAM WINS THE SERIES!' : 'Cobalt wins the series!'), findsOneWidget);
      expect(find.byType(TeamResults), findsOneWidget);
      expect(find.text('You · 3 wins'), findsOneWidget);
      // Teams can be changed before a rematch.
      await tester.scrollUntilVisible(find.byType(TeamPicker), 200, scrollable: find.byType(Scrollable).first);
      expect(find.byType(TeamPicker), findsOneWidget);
    });
  }
}
