import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/coop/next_round_bar.dart';
import 'package:wordsmith/features/coop/results_view.dart';
import 'package:wordsmith/features/solo/forged_overlay.dart';
import 'package:wordsmith/features/vs/vs_standings_view.dart';
import 'package:wordsmith/game/coop_session.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/widgets/metal_button.dart';

const _names = ['Ada', 'sam', 'Kit'];

/// Ada (u1, me, the host), sam and Kit; [ready] says who's ready.
RoomLobby _lobby(String mode, String phase, {Set<String> ready = const {}, int? nextAt}) => RoomLobby.fromJson({
  'code': 'K7Q2AB',
  'mode': mode,
  'phase': phase,
  'hostId': 'u1',
  'heat': 2,
  'series': 5,
  'nextAt': ?nextAt,
  'players': [
    for (var i = 1; i <= 3; i++)
      {
        'id': 'u$i',
        'username': _names[i - 1],
        'avatar': 'avatar_0$i',
        'level': 3 * i,
        'color': i - 1,
        'ready': ready.contains('u$i'),
        'connected': true,
      },
  ],
});

int get _now => DateTime.now().millisecondsSinceEpoch;

/// A Versus session that keeps my NEXTs instead of sending them.
class _Vs extends VsSession {
  _Vs()
    : super(
        client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't'),
        me: 'u1',
      );

  var nexts = 0;

  @override
  void readyForNext() => nexts++;
}

class _Coop extends CoopSession {
  _Coop({super.me = 'u1'})
    : super(
        client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't'),
      );

  var nexts = 0;

  @override
  void readyForNext() => nexts++;
}

RoundStart _start() => RoundStart.fromJson({
  'round': 1,
  'heat': 2,
  'startsAt': 0,
  'endsAt': _now + 90000,
  'serverNow': _now,
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
  'regular': 5,
  'suddenDeath': false,
  'players': ['u1', 'u2', 'u3'],
  'tally': {'u1': 0, 'u2': 0, 'u3': 0},
});

/// Round 1's end; [racers] play round 2, and the standings last 30 s.
VsRoundEnd _end({List<String> racers = const ['u1', 'u2', 'u3']}) => VsRoundEnd.fromJson({
  'round': 1,
  'reason': 'finished',
  'winner': 'u2',
  'how': 'finished',
  'progress': [
    {'id': 'u1', 'filled': 3, 'total': 7},
    {'id': 'u2', 'filled': 7, 'total': 7},
    {'id': 'u3', 'filled': 0, 'total': 7},
  ],
  'tally': {'u1': 0, 'u2': 1, 'u3': 0},
  'answers': [
    {'slot': 0, 'word': 'CAT'},
    {'slot': 1, 'word': 'COT'},
    {'slot': 2, 'word': 'TOE'},
  ],
  'next': {'round': 2, 'suddenDeath': false, 'players': racers},
  'standingsEndsAt': _now + 30000,
});

_Vs _standings({Set<String> ready = const {}, List<String> racers = const ['u1', 'u2', 'u3']}) {
  final start = _start();
  final end = _end(racers: racers);
  final s = _Vs()
    ..lobby = _lobby('vs', 'standings', ready: ready)
    ..round = start
    ..standings = end
    ..tally = end.tally;
  s.mold = RemoteMold(start, () => s.lobby!);
  addTearDown(s.dispose);
  return s;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(const Size(412, 892));
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

/// Past the round's result card, to the standings themselves.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await tester.pump(const Duration(seconds: 1));
}

PlateButton _readyButton(WidgetTester tester) => tester.widget<PlateButton>(find.byKey(const ValueKey('ready-next')));

/// The bar counts down on the real clock, which a slow machine moves on
/// whatever the test pumps: it shows the seconds left until [endsAt].
Future<void> _expectCountdown(WidgetTester tester, RoomSession s, int endsAt, {required int from}) async {
  await tester.pump(const Duration(milliseconds: 300));
  final shown = tester.widget<Text>(find.textContaining(RegExp(r'^Next round in \d+$'))).data!;
  final secs = int.parse(shown.split(' ').last);
  final left = ((endsAt - s.serverNow) / 1000).ceil();
  expect(secs, inInclusiveRange(left, left + 1));
  expect(secs, inInclusiveRange(1, from));
}

