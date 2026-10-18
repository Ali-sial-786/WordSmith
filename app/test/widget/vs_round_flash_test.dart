import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/auth/auth_service.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/vs/rival_molds.dart';
import 'package:wordsmith/features/vs/round_flash.dart';
import 'package:wordsmith/features/vs/vs_results_view.dart';
import 'package:wordsmith/features/vs/vs_standings_view.dart';
import 'package:wordsmith/features/vs/vs_widgets.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';

import '../fixtures/fake_backend.dart';
import '../fixtures/puzzles.dart';

const _names = ['Ada', 'sam', 'Kit', 'Bo', 'Wren'];

Map<String, Object?> _lobbyJson(String phase, {int players = 4}) => {
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
        'avatar': 'avatar_0$i',
        'level': 3 * i,
        'color': i - 1,
        'ready': true,
        'connected': true,
      },
  ],
};

/// CAT across the top, COT down the left, TOE down the right: 7 letters.
const _cells = {
  0: [(0, 0), (1, 0), (2, 0)],
  1: [(0, 0), (0, 1), (0, 2)],
  2: [(2, 0), (2, 1), (2, 2)],
};

Map<String, Object?> _startJson({int round = 3, bool sudden = false, List<String>? racers, bool survival = false}) => {
  'round': round,
  'heat': 3,
  'startsAt': 0,
  'endsAt': DateTime.now().millisecondsSinceEpoch,
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
  'regular': sudden ? null : round,
  'suddenDeath': sudden,
  'players': racers ?? ['u1', 'u2', 'u3', 'u4'],
  'tally': {'u1': 1, 'u2': 1, 'u3': 0, 'u4': 0},
  if (survival) 'variant': 'survival',
};

/// The end of round [round]: [molds] are everyone's complete slots, [tally]
/// the wins after it; [deciding] when it decides the series.
Map<String, Object?> _endJson({
  int round = 3,
  required String? winner,
  required String how,
  required Map<String, List<int>> molds,
  Map<String, int> tally = const {},
  bool deciding = false,
  Map<String, Object>? melted,
}) => {
  'round': round,
  'reason': melted != null ? 'melted' : (how == 'finished' ? 'finished' : 'timeout'),
  'winner': winner,
  'how': how,
  'progress': [
    for (final e in molds.entries)
      {
        'id': e.key,
        'filled': {for (final s in e.value) ..._cells[s]!}.length,
        'total': 7,
      },
  ],
  'molds': molds,
  'tally': tally,
  'answers': [
    {'slot': 0, 'word': 'CAT'},
    {'slot': 1, 'word': 'COT'},
    {'slot': 2, 'word': 'TOE'},
  ],
  'next': deciding ? null : {'round': round + 1, 'suddenDeath': false, 'players': molds.keys.toList()},
  'standingsEndsAt': deciding ? null : DateTime.now().millisecondsSinceEpoch + 8000,
  if (melted != null) ...{'variant': 'survival', 'melted': melted},
};

/// A room just after a round, as the standings see it.
VsSession _clash({
  int round = 3,
  bool sudden = false,
  required String? winner,
  required String how,
  required Map<String, List<int>> molds,
  Map<String, int> tally = const {},
  bool deciding = false,
  Map<String, Object>? melted,
}) {
  final start = RoundStart.fromJson(
    _startJson(round: round, sudden: sudden, racers: molds.keys.toList(), survival: melted != null),
  );
  final end = VsRoundEnd.fromJson(
    _endJson(round: round, winner: winner, how: how, molds: molds, tally: tally, deciding: deciding, melted: melted),
  );
  final lobby = RoomLobby.fromJson(_lobbyJson(deciding ? 'round' : 'standings'));
  final s = VsSession(
    client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'),
    me: 'u1',
  );
  s
    ..lobby = lobby
    ..round = start
    ..mold = RemoteMold(start, () => lobby)
    ..standings = end
    ..tally = end.tally;
  if (deciding) s.finalRoundUntil = DateTime.now().add(VsSession.finalRoundHold);
  addTearDown(s.dispose);
  return s;
}

SeriesEnd _seriesEnd(String? winner) => SeriesEnd.fromJson({
  'winner': winner,
  'early': true,
  'forfeit': false,
  'rounds': 4,
  'podium': [
    {'id': 'u1', 'username': 'Ada', 'wins': 3, 'place': 1},
  ],
  'xp': {},
});

Future<void> _pump(WidgetTester tester, VsSession s, {bool calm = false}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': calm, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(const Size(360, 740));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWithValue(store)],
      child: MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: VsStandingsView(session: s, cues: MoldCues(), onLeave: () {}),
          ),
        ),
      ),
    ),
  );
  // The card's clock starts once it's laid out.
  await tester.pump();
  await tester.pump();
}

