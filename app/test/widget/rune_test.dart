import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/coop/lobby_view.dart';
import 'package:wordsmith/features/rune/rune_board.dart';
import 'package:wordsmith/features/rune/rune_results_view.dart';
import 'package:wordsmith/features/rune/rune_review.dart';
import 'package:wordsmith/features/rune/rune_round_view.dart';
import 'package:wordsmith/features/rune/rune_standings_view.dart';
import 'package:wordsmith/features/rune/rune_widgets.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/rune_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/widgets/metal_button.dart';

/// C A T S / O R E D / QU I L T / N M P H
const _tiles = ['C', 'A', 'T', 'S', 'O', 'R', 'E', 'D', 'QU', 'I', 'L', 'T', 'N', 'M', 'P', 'H'];
const _names = ['Ada', 'sam', 'Kit_the_Smith', 'Bo', 'Wren', 'Juniper'];
const _teams = {'u1': 0, 'u2': 1, 'u3': 0, 'u4': 1, 'u5': 0, 'u6': 1};

RoomLobby _lobby(String phase, {String mode = 'rune', String hostId = 'u1', int players = 6}) => RoomLobby.fromJson({
  'code': 'R5X7KQ',
  'mode': mode,
  'phase': phase,
  'hostId': hostId,
  'heat': 2,
  'rune': {'size': 4, 'seconds': 120, 'min': 3, 'rounds': 3, 'teamScoring': 'sum'},
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
        if (mode == 'runeteam') 'team': _teams['u$i'],
      },
  ],
});

final _ids = [for (var i = 1; i <= 6; i++) 'u$i'];

RuneRoundStart _start({bool team = false, int startsIn = -1000}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RuneRoundStart.fromJson({
    'game': 'rune',
    'round': 2,
    'rounds': 3,
    'players': _ids,
    'size': 4,
    'tiles': _tiles,
    'min': 3,
    'seconds': 120,
    'startsAt': now + startsIn,
    'endsAt': now + 100000,
    'serverNow': now,
    'heat': 2,
    'totals': {for (final id in _ids) id: 10},
    if (team) ...{
      'teams': _teams,
      'teamScoring': 'pooled',
      'teamTotals': [30, 24],
    },
  });
}

final _manyWords = [
  for (final a in 'BCDFGHJKLMNPRSTVW'.split(''))
    for (final b in 'AEIOU'.split('')) '$a${b}T',
];

RuneRoundEnd _end({bool last = false, bool team = false}) => RuneRoundEnd.fromJson({
  'game': 'rune',
  'round': 2,
  'tiebreak': false,
  'size': 4,
  'tiles': _tiles,
  'found': {
    for (final id in _ids)
      id: [
        {'word': 'QUILT', 'points': 3, 'unique': false},
        if (id == 'u1') {'word': 'CRATED', 'points': 8, 'unique': true},
        for (final w in _manyWords.take(id == 'u2' ? 30 : 4)) {'word': w, 'points': 1, 'unique': false},
      ],
  },
  'points': {for (final id in _ids) id: id == 'u1' ? 15 : 7},
  'winner': team ? null : 'u1',
  if (team) ...{
    'team': 0,
    'teamPoints': [29, 21],
    'teamTotals': [59, 45],
  },
  'words': ['CRATED', 'QUILT', 'CATS', 'CAT', ..._manyWords],
  'total': 4 + _manyWords.length,
  'totals': {for (final id in _ids) id: id == 'u1' ? 25 : 17},
  'next': last ? null : {'round': 3, 'tiebreak': false, 'players': _ids},
  'standingsEndsAt': last ? null : DateTime.now().millisecondsSinceEpoch + 20000,
});

SeriesEnd _seriesEnd({bool team = false}) => SeriesEnd.fromJson({
  'game': 'rune',
  'winner': team ? null : 'u1',
  'team': team ? 0 : null,
  if (team) 'teamTally': [2, 1],
  'early': false,
  'forfeit': false,
  'rounds': 3,
  'scoring': 'total',
  'history': [],
  'podium': [
    for (final (i, id) in _ids.indexed)
      {
        'id': id,
        'username': _names[i],
        'wins': i == 0 ? 2 : 0,
        'place': team ? (_teams[id] == 0 ? 1 : 2) : i + 1,
        'score': 40 - i * 5,
        if (team) 'team': _teams[id],
      },
  ],
  'xp': {
    'u1': {'xp': 75, 'level': 4, 'levelUps': 1, 'rewards': {}, 'heatBonus': 10},
  },
  'rune': {
    'settings': {'size': 4, 'seconds': 120, 'min': 3, 'rounds': 3, 'teamScoring': 'pooled'},
    'history': [
      for (final r in [1, 2, 3]) {..._endJson, 'round': r},
    ],
    'words': {for (final id in _ids) id: 12},
    if (team) ...{
      'teamTotals': [90, 70],
      'teamWords': [30, 25],
    },
  },
});

