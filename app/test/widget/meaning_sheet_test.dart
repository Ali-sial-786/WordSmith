import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/lexicon.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/coop/results_view.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/coop_session.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/net/api_client.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/widgets/meaning_sheet.dart';

/// An offline lexicon that only knows FORGE.
class _Lexicon extends Lexicon {
  _Lexicon() : super(rootBundle);

  @override
  Future<Meaning?> lookup(String word) async =>
      word.toUpperCase() == 'FORGE' ? const Meaning(word: 'FORGE', senses: [Sense('v', 'create by hammering')]) : null;
}

/// The server's `GET /v1/define`: knows TUYERE (from Wiktionary), not
/// anything else. [down] makes it unreachable; [gate] holds answers back.
class _Dictionary {
  final asked = <http.Request>[];
  bool down = false;
  Completer<void>? gate;

  ApiClient client() =>
      ApiClient(baseUrl: 'https://forge.test', token: () async => 'token-u1', client: MockClient(_handle));

  Future<http.Response> _handle(http.Request req) async {
    asked.add(req);
    await gate?.future;
    if (down) throw http.ClientException('offline');
    if (req.url.path == '/v1/define/tuyere') {
      return http.Response(
        jsonEncode({
          'word': 'tuyere',
          'senses': [
            {'pos': 'n', 'gloss': 'A nozzle through which air is blown into a furnace or forge.'},
            {'pos': 'n', 'gloss': 'The opening in the hearth where such a nozzle enters.'},
          ],
          'source': 'wiktionary',
        }),
        200,
      );
    }
    return http.Response(jsonEncode({'error': 'word_not_found'}), 404);
  }
}

