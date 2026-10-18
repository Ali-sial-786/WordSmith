// Renders the Versus round review to PNGs with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots/review_shots_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/vs/round_review.dart';
import 'package:wordsmith/features/vs/vs_results_view.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/forge_background.dart';

import '../test/fixtures/vs_review.dart';

Future<void> _font(String family, Future<ByteData> data) async {
  final loader = FontLoader(family)..addFont(data);
  await loader.load();
}

/// The round's page scrolled down by [scroll].
Future<void> _shoot(WidgetTester tester, String name, Widget child, {double scroll = 0}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(const Size(412, 892));
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
            dim: 0.7,
            fire: 0.0,
            child: SafeArea(child: child),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
  await tester.pump(const Duration(milliseconds: 1200));
  if (scroll > 0) {
    final page = find.byWidgetPredicate((w) => w is ListView && w.scrollDirection == Axis.vertical);
    final position = tester
        .state<ScrollableState>(find.descendant(of: page, matching: find.byType(Scrollable)))
        .position;
    position.jumpTo(scroll.clamp(0, position.maxScrollExtent));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pump(const Duration(milliseconds: 100));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
}

Widget _review(SeriesEnd series, int round, {int players = 4}) {
  final s = reviewSession(players: players)..seriesEnd = series;
  return RoundReview(session: s, series: series, round: round, onPodium: () {});
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

  for (final (name, scroll) in [('vs_review_classic', 0.0), ('vs_review_classic_bins', 900.0)]) {
    testWidgets(name.replaceAll('_', ' '), (tester) async {
      await _shoot(tester, name, _review(classicSeries(), 3), scroll: scroll);
    });
  }

  for (final (name, scroll) in [('vs_review_survival_melt', 0.0), ('vs_review_survival_melt_bins', 900.0)]) {
    testWidgets(name.replaceAll('_', ' '), (tester) async {
      await _shoot(tester, name, _review(survivalSeries(), 2), scroll: scroll);
    });
  }

  testWidgets('vs review nothing found', (tester) async {
    await _shoot(tester, 'vs_review_nothing', _review(classicSeries(), 2));
  });

  for (final (name, round) in [('vs_review_long', 12), ('vs_review_long_middle', 6)]) {
    testWidgets(name.replaceAll('_', ' '), (tester) async {
      await _shoot(tester, name, _review(longSeries(), round, players: 5));
    });
  }

  testWidgets('vs review older server', (tester) async {
    final series = reviewSeries([
      reviewRound(
        1,
        winner: 'u2',
        words: false,
        molds: {
          'u1': [0, 1],
          'u2': [0, 1, 3],
          'u3': [2],
          'u4': [],
        },
      ),
    ]);
    await _shoot(tester, 'vs_review_older_server', _review(series, 1));
  });

  testWidgets('vs podium with the review hint', (tester) async {
    final s = reviewSession()..seriesEnd = classicSeries();
    await _shoot(tester, 'vs_review_podium', VsResultsView(session: s, onLeave: () {}));
  });
}