void main() {
  testWidgets('the Versus standings count down 30 s, and I can say I\'m ready to go sooner', (tester) async {
    final s = _standings(ready: {'u2'});
    await _pump(tester, VsStandingsView(session: s, cues: MoldCues(), onLeave: () {}));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    final bar = find.byType(NextRoundBar);
    await tester.scrollUntilVisible(bar, 200, scrollable: find.byType(Scrollable).first);
    await _expectCountdown(tester, s, s.standings!.standingsEndsAt!, from: 30);
    expect(find.text('1 of 3 ready'), findsOneWidget);
    expect(_readyButton(tester).label, "I'm ready");
    expect(_readyButton(tester).sublabel, 'Starts as soon as everyone is ready');
    await tester.tap(find.byKey(const ValueKey('ready-next')));
    expect(s.nexts, 1);

    // The server says I'm ready: the button waits on the others.
    s.lobby = _lobby('vs', 'standings', ready: {'u1', 'u2'});
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2 of 3 ready'), findsOneWidget);
    expect(_readyButton(tester).label, 'Ready!');
    expect(_readyButton(tester).sublabel, 'Waiting for 1 more');
    expect(_readyButton(tester).onPressed, isNull);
  });

  testWidgets('only the next round\'s racers are counted, and only they get the button', (tester) async {
    final s = _standings(racers: ['u2', 'u3'], ready: {'u1'});
    await _pump(tester, VsStandingsView(session: s, cues: MoldCues(), onLeave: () {}));
    await _settle(tester);
    await tester.scrollUntilVisible(find.byType(NextRoundBar), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('0 of 2 ready'), findsOneWidget);
    expect(find.byKey(const ValueKey('ready-next')), findsNothing, reason: 'I sit out the sudden death');
  });

  testWidgets('the standings list the bonus words I sent to my Scrap Bin this round', (tester) async {
    final s = _standings();
    s.scrapWords.addAll(['TOE', 'ACT']);
    await _pump(tester, VsStandingsView(session: s, cues: MoldCues(), onLeave: () {}));
    await _settle(tester);
    final scrap = find.byType(ScrapWords);
    await tester.scrollUntilVisible(scrap, 200, scrollable: find.byType(Scrollable).first);
    expect(find.descendant(of: scrap, matching: find.text('Into the Scrap Bin')), findsOneWidget);
    expect(find.descendant(of: scrap, matching: find.text('ACT')), findsOneWidget);
    expect(find.descendant(of: scrap, matching: find.text('TOE')), findsOneWidget);
    expect(s.bonusWords, 2);
  });

  testWidgets('co-op results: after Forge again, a 20 s wait anyone can cut short, and the team\'s bonus words', (
    tester,
  ) async {
    final s = _Coop()
      ..lobby = _lobby('coop', 'results')
      ..round = _start()
      ..results = RoundEnd.fromJson({
        'reason': 'timeout',
        'teamScore': 80,
        'filled': 5,
        'total': 7,
        'stars': 1,
        'players': [
          {'id': 'u1', 'username': 'Ada', 'points': 50, 'words': 1, 'longest': 'CAT'},
          {'id': 'u2', 'username': 'sam', 'points': 30, 'words': 1, 'longest': 'TOE'},
        ],
        'mvp': 'u1',
        'answers': [],
        'xp': {},
      });
    s.bonusWords
      ..add(('ACT', 'u1'))
      ..add(('OAT', 'u2'));
    addTearDown(s.dispose);
    await _pump(tester, ResultsView(session: s, cues: MoldCues(), onLeave: () {}));
    expect(tester.takeException(), isNull);
    final scrap = find.byType(ScrapWords);
    await tester.scrollUntilVisible(scrap, 200, scrollable: find.byType(Scrollable).first);
    expect(find.descendant(of: scrap, matching: find.text('Bonus words this round')), findsOneWidget);
    expect(find.descendant(of: scrap, matching: find.text('ACT')), findsOneWidget);
    expect(find.descendant(of: scrap, matching: find.text('OAT')), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Forge again'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.byType(NextRoundBar), findsNothing);

    // The host forged again: the server gives the wait, with the host ready.
    final nextAt = _now + 20000;
    s.lobby = _lobby('coop', 'results', ready: {'u1'}, nextAt: nextAt);
    await _pump(tester, ResultsView(session: s, cues: MoldCues(), onLeave: () {}));
    await tester.scrollUntilVisible(find.byType(NextRoundBar), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Forge again'), findsNothing);
    await _expectCountdown(tester, s, nextAt, from: 20);
    expect(find.text('1 of 3 ready'), findsOneWidget);
    expect(_readyButton(tester).sublabel, 'Waiting for 2 more');

    // As sam, not yet ready.
    final sam = _Coop(me: 'u2')
      ..lobby = _lobby('coop', 'results', ready: {'u1'}, nextAt: _now + 20000)
      ..round = s.round
      ..results = s.results;
    addTearDown(sam.dispose);
    await _pump(tester, ResultsView(session: sam, cues: MoldCues(), onLeave: () {}));
    await tester.scrollUntilVisible(find.byType(NextRoundBar), 200, scrollable: find.byType(Scrollable).first);
    expect(_readyButton(tester).label, "I'm ready");
    await tester.tap(find.byKey(const ValueKey('ready-next')));
    expect(sam.nexts, 1);
  });
}
