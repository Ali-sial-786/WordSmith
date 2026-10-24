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
import 'package:wordsmith/features/vs/vs_widgets.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';

const _names = ['Ada', 'sam', 'Kit'];

RoomLobby _lobby(String phase) => RoomLobby.fromJson({
  'code': 'V5X7KQ',
  'mode': 'vs',
  'phase': phase,
  'hostId': 'u1',
  'heat': 2,
  'series': 5,
  'scoring': 'total',
  'players': [
    for (var i = 1; i <= 3; i++)
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

/// The shots' 5×5 mold: STONE, SEAT, EATEN, TON, ONE (16 letters).
final _slots = [
  {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 5},
  {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 4},
  {'slot': 2, 'x': 4, 'y': 0, 'd': 'd', 'len': 5},
  {'slot': 3, 'x': 0, 'y': 3, 'd': 'a', 'len': 3},
  {'slot': 4, 'x': 2, 'y': 2, 'd': 'a', 'len': 3},
];
const _words = ['STONE', 'SEAT', 'EATEN', 'TON', 'ONE'];

Map<String, dynamic> _startJson() => {
  'round': 3,
  'heat': 2,
  'startsAt': 0,
  'endsAt': DateTime.now().millisecondsSinceEpoch + 74000,
  'serverNow': DateTime.now().millisecondsSinceEpoch,
  'letters': 'STONEA',
  'cols': 5,
  'rows': 5,
  'slots': _slots,
  'pickups': [],
  'series': 5,
  'regular': 3,
  'suddenDeath': false,
  'players': ['u1', 'u2', 'u3'],
  'tally': {'u1': 0, 'u2': 2, 'u3': 0},
  'scoring': 'total',
  'scores': {'u1': 27, 'u2': 32, 'u3': 18},
  'bonusTally': {'u1': 4, 'u2': 1, 'u3': 2},
};

RoundStart _start() => RoundStart.fromJson(_startJson());

VsRoundEnd _end() => VsRoundEnd.fromJson({
  'round': 3,
  'reason': 'finished',
  'winner': 'u2',
  'how': 'finished',
  'progress': [
    {'id': 'u1', 'filled': 13, 'total': 16},
    {'id': 'u2', 'filled': 16, 'total': 16},
    {'id': 'u3', 'filled': 8, 'total': 16},
  ],
  'molds': {
    'u1': [0, 1, 2, 4],
    'u2': [0, 1, 2, 3, 4],
    'u3': [0, 3],
  },
  'tally': {'u1': 0, 'u2': 3, 'u3': 0},
  'answers': [
    for (final (i, w) in _words.indexed) {'slot': i, 'word': w},
  ],
  'next': {
    'round': 4,
    'suddenDeath': false,
    'players': ['u1', 'u2', 'u3'],
  },
  'standingsEndsAt': DateTime.now().millisecondsSinceEpoch + 28000,
  'scoring': 'total',
  'scores': {'u1': 40, 'u2': 48, 'u3': 26},
  'bonusTally': {'u1': 5, 'u2': 1, 'u3': 2},
});

SeriesEnd _seriesEnd() => SeriesEnd.fromJson({
  'winner': 'u1',
  'scoring': 'total',
  'early': false,
  'forfeit': false,
  'rounds': 5,
  'podium': [
    {'id': 'u1', 'username': 'Ada', 'wins': 1, 'place': 1, 'score': 71, 'bonus': 7},
    {'id': 'u2', 'username': 'sam', 'wins': 4, 'place': 2, 'score': 71, 'bonus': 3},
    {'id': 'u3', 'username': 'Kit', 'wins': 0, 'place': 3, 'score': 44, 'bonus': 2},
  ],
  'history': [],
  'xp': {
    'u1': {'xp': 80, 'level': 6, 'levelUps': 0, 'rewards': {}, 'scrapHammers': 1, 'heatBonus': 13, 'tiersAbove': 0},
  },
});

VsSession _session(RoomLobby lobby, {String me = 'u1'}) {
  final s = VsSession(
    client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'),
    me: me,
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

Finder _text(String key) => find.byKey(ValueKey(key));

void main() {
  testWidgets('the Versus lobby offers round wins or the total score, with what it means', (tester) async {
    await _pump(tester, LobbyView(session: _session(_lobby('lobby')), onLeave: () {}, video: RoomVideo.none));
    expect(tester.takeException(), isNull);
    expect(find.text('How many rounds?'), findsOneWidget, reason: 'a total score series plays them all');
    expect(tester.widget<ChoiceChip>(_text('scoring-total')).selected, isTrue);
    expect(tester.widget<ChoiceChip>(_text('scoring-rounds')).selected, isFalse);
    expect(find.text(scoringBlurb(true)), findsOneWidget);

    // A guest sees the pick but can't change it.
    await _pump(
      tester,
      LobbyView(
        session: _session(_lobby('lobby'), me: 'u2'),
        onLeave: () {},
        video: RoomVideo.none,
      ),
    );
    expect(find.text('How the series is won · the host picks'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(_text('scoring-total')).onSelected, isNull);
  });

  testWidgets('during a round, everyone\'s total grows with the letters they fill', (tester) async {
    final start = _start();
    final s = _session(_lobby('round'))
      ..round = start
      ..mold = RemoteMold(start, () => _lobby('round'))
      ..tally = start.tally
      ..scores = start.scores
      ..bonusTally = start.bonusTally
      ..progress = {
        'u1': RacerProgress('u1', 5, 16),
        'u2': RacerProgress('u2', 9, 16),
        'u3': RacerProgress('u3', 7, 16),
      };
    await _pump(tester, VsRoundView(session: s, cues: MoldCues(), onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('of 5'), findsOneWidget);
    expect(tester.widget<Text>(_text('rival-score-u2')).data, '41');
    expect(tester.widget<Text>(_text('rival-score-u3')).data, '25');
    expect(tester.widget<Text>(_text('my-score')).data, '32');
  });

  testWidgets('the standings rank by total score, with bonus words for a tie', (tester) async {
    final start = _start();
    final end = _end();
    final s = _session(_lobby('standings'))
      ..round = start
      ..mold = RemoteMold(start, () => _lobby('standings'))
      ..standings = end
      ..tally = end.tally
      ..scores = end.scores
      ..bonusTally = end.bonusTally;
    await _pump(tester, VsStandingsView(session: s, cues: MoldCues(), onLeave: () {}));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(s.standingsOrder, ['u2', 'u1', 'u3']);
    expect(tester.widget<Text>(_text('score-u2')).data, '48');
    expect(find.text('5 bonus'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Round 4 of 5'), 200, scrollable: find.byType(Scrollable).first);
  });

  testWidgets('the podium goes by letters, and says when bonus words decided it', (tester) async {
    final s = _session(_lobby('results'))..seriesEnd = _seriesEnd();
    await _pump(tester, VsResultsView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('YOU WIN THE SERIES!'), findsOneWidget);
    expect(find.text('5 rounds · tied on 71 letters, won on bonus words'), findsOneWidget);
    expect(find.text('71 letters'), findsNWidgets(2));
  });

  testWidgets('a tie on letters and bonus words goes to a tiebreaker round, and the podium says so', (tester) async {
    final tied = SeriesEnd.fromJson({
      ..._seriesEnd().json,
      'winner': 'u1',
      'rounds': 6,
      'tiebreak': true,
      'podium': [
        {'id': 'u1', 'username': 'Ada', 'wins': 2, 'place': 1, 'score': 58, 'bonus': 2},
        {'id': 'u2', 'username': 'sam', 'wins': 2, 'place': 2, 'score': 53, 'bonus': 3},
        {'id': 'u3', 'username': 'Kit', 'wins': 0, 'place': 3, 'score': 30, 'bonus': 0},
      ],
    });
    expect(tied.tiebreak, isTrue);
    final s = _session(_lobby('results'))..seriesEnd = tied;
    await _pump(tester, VsResultsView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('YOU WIN THE SERIES!'), findsOneWidget);
    expect(find.text('6 rounds · tied on letters and bonus words, won in a tiebreaker round'), findsOneWidget);
  });

  testWidgets('the tiebreaker round is called that', (tester) async {
    final start = RoundStart.fromJson({
      ..._startJson(),
      'round': 6,
      'regular': null,
      'suddenDeath': true,
      'players': ['u1', 'u2'],
    });
    final s = _session(_lobby('round'))
      ..round = start
      ..scores = start.scores
      ..bonusTally = start.bonusTally;
    expect(roundLabel(s), 'Tiebreaker round!');
    s.scores = null;
    expect(roundLabel(s), 'Sudden death!', reason: 'on round wins it stays sudden death');
  });
}