Future<void> _pump(WidgetTester tester, Widget child, {_Dictionary? server}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(const Size(412, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storeProvider.overrideWithValue(store),
        lexiconProvider.overrideWithValue(_Lexicon()),
        apiClientProvider.overrideWithValue(server?.client()),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
}

/// A button that opens [word]'s meaning.
Widget _opener(String word) => Builder(
  builder: (context) => Center(
    child: TextButton(onPressed: () => showMeanings(context, [word]), child: const Text('look up')),
  ),
);

/// Opens the sheet and lets both lookups (offline, then online) answer.
Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('look up'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _close(WidgetTester tester) async {
  await tester.tapAt(const Offset(200, 20));
  await tester.pumpAndSettle();
  expect(find.byType(MeaningView), findsNothing);
}

const _notInLexicon = "This one isn't in the forge's lexicon, but it's a real word.";
const _searching = "Not in the forge's lexicon. Looking further afield…";

void main() {
  testWidgets('a word in the lexicon is shown from it, without asking the server', (tester) async {
    final server = _Dictionary();
    await _pump(tester, _opener('FORGE'), server: server);
    await _open(tester);
    expect(find.text('verb  create by hammering', findRichText: true), findsOneWidget);
    expect(find.textContaining('From ', findRichText: true), findsNothing);
    expect(server.asked, isEmpty);
  });

  testWidgets('a word the lexicon lacks is looked up online, once a session', (tester) async {
    final server = _Dictionary()..gate = Completer();
    await _pump(tester, _opener('TUYERE'), server: server);
    await _open(tester);
    expect(find.text(_searching), findsOneWidget);

    server.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text(_searching), findsNothing);
    expect(
      find.text('noun  A nozzle through which air is blown into a furnace or forge.', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('noun  The opening in the hearth where such a nozzle enters.', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Wiktionary'), findsOneWidget);
    expect(find.text('CC BY-SA 4.0'), findsOneWidget);
    expect(find.text(', shortened · '), findsOneWidget);
    // Signed out works too: the lookup carries no token.
    expect(server.asked.single.url.path, '/v1/define/tuyere');
    expect(server.asked.single.headers['Authorization'], isNull);

    await _close(tester);
    await _open(tester);
    expect(find.text('Wiktionary'), findsOneWidget);
    expect(server.asked, hasLength(1), reason: 'kept for the session');
  });

  testWidgets("a word no dictionary has shows today's message, and isn't asked again", (tester) async {
    final server = _Dictionary();
    await _pump(tester, _opener('QWZX'), server: server);
    await _open(tester);
    expect(find.text(_notInLexicon), findsOneWidget);
    await _close(tester);
    await _open(tester);
    expect(find.text(_notInLexicon), findsOneWidget);
    expect(server.asked, hasLength(1));
  });

  testWidgets("offline shows today's message, and tries again next time", (tester) async {
    final server = _Dictionary()..down = true;
    await _pump(tester, _opener('TUYERE'), server: server);
    await _open(tester);
    expect(find.text(_notInLexicon), findsOneWidget);
    expect(find.text(_searching), findsNothing);

    server.down = false;
    await _close(tester);
    await _open(tester);
    expect(find.text('Wiktionary'), findsOneWidget);
    expect(server.asked, hasLength(2));
  });

  testWidgets("without a server it's today's message", (tester) async {
    await _pump(tester, _opener('TUYERE'));
    await _open(tester);
    expect(find.text(_notInLexicon), findsOneWidget);
  });

  group('co-op results', () {
    // CAT across the top, COT down the left (both forged) and TOE down the
    // right, which nobody found.
    final start = RoundStart.fromJson({
      'round': 1,
      'heat': 3,
      'startsAt': 0,
      'endsAt': 0,
      'letters': 'CATOE',
      'cols': 3,
      'rows': 3,
      'slots': [
        {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 3},
        {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 3},
        {'slot': 2, 'x': 2, 'y': 0, 'd': 'd', 'len': 3},
      ],
    });

    CoopSession session() {
      final lobby = RoomLobby.fromJson({
        'code': 'K7Q2AB',
        'mode': 'coop',
        'phase': 'results',
        'hostId': 'u1',
        'heat': 3,
        'players': [
          for (final (i, name) in ['Ada', 'sam'].indexed)
            {'id': 'u${i + 1}', 'username': name, 'avatar': 'avatar_01', 'level': 3, 'color': i, 'connected': true},
        ],
      });
      final end = RoundEnd.fromJson({
        'reason': 'timeout',
        'teamScore': 60,
        'filled': 7,
        'total': 9,
        'stars': 1,
        'players': [
          {'id': 'u1', 'points': 30, 'words': 1, 'longest': 'CAT'},
          {'id': 'u2', 'points': 30, 'words': 1, 'longest': 'COT', 'bonus': 1},
        ],
        'answers': [
          {'slot': 2, 'word': 'TOE'},
        ],
      });
      final s =
          CoopSession(
              client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'K7Q2AB', token: () async => 't'),
              me: 'u1',
            )
            ..lobby = lobby
            ..round = start
            ..mold = RemoteMold(start, () => lobby)
            ..results = end;
      s.mold!
        ..claim(0, 'CAT', 'u1')
        ..claim(1, 'COT', 'u2')
        ..showAnswers(end.answers);
      addTearDown(s.dispose);
      return s;
    }

    Finder inSheet(String text) => find.descendant(of: find.byType(MeaningView), matching: find.text(text));

    testWidgets('a word nobody found can be tapped for its meaning', (tester) async {
      await _pump(tester, ResultsView(session: session(), cues: MoldCues(), onLeave: () {}));
      await tester.tap(find.byKey(const ValueKey((x: 2, y: 2))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(inSheet('TOE'), findsOneWidget);
    });

    testWidgets("a smith's longest word can be tapped for its meaning", (tester) async {
      await _pump(tester, ResultsView(session: session(), cues: MoldCues(), onLeave: () {}));
      expect(find.textContaining('1 word · 1 bonus · longest ', findRichText: true), findsOneWidget);
      await tester.tap(find.text('COT'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(inSheet('COT'), findsOneWidget);
    });
  });
}