Finder _inCard(Finder f) => find.descendant(of: find.byType(RoundFlash), matching: f);
Finder _inBanner(Finder f) => find.descendant(of: find.byType(RoundBanner), matching: f);

/// Past the card's few seconds and its flight into the banner.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pump(const Duration(milliseconds: 500));
}

/// A room socket the test talks through.
class _Socket implements WebSocketChannel {
  final _in = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  late final _sink = _Sink(this);

  bool get open => _in.hasListener;

  void send(Map<String, Object?> m) => _in.add(jsonEncode(m));

  @override
  Stream<dynamic> get stream => _in.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  Future<void> get ready => Future.value();

  @override
  String? get protocol => 'wordsmith.v1';

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sink implements WebSocketSink {
  _Sink(this.socket);

  final _Socket socket;

  @override
  void add(dynamic data) => socket.sent.add(jsonDecode(data as String) as Map<String, dynamic>);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The app, in Versus room V5X7KQ as Ada (u1), connected through the returned socket.
Future<_Socket> _openRoom(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  final auth = FakeAuth(
    signedIn: const AuthUser(uid: 'u1', email: 'ada@example.com'),
  );
  final server = FakeServer()..username = 'Ada';
  server.rooms['V5X7KQ'] = {
    'code': 'V5X7KQ',
    'mode': 'vs',
    'phase': 'round',
    'players': 4,
    'maxPlayers': 5,
    'seated': true,
  };
  final socket = _Socket();
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(
        Campaign.fromJson({
          'version': 1,
          'chapters': [
            {'id': 'tin', 'name': 'Tin', 'first': 1, 'count': 1},
          ],
          'puzzles': [tearJson()],
        }),
      ),
      authServiceProvider.overrideWithValue(auth),
      apiClientProvider.overrideWithValue(server.client(auth)),
      roomClientFactoryProvider.overrideWithValue(
        (code) => RoomClient(baseUrl: 'http://127.0.0.1:9', code: code, token: auth.idToken, connect: (_, _) => socket),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: '/room/V5X7KQ?mode=vs', routes: appRouter.configuration.routes),
      ),
    ),
  );
  for (var i = 0; i < 40 && !socket.open; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(socket.open, isTrue, reason: 'the room connects');
  return socket;
}

/// Round 3 decides the series: I fill my mold first; everyone's molds differ.
void _decidingRound(_Socket socket) {
  final now = DateTime.now().millisecondsSinceEpoch;
  socket
    ..send({'op': 'WELCOME', 'you': 'u1', 'protocol': 1, 'serverNow': now})
    ..send({'op': 'LOBBY', ..._lobbyJson('round')})
    ..send({'op': 'ROUND_START', ..._startJson()})
    ..send({
      'op': 'ROUND_END',
      ..._endJson(
        winner: 'u1',
        how: 'finished',
        molds: {
          'u1': [0, 1, 2],
          'u2': [0, 1],
          'u3': [2],
          'u4': [],
        },
        tally: {'u1': 3, 'u2': 1, 'u3': 0, 'u4': 0},
        deciding: true,
      ),
    });
}

void _seriesOver(_Socket socket) => socket
  ..send({
    'op': 'SERIES_END',
    'winner': 'u1',
    'early': true,
    'forfeit': false,
    'rounds': 3,
    'podium': [
      {'id': 'u1', 'username': 'Ada', 'wins': 3, 'place': 1},
      {'id': 'u2', 'username': 'sam', 'wins': 1, 'place': 2},
      {'id': 'u3', 'username': 'Kit', 'wins': 0, 'place': 3},
      {'id': 'u4', 'username': 'Bo', 'wins': 0, 'place': 3},
    ],
    'xp': {},
  })
  ..send({'op': 'LOBBY', ..._lobbyJson('results')});