final _endJson = {
  'round': 1,
  'size': 4,
  'tiles': _tiles,
  'found': {
    'u1': [
      {'word': 'CAT', 'points': 2, 'unique': true},
    ],
    'u2': <Object>[],
  },
  'points': {'u1': 2, 'u2': 0},
  'winner': 'u1',
  'words': ['CATS', 'CAT'],
  'total': 2,
};

RuneSession _session(RoomLobby lobby) {
  final s = RuneSession(
    client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'R5X7KQ', token: () async => 't'),
    me: 'u1',
  )..lobby = lobby;
  addTearDown(s.dispose);
  return s;
}

Future<void> _pump(WidgetTester tester, Widget child, {Size size = const Size(360, 740)}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(size);
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

/// The middle of tile [i] on a 4×4 board [side] across, from its top left.
Offset _at(int i, double side) => Offset((i % 4 + 0.5) * side / 4, (i ~/ 4 + 0.5) * side / 4);

void main() {
  group('the grid', () {
    late List<String> sent;
    late List<String> traced;

    Future<Rect> board(WidgetTester tester, {int turns = 0}) async {
      sent = [];
      traced = [];
      await _pump(
        tester,
        SizedBox(
          width: 320,
          height: 320,
          child: RuneBoard(
            tiles: _tiles,
            size: 4,
            quarterTurns: turns,
            onChanged: traced.add,
            onSubmit: (w, _) => sent.add(w),
          ),
        ),
      );
      return tester.getRect(find.byKey(const ValueKey('rune-board')));
    }

    testWidgets('a swipe through touching tiles sends the word; going back takes a tile off', (tester) async {
      final r = await board(tester);
      final g = await tester.startGesture(r.topLeft + _at(0, r.width));
      for (final i in [1, 2, 6, 2, 3]) {
        await g.moveTo(r.topLeft + _at(i, r.width));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      expect(traced, containsAllInOrder(['C', 'CA', 'CAT', 'CATE', 'CAT', 'CATS']));
      expect(sent, ['CATS']);
    });

    testWidgets("tiles that don't touch, or are used, are passed over", (tester) async {
      final r = await board(tester);
      var g = await tester.startGesture(r.topLeft + _at(8, r.width));
      // QU → I → L → T, then a knight's move to T at the top (not touching),
      // which cuts between tiles without crossing the middle of any.
      for (final i in [9, 10, 11, 2]) {
        await g.moveTo(r.topLeft + _at(i, r.width));
        await tester.pump();
      }
      await g.up();
      expect(sent, ['QUILT']);
      // C → A → R → O, then back up to C (used, and not the tile before).
      g = await tester.startGesture(r.topLeft + _at(0, r.width));
      for (final i in [1, 5, 4, 0]) {
        await g.moveTo(r.topLeft + _at(i, r.width));
        await tester.pump();
      }
      await g.up();
      expect(sent, ['QUILT', 'CARO']);
    });

    testWidgets('a fast swipe takes every tile it crosses, even with few samples', (tester) async {
      final r = await board(tester);
      // Corner to corner in one jump: C, R, L, H down the diagonal.
      final g = await tester.startGesture(r.topLeft + _at(0, r.width));
      await g.moveTo(r.topLeft + _at(15, r.width));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(sent, ['CRLH']);
    });

    testWidgets('a diagonal that cuts past a corner leaves the tile beside it', (tester) async {
      final r = await board(tester);
      final cell = r.width / 4;
      Offset cells(double x, double y) => r.topLeft + Offset(x * cell, y * cell);
      // From C to R (down and right), bowing out towards A: a third of a cell
      // from A's middle at the closest, which a round hit area would take.
      final g = await tester.startGesture(cells(0.5, 0.5));
      await g.moveTo(cells(1.255, 0.745));
      await tester.pump();
      await g.moveTo(cells(1.5, 1.5));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(traced, isNot(contains('CA')));
      expect(sent, ['CR']);
    });

    testWidgets('a swipe along a row may wander off the middle and still take each tile', (tester) async {
      final r = await board(tester);
      final cell = r.width / 4;
      Offset cells(double x, double y) => r.topLeft + Offset(x * cell, y * cell);
      final g = await tester.startGesture(cells(0.5, 0.5));
      for (final (x, y) in const [(1.5, 0.94), (2.5, 0.9), (3.5, 0.6)]) {
        await g.moveTo(cells(x, y));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      expect(sent, ['CATS']);
    });

    testWidgets('tapping tiles builds a word; tapping the last again sends it', (tester) async {
      final r = await board(tester);
      for (final i in [0, 1, 2]) {
        await tester.tapAt(r.topLeft + _at(i, r.width));
        await tester.pump();
      }
      expect(traced.last, 'CAT');
      expect(sent, isEmpty);
      await tester.tapAt(r.topLeft + _at(2, r.width));
      await tester.pump();
      expect(sent, ['CAT']);
      // A tile that doesn't touch the last starts again.
      await tester.tapAt(r.topLeft + _at(0, r.width));
      await tester.tapAt(r.topLeft + _at(15, r.width));
      await tester.pump();
      expect(traced.last, 'H');
    });

    testWidgets('a turned grid still spells the same words', (tester) async {
      final r = await board(tester, turns: 1);
      // Turned a quarter clockwise: the top row (C A T S) runs down the right-hand column.
      final g = await tester.startGesture(r.topLeft + _at(3, r.width));
      for (final i in [7, 11]) {
        await g.moveTo(r.topLeft + _at(i, r.width));
        await tester.pump();
      }
      await g.up();
      expect(sent, ['CAT']);
    });

    test('finds where a word lies, QU and all', () {
      expect(runePathOf(_tiles, 4, 'QUILT'), [8, 9, 10, 11]);
      expect(runePathOf(_tiles, 4, 'CRATED'), isNotNull);
      expect(runePathOf(_tiles, 4, 'CATS'), [0, 1, 2, 3]);
      expect(runePathOf(_tiles, 4, 'QUIT'), isNull);
      expect(runePathOf(_tiles, 4, 'UIL'), isNull, reason: 'QU is one tile');
      expect(runeTilesTouch(0, 5, 4), isTrue);
      expect(runeTilesTouch(3, 4, 4), isFalse, reason: 'the end of one row and the start of the next');
      expect([3, 4, 5, 6, 7].map(runeWordPoints), [1, 2, 3, 4, 5]);
    });
  });

  testWidgets('the Rune Rush lobby: the host\'s settings, Auto heat and the start', (tester) async {
    await _pump(tester, LobbyView(session: _session(_lobby('lobby')), onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('Rune Rush'), findsWidgets);
    expect(find.text('Smiths 6/6'), findsOneWidget);
    expect(find.byKey(const ValueKey('heat-banner')), findsOneWidget, reason: 'Rune Rush heat is always Auto');
    expect(find.byKey(const ValueKey('heat-auto')), findsNothing);
    expect(find.text('Survival'), findsNothing);
    for (final key in ['rune-size-5', 'rune-seconds-120', 'rune-min-4', 'rune-rounds-5']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('rune-seconds-120'))).selected, isTrue);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('rune-size-5'))).onSelected, isNotNull);
    expect(find.byKey(const ValueKey('rune-team-scoring-sum')), findsNothing, reason: 'free-for-all');
    await tester.scrollUntilVisible(find.text('Start the game'), 200, scrollable: find.byType(Scrollable).first);
    expect(tester.widget<PlateButton>(find.widgetWithText(PlateButton, 'Start the game')).onPressed, isNotNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('mode-runeteam')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
  });

  testWidgets('the Team Rune Rush lobby: teams, team scoring, and a guest can only look', (tester) async {
    await _pump(
      tester,
      LobbyView(
        session: _session(_lobby('lobby', mode: 'runeteam', hostId: 'u2')),
        onLeave: () {},
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Team Rune Rush'), findsOneWidget);
    expect(find.text('The host picks'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('rune-team-scoring-sum'))).selected, isTrue);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('rune-size-5'))).onSelected, isNull);
    expect(find.text(teamScoringBlurb('sum')), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Teams are even'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Copper'), findsOneWidget);
    expect(find.text('Cobalt'), findsOneWidget);
  });

  testWidgets('a round fits a small phone: rivals, the grid, my words', (tester) async {
    final s = _session(_lobby('round'))..grid = _start();
    s.mine.addAll([for (final w in _manyWords.take(40)) RuneWord(w, 'u1', 1)]);
    s.tally = {for (final id in _ids) id: 7};
    s.totals = {for (final id in _ids) id: 10};
    await _pump(tester, RuneRoundView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('Round 2 of 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('rune-board')), findsOneWidget);
    expect(find.text('7 words · 10 pts'), findsNWidgets(5));
    expect(find.text('40 words · 40 pts'), findsOneWidget);
    final board = tester.getRect(find.byKey(const ValueKey('rune-board')));
    expect(board.width, greaterThan(250), reason: 'the grid gets most of the screen');
  });

  testWidgets('a team round shows both teams, and the countdown before it', (tester) async {
    final s = _session(_lobby('countdown', mode: 'runeteam'))
      ..grid = _start(team: true, startsIn: 3000)
      ..teamTotals = [30, 24];
    await _pump(tester, RuneRoundView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('rune-team-0')), findsOneWidget);
    expect(find.text('30 pts · 0 words'), findsOneWidget);
    expect(find.text('4×4 · 2:00 · words of 3+ letters'), findsOneWidget);
  });

  testWidgets('the standings: who took it, everyone\'s words and every word on the grid', (tester) async {
    final s = _session(_lobby('standings'))
      ..grid = _start()
      ..standings = _end()
      ..totals = _end().totals;
    await _pump(tester, RuneStandingsView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('You take the round with 15!'), findsOneWidget);
    expect(find.byKey(const ValueKey('next-round-bar')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('rune-found-u1')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // Tapping a word shows where it lies.
    await tester.tap(find.textContaining('CRATED').first);
    await tester.pump();
    expect(find.text('CRATED'), findsOneWidget, reason: 'named under the grid, its path lit');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('rune-all-words')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('rune-all-words')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rune-all-words')));
    await tester.pump();
    expect(find.byKey(const ValueKey('rune-all-words')), findsNothing, reason: 'all shown');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the words are counted first, fast, while the list scrolls; then who took it', (tester) async {
    final end = _end();
    final s = _session(_lobby('standings'))
      ..grid = _start()
      ..standings = end
      ..totals = end.totals
      ..countRound = 2;
    await _pump(tester, RuneStandingsView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('rune-count')), findsOneWidget);
    expect(find.text("Time's up! Counting the words…"), findsOneWidget);
    expect(find.byKey(const ValueKey('rune-headline')), findsNothing, reason: 'no spoilers while counting');
    await tester.pump(const Duration(milliseconds: 400));
    final early = tester.widget<Text>(find.byKey(const ValueKey('rune-count-points-u2'))).data!;
    expect(int.parse(early), lessThan(end.points['u2']!));
    // The list scrolls while the count goes on.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('rune-found-u6')),
      300,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('rune-standings-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(const ValueKey('rune-count')), findsOneWidget, reason: 'still counting, pinned above');
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('rune-count')), findsNothing);
    expect(s.countRound, isNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('rune-headline')),
      -300,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('rune-standings-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('You take the round with 15!'), findsOneWidget);
  });

  testWidgets('Skip jumps to the end of the count', (tester) async {
    final s = _session(_lobby('standings', mode: 'runeteam'))
      ..grid = _start(team: true)
      ..standings = _end(team: true)
      ..countRound = 2;
    await _pump(tester, RuneStandingsView(session: s, onLeave: () {}));
    expect(find.byKey(const ValueKey('rune-count-team-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rune-skip-count')));
    await tester.pump();
    expect(find.byKey(const ValueKey('rune-count')), findsNothing);
    expect(find.text('Your team takes the round, 29–21'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('after the last round: see the results', (tester) async {
    final s = _session(_lobby('results'))
      ..grid = _start()
      ..standings = _end(last: true)
      ..finalRoundUntil = DateTime.now().add(const Duration(seconds: 10));
    s.seriesEnd = _seriesEnd();
    await _pump(tester, RuneStandingsView(session: s, onLeave: () {}));
    expect(find.byKey(const ValueKey('rune-see-results')), findsOneWidget);
    expect(find.byKey(const ValueKey('next-round-bar')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('rune-see-results')));
    await tester.pump();
    expect(s.showingFinalRound, isFalse);
  });

  testWidgets('the results: places on points, XP, round by round, rematch', (tester) async {
    final s = _session(_lobby('results'))..seriesEnd = _seriesEnd();
    await _pump(tester, RuneResultsView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('YOU WIN!'), findsOneWidget);
    expect(find.byKey(const ValueKey('rune-place-u1')), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
    expect(find.text('Rematch'), findsOneWidget);
    expect(find.byKey(const ValueKey('to-lobby')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('rune-history-3')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('rune-history-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rune-history-3')));
    await tester.pumpAndSettle();
    expect(find.text('Round 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('team results: both teams\' points and the team picker', (tester) async {
    final s = _session(_lobby('results', mode: 'runeteam'))..seriesEnd = _seriesEnd(team: true);
    await _pump(tester, RuneResultsView(session: s, onLeave: () {}));
    expect(tester.takeException(), isNull);
    expect(find.text('YOUR TEAM WINS!'), findsOneWidget);
    expect(find.byKey(const ValueKey('rune-team-total-0')), findsOneWidget);
    expect(find.text('90'), findsOneWidget);
    expect(find.text('Copper'), findsWidgets);
  });
}
