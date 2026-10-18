// Renders the meaning sheet's online definitions to PNGs with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots/dictionary_shots_test.dart --update-goldens
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/forge_background.dart';
import 'package:wordsmith/ui/widgets/meaning_sheet.dart';

import 'shot_fonts.dart';

/// An offline lexicon that has none of the shots' words.
class _EmptyLexicon extends Lexicon {
  _EmptyLexicon() : super(rootBundle);

  @override
  Future<Meaning?> lookup(String word) async => null;
}

/// `GET /v1/define`, answering once [gate] opens.
ApiClient _server(Completer<void> gate) => ApiClient(
  baseUrl: 'https://forge.test',
  token: () async => null,
  client: MockClient((req) async {
    await gate.future;
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
  }),
);

Future<void> _pump(WidgetTester tester, Widget child, {ApiClient? api}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(const Size(412, 892));
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storeProvider.overrideWithValue(store),
        lexiconProvider.overrideWithValue(_EmptyLexicon()),
        apiClientProvider.overrideWithValue(api),
      ],
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
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

/// A button behind the sheet that opens [word]'s meaning.
Widget _opener(String word) => Builder(
  builder: (context) => Center(
    child: TextButton(onPressed: () => showMeanings(context, [word]), child: const Text('look up')),
  ),
);

/// A co-op round that ran out of time: TON and NET nobody found.
CoopSession _coopResults() {
  final slots = [
    {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 5},
    {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 4},
    {'slot': 2, 'x': 4, 'y': 0, 'd': 'd', 'len': 5},
    {'slot': 3, 'x': 0, 'y': 3, 'd': 'a', 'len': 3},
    {'slot': 4, 'x': 2, 'y': 2, 'd': 'a', 'len': 3},
  ];
  final lobby = RoomLobby.fromJson({
    'code': 'K7Q2AB',
    'mode': 'coop',
    'phase': 'results',
    'hostId': 'u1',
    'heat': 3,
    'players': [
      for (final (i, name) in ['Ada', 'sam', 'Kit'].indexed)
        {
          'id': 'u${i + 1}',
          'username': name,
          'avatar': 'avatar_0${i + 3}',
          'level': 6 + i,
          'color': i,
          'connected': true,
        },
    ],
  });
  final start = RoundStart.fromJson({
    'round': 1,
    'heat': 3,
    'startsAt': 0,
    'endsAt': 0,
    'letters': 'STONEA',
    'cols': 5,
    'rows': 5,
    'slots': slots,
  });
  final end = RoundEnd.fromJson({
    'reason': 'timeout',
    'teamScore': 140,
    'filled': 12,
    'total': 16,
    'stars': 1,
    'players': [
      {'id': 'u1', 'points': 70, 'words': 1, 'longest': 'STONE', 'bonus': 2},
      {'id': 'u2', 'points': 40, 'words': 1, 'longest': 'EATEN'},
      {'id': 'u3', 'points': 30, 'words': 1, 'longest': 'SEAT'},
    ],
    'answers': [
      {'slot': 3, 'word': 'TON'},
      {'slot': 4, 'word': 'NET'},
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
    ..claim(0, 'STONE', 'u1')
    ..claim(2, 'EATEN', 'u2')
    ..claim(1, 'SEAT', 'u3')
    ..showAnswers(end.answers);
  return s;
}

void main() {
  setUpAll(loadShotFonts);

  testWidgets('meaning looked up online', (tester) async {
    final gate = Completer<void>()..complete();
    await _pump(tester, _opener('TUYERE'), api: _server(gate));
    await tester.tap(find.text('look up'));
    await _settle(tester);
    await _shot('meaning_online');
  });

  testWidgets('meaning loading online', (tester) async {
    final gate = Completer<void>();
    await _pump(tester, _opener('TUYERE'), api: _server(gate));
    await tester.tap(find.text('look up'));
    await _settle(tester);
    await _shot('meaning_loading');
    gate.complete();
    await _settle(tester);
  });

  testWidgets('co-op results words', (tester) async {
    await _pump(tester, ResultsView(session: _coopResults(), cues: MoldCues(), onLeave: () {}));
    await _shot('coop_results_words');
  });
}