void main() {
  testWidgets('my win: the hammer comes down on the card, then it settles into the banner', (tester) async {
    final s = _clash(
      winner: 'u1',
      how: 'finished',
      molds: {
        'u1': [0, 1, 2],
        'u2': [0],
        'u3': [],
        'u4': [2],
      },
      tally: {'u1': 2, 'u2': 1, 'u3': 0, 'u4': 0},
    );
    await _pump(tester, s);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.byType(HammerStrike), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1200));
    expect(tester.takeException(), isNull);
    expect(_inCard(find.text('ROUND 3')), findsOneWidget);
    expect(_inCard(find.text('YOU WON THE ROUND!')), findsOneWidget);
    expect(_inCard(find.text('Filled the whole mold first')), findsOneWidget);
    expect(_inCard(find.text('You')), findsOneWidget, reason: 'the series so far');
    expect(_inCard(find.byType(WinPips)), findsNWidgets(2), reason: 'my two wins and sam\'s one');
    expect(find.byType(HammerStrike), findsNothing, reason: 'the hammer has lifted away');

    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(RoundFlash), findsNothing);
    expect(_inBanner(find.text('YOU WON THE ROUND!')), findsOneWidget);
    expect(_inBanner(find.text('Filled the whole mold first')), findsOneWidget);
    expect(find.byType(RivalMolds), findsOneWidget, reason: 'the boards stay in view below');
    expect(find.text('Round 4 of up to 5'), findsOneWidget);
  });

  testWidgets("a rival's win lands quietly, with no hammer", (tester) async {
    final s = _clash(
      winner: 'u2',
      how: 'timeout',
      molds: {
        'u1': [0],
        'u2': [0, 1],
        'u3': [],
        'u4': [],
      },
      tally: {'u1': 1, 'u2': 2, 'u3': 0, 'u4': 0},
    );
    await _pump(tester, s);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(tester.takeException(), isNull);
    expect(_inCard(find.text('sam won the round')), findsOneWidget);
    expect(_inCard(find.text('Most letters when time ran out (5/7)')), findsOneWidget);
    expect(find.byType(HammerStrike), findsNothing);

    await _settle(tester);
    expect(_inBanner(find.text('sam won the round')), findsOneWidget);
  });

  testWidgets('a round nobody wins says so, and why', (tester) async {
    final s = _clash(
      winner: null,
      how: 'none',
      molds: {'u1': [], 'u2': [], 'u3': [], 'u4': []},
      tally: {'u1': 1, 'u2': 1, 'u3': 0, 'u4': 0},
    );
    await _pump(tester, s);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(tester.takeException(), isNull);
    expect(_inCard(find.text('No winner this round')), findsOneWidget);
    expect(_inCard(find.text('Nobody filled a letter')), findsOneWidget);
    expect(find.byType(HammerStrike), findsNothing);

    // Survival: a word melted before anyone had a letter.
    final melt = RoundResult(
      s,
      VsRoundEnd.fromJson(
        _endJson(winner: null, how: 'none', molds: {'u1': [], 'u4': []}, melted: {'id': 'u4', 'slot': 1}),
      ),
    );
    expect(melt.how, "Bo's heated word melted before anyone filled a letter");
  });

  testWidgets('sudden death says so, even back in the forge without that round', (tester) async {
    final s = _clash(
      round: 6,
      sudden: true,
      winner: 'u2',
      how: 'finished',
      molds: {
        'u1': [0],
        'u2': [0, 1, 2],
      },
      tally: {'u1': 2, 'u2': 3, 'u3': 0, 'u4': 0},
      deciding: true,
    );
    s.seriesEnd = _seriesEnd('u2');
    await _pump(tester, s);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(tester.takeException(), isNull);
    expect(_inCard(find.text('SUDDEN DEATH')), findsOneWidget);
    expect(_inCard(find.text('sam won the round')), findsOneWidget);
    expect(_inCard(find.text('sam wins the series')), findsOneWidget);

    // Rejoined during the standings: no ROUND_START, but round 6 of a best of 5 is sudden death.
    s.round = null;
    expect(RoundResult(s, s.standings!).suddenDeath, isTrue);
    expect(
      RoundResult(s, VsRoundEnd.fromJson(_endJson(round: 4, winner: 'u2', how: 'finished', molds: {}))).overline,
      'Round 4',
    );
  });

  testWidgets('survival: who melted, and who survived', (tester) async {
    final s = _clash(
      winner: 'u1',
      how: 'survived',
      molds: {
        'u1': [0, 1],
        'u2': [0],
        'u3': [],
        'u4': [2],
      },
      tally: {'u1': 2, 'u2': 1, 'u3': 0, 'u4': 0},
      melted: {'id': 'u4', 'slot': 0},
    );
    await _pump(tester, s);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(tester.takeException(), isNull);
    expect(_inCard(find.text('YOU WON THE ROUND!')), findsOneWidget);
    expect(_inCard(find.text("Bo's heated word melted · survived with the most letters (5/7)")), findsOneWidget);

    // My own word melting.
    final mine = RoundResult(
      s,
      VsRoundEnd.fromJson(
        _endJson(
          winner: 'u2',
          how: 'survived',
          molds: {
            'u1': [1],
            'u2': [2],
          },
          melted: {'id': 'u1', 'slot': 0},
        ),
      ),
    );
    expect(mine.how, 'Your heated word melted · survived with the most letters (3/7)');
    expect(mine.won, isFalse);
  });

  testWidgets('the round that decides the series: its result comes in with SERIES_END', (tester) async {
    final s = _clash(
      round: 4,
      winner: 'u1',
      how: 'finished',
      molds: {
        'u1': [0, 1, 2],
        'u2': [0],
        'u3': [],
        'u4': [],
      },
      tally: {'u1': 3, 'u2': 1, 'u3': 0, 'u4': 0},
      deciding: true,
    );
    await _pump(tester, s);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(_inCard(find.text('YOU WON THE ROUND!')), findsOneWidget);
    expect(_inCard(find.text('YOU WIN THE SERIES!')), findsNothing, reason: 'not before SERIES_END');

    s.seriesEnd = _seriesEnd('u1');
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(_inCard(find.text('YOU WIN THE SERIES!')), findsOneWidget);

    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(_inBanner(find.text('YOU WIN THE SERIES!')), findsOneWidget);
    expect(_inBanner(find.text('You won the round. Filled the whole mold first')), findsOneWidget);
    expect(find.text('See the results'), findsOneWidget);
    expect(find.textContaining('Round 5'), findsNothing, reason: 'no next round');

    // Someone else's series.
    s.seriesEnd = _seriesEnd('u3');
    await tester.pump(const Duration(milliseconds: 300));
    expect(_inBanner(find.text('Kit wins the series')), findsOneWidget);
  });

  testWidgets('a tap settles the card straight away', (tester) async {
    final s = _clash(
      winner: 'u1',
      how: 'finished',
      molds: {
        'u1': [0, 1, 2],
        'u2': [0],
      },
      tally: {'u1': 2, 'u2': 1},
    );
    await _pump(tester, s);
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.tap(find.byType(RoundFlash));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.byType(RoundFlash), findsNothing);
    expect(_inBanner(find.text('YOU WON THE ROUND!')), findsOneWidget);
  });

  testWidgets('with reduced motion the card shows without the hammer, then gives way', (tester) async {
    final s = _clash(
      winner: 'u1',
      how: 'finished',
      molds: {
        'u1': [0, 1, 2],
        'u2': [0],
      },
      tally: {'u1': 2, 'u2': 1},
    );
    await _pump(tester, s, calm: true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(_inCard(find.text('YOU WON THE ROUND!')), findsOneWidget);
    expect(_inCard(find.text('Filled the whole mold first')), findsOneWidget);
    expect(find.byType(HammerStrike), findsNothing);

    await tester.pump(const Duration(seconds: 4));
    expect(find.byType(RoundFlash), findsNothing);
    expect(_inBanner(find.text('YOU WON THE ROUND!')), findsOneWidget);
  });

  testWidgets('after the round that decides the series: everyone\'s molds, then the podium on "See the results"', (
    tester,
  ) async {
    final socket = await _openRoom(tester);
    _decidingRound(socket);
    await tester.pump();
    await tester.pump();
    expect(find.byType(VsStandingsView), findsOneWidget, reason: 'the standings, not the round');
    expect(_inCard(find.text('YOU WON THE ROUND!')), findsOneWidget);
    expect(find.text('See the results'), findsOneWidget);
    expect(find.textContaining('The podium in'), findsOneWidget);

    // The series' results follow, as the server sends them; the standings stay up.
    _seriesOver(socket);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
    expect(find.byType(RoundFlash), findsNothing, reason: 'the card has settled');
    expect(_inBanner(find.text('YOU WIN THE SERIES!')), findsOneWidget);
    final molds = find.byType(RivalMolds);
    expect(molds, findsOneWidget);
    for (final name in ['You', 'sam', 'Kit', 'Bo']) {
      expect(
        find.descendant(of: molds, matching: find.text(name)),
        findsOneWidget,
        reason: "$name's mold",
      );
    }
    expect(
      find.descendant(of: molds, matching: find.text('5/7')),
      findsOneWidget,
      reason: "sam's",
    );
    expect(find.byType(VsResultsView), findsNothing);

    await tester.tap(find.text('See the results'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byType(VsResultsView), findsOneWidget);
    expect(find.byType(VsStandingsView), findsNothing);
  });

  testWidgets('after the round that decides the series, the podium comes by itself', (tester) async {
    final socket = await _openRoom(tester);
    _decidingRound(socket);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    _seriesOver(socket);
    await tester.pump();
    await tester.pump(const Duration(seconds: 7));
    expect(find.byType(VsStandingsView), findsOneWidget, reason: 'still looking at the molds');

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(VsResultsView), findsOneWidget);
  });
}
