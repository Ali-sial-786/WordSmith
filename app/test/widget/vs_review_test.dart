import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/vs/round_review.dart';
import 'package:wordsmith/features/vs/series_summary.dart';
import 'package:wordsmith/features/vs/vs_results_view.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/theme/palette.dart';
import 'package:wordsmith/ui/widgets/meaning_sheet.dart';

import '../fixtures/vs_review.dart';

/// A session the test can move on, as a rematch would.
class _Session extends VsSession {
  _Session({super.me = 'u1', int players = 4})
    : super(
        client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'),
      ) {
    lobby = reviewLobby(players: players);
  }

  /// The host's rematch: a new countdown, and the series' results are gone.
  void rematch() {
    seriesEnd = null;
    lobby = reviewLobby(phase: 'countdown');
    notifyListeners();
  }
}

_Session _session(SeriesEnd series, {String me = 'u1', int players = 4}) {
  final s = _Session(me: me, players: players)..seriesEnd = series;
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

Future<void> _review(WidgetTester tester, VsSession s, {required int round}) =>
    _pump(tester, RoundReview(session: s, series: s.seriesEnd!, round: round, onPodium: () {}));

/// The open round's page, to scroll.
final _page = find.descendant(
  of: find.byType(PageView),
  matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down),
);

/// Scrolls [scrollable] (the open round's page unless given) until [finder] is built, then into view.
Future<void> _scrollTo(WidgetTester tester, Finder finder, {Finder? scrollable}) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: scrollable ?? _page.first);
  await tester.ensureVisible(finder);
  await tester.pump();
}

/// Closes the meaning sheet (its lookup may still be spinning, so no settling).
Future<void> _closeSheet(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator).last).pop();
  await tester.pump(const Duration(seconds: 1));
}

/// A round's row on the podium, by its number (the first match: a win count can read the same).
Finder _row(int round) => find.descendant(of: find.byType(SeriesSummary), matching: find.text('$round')).first;

void main() {
  testWidgets('a round on the podium opens for a look back, and the podium comes back', (tester) async {
    final s = _session(classicSeries());
    await _pump(tester, VsResultsView(session: s, onLeave: () {}));
    await _scrollTo(tester, _row(3), scrollable: find.byType(Scrollable).first);
    expect(find.text('Tap a round for its words, molds and Scrap Bins'), findsOneWidget);
    await tester.tap(_row(3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(RoundReview), findsOneWidget);
    expect(find.text('Round 3'), findsOneWidget);
    expect(find.text('You found 3 of 5'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('review-podium')));
    await tester.pumpAndSettle();
    expect(find.byType(RoundReview), findsNothing);
    expect(find.text('Round by round'), findsOneWidget);

    // The phone's back works too.
    await tester.tap(_row(1));
    await tester.pumpAndSettle();
    expect(find.text('Round 1'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(RoundReview), findsNothing);
    expect(find.text('Round by round'), findsOneWidget);
  });

  testWidgets('steps from round to round, by the buttons, the strip and a swipe', (tester) async {
    await _review(tester, _session(classicSeries()), round: 1);
    expect(find.text('Round 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('review-prev')), findsNothing, reason: 'nothing before the first');
    expect(find.text('You found 5 of 5'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('review-next')));
    await tester.pumpAndSettle();
    expect(find.text('Round 2'), findsOneWidget);
    expect(find.text('You found 0 of 5'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('review-prev')));
    await tester.pumpAndSettle();
    expect(find.text('Round 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('review-token-4')));
    await tester.pumpAndSettle();
    expect(find.text('Round 4'), findsOneWidget);
    expect(find.byKey(const ValueKey('review-next')), findsNothing, reason: 'nothing after the last');

    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('Round 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tells the words I forged from the ones I missed, on the mold and below it', (tester) async {
    await _review(tester, _session(classicSeries()), round: 3);
    expect(tester.takeException(), isNull);
    // STONE, SEAT and TONES forged; EATS and NET missed.
    expect(find.text('You found 3 of 5'), findsOneWidget);
    expect(find.text('12/16 letters'), findsOneWidget);
    // On the mold: forged cells are metal, missed ones ghosts with their letters.
    expect(find.byKey(const ValueKey(('forged', (x: 0, y: 0)))), findsOneWidget);
    expect(find.byKey(const ValueKey(('forged', (x: 4, y: 3)))), findsOneWidget, reason: 'the S of TONES');
    for (final cell in [(x: 4, y: 1), (x: 4, y: 2), (x: 2, y: 4), (x: 2, y: 5)]) {
      final ghost = find.byKey(ValueKey(('missed', cell)));
      expect(ghost, findsOneWidget);
      expect(find.descendant(of: ghost, matching: find.byType(MoldCell)), findsNothing);
    }
    expect(
      find.descendant(of: find.byKey(const ValueKey(('missed', (x: 4, y: 1)))), matching: find.text('A')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey(('missed', (x: 2, y: 5)))), matching: find.text('T')),
      findsOneWidget,
    );

    // Below it, each group has its words.
    await _scrollTo(tester, find.text('Forged · 3'));
    final forged = find.ancestor(of: find.text('Forged · 3'), matching: find.byType(Column)).first;
    for (final w in ['STONE', 'SEAT', 'TONES']) {
      expect(find.descendant(of: forged, matching: find.byKey(ValueKey('word-$w'))), findsOneWidget);
    }
    await _scrollTo(tester, find.text('Missed · 2'));
    final missed = find.ancestor(of: find.text('Missed · 2'), matching: find.byType(Column)).first;
    for (final w in ['EATS', 'NET']) {
      expect(find.descendant(of: missed, matching: find.byKey(ValueKey('word-$w'))), findsOneWidget);
    }
    // sam (gold) and Kit (verdigris) both had EATS.
    final dots = tester
        .widgetList<Container>(
          find.descendant(of: find.byKey(const ValueKey('word-EATS')), matching: find.byType(Container)),
        )
        .map((c) => (c.decoration as BoxDecoration?)?.color)
        .where((c) => c == Palette.player(1) || c == Palette.player(2));
    expect(dots, hasLength(2));
  });

  testWidgets('shows my Scrap Bin and my rivals\'', (tester) async {
    await _review(tester, _session(classicSeries()), round: 3);
    await _scrollTo(tester, find.byKey(const ValueKey('bin-u4-ANTE')));
    expect(tester.takeException(), isNull);
    expect(find.text('Scrap Bins'), findsOneWidget);
    for (final w in ['NOTE', 'TOE', 'EAST']) {
      expect(find.byKey(ValueKey('bin-u1-$w')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('bin-u2-ONE')), findsOneWidget);
    expect(find.text('3 bonus words'), findsOneWidget);
    expect(find.text('1 bonus word'), findsOneWidget);
    expect(find.text('no bonus words'), findsOneWidget, reason: 'Kit found none');
    expect(find.text('5 bonus words'), findsOneWidget);
  });

  testWidgets('every word opens its meaning: on the mold, below it, and in a Scrap Bin', (tester) async {
    await _review(tester, _session(classicSeries()), round: 3);
    // A ghost cell on the mold, and a forged one where two words cross.
    await tester.tap(find.byKey(const ValueKey(('missed', (x: 2, y: 4)))));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(MeaningView), findsOneWidget);
    expect(tester.widget<MeaningView>(find.byType(MeaningView)).word, 'NET');
    await _closeSheet(tester);
    expect(find.byType(MeaningView), findsNothing);
    await tester.tap(find.byKey(const ValueKey(('forged', (x: 0, y: 3)))));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(ChoiceChip, 'SEAT'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'TONES'), findsOneWidget);
    await _closeSheet(tester);

    // A missed word below the mold.
    await _scrollTo(tester, find.byKey(const ValueKey('word-EATS')));
    await tester.tap(find.byKey(const ValueKey('word-EATS')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<MeaningView>(find.byType(MeaningView)).word, 'EATS');
    await _closeSheet(tester);

    // A rival's bonus word.
    await _scrollTo(tester, find.byKey(const ValueKey('bin-u4-NEAT')));
    await tester.tap(find.byKey(const ValueKey('bin-u4-NEAT')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<MeaningView>(find.byType(MeaningView)).word, 'NEAT');
    await _closeSheet(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a Survival round shows my word that melted, and the words I saved', (tester) async {
    await _review(tester, _session(survivalSeries()), round: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('Survival'), findsOneWidget);
    expect(find.textContaining('you melted', findRichText: true), findsOneWidget);
    expect(find.text('8/16 letters · 2 saved', findRichText: true), findsOneWidget);
    // NET melted: red, on the mold and below it.
    final melted = find.descendant(of: find.byKey(const ValueKey(('missed', (x: 2, y: 5)))), matching: find.text('T'));
    expect(tester.widget<Text>(melted).style?.color?.r, closeTo(Palette.quenchRed.r, 0.01));
    await _scrollTo(tester, find.byKey(const ValueKey('word-NET')));
    final net = find.descendant(of: find.byKey(const ValueKey('word-NET')), matching: find.text('NET'));
    expect(tester.widget<Text>(net).style?.color, Palette.quenchRed);
    final eats = find.descendant(of: find.byKey(const ValueKey('word-EATS')), matching: find.text('EATS'));
    expect(tester.widget<Text>(eats).style?.color, isNot(Palette.quenchRed));

    // Someone else's melt is only on their own mold.
    await tester.tap(find.byKey(const ValueKey('review-next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Kit melted', findRichText: true), findsOneWidget);
    final ghost = find.descendant(of: find.byKey(const ValueKey(('missed', (x: 4, y: 1)))), matching: find.text('A'));
    expect(tester.widget<Text>(ghost).style?.color?.r, isNot(closeTo(Palette.quenchRed.r, 0.01)));
  });

  testWidgets('a long series opens on its last round, with the strip scrolled to it', (tester) async {
    final s = _session(longSeries(), players: 5);
    await _review(tester, s, round: 12);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Round 12'), findsOneWidget);
    expect(find.text('Sudden death'), findsOneWidget);
    final token = tester.getRect(find.byKey(const ValueKey('review-token-12')));
    expect(token.right, lessThanOrEqualTo(360));
    expect(token.left, greaterThan(0));
    // Only its two racers' molds and Scrap Bins.
    await _scrollTo(tester, find.byKey(const ValueKey('bin-u2-NOTE')));
    expect(find.byKey(const ValueKey('bin-u1-TEN')), findsOneWidget);
    expect(find.text('Kit'), findsNothing);
  });

  testWidgets('someone who watched a sudden death sees its words without anything missed', (tester) async {
    await _review(tester, _session(longSeries(), me: 'u3', players: 5), round: 12);
    expect(tester.takeException(), isNull);
    expect(find.text('You watched this round'), findsOneWidget);
    expect(find.text('Ada vs sam', findRichText: true), findsOneWidget);
    expect(find.text('The words · 5'), findsOneWidget);
    expect(find.textContaining('Missed'), findsNothing);
    expect(find.byKey(const ValueKey(('missed', (x: 0, y: 0)))), findsNothing);
  });

  testWidgets('a round from an older server shows its molds, and says what it didn\'t keep', (tester) async {
    final series = reviewSeries([
      reviewRound(
        1,
        winner: 'u2',
        words: false,
        molds: {
          'u1': [0, 1],
          'u2': [0, 1, 3],
        },
      ),
    ]);
    await _review(tester, _session(series), round: 1);
    expect(tester.takeException(), isNull);
    expect(find.text('You found 2 of 5'), findsOneWidget);
    expect(find.text("This round's words weren't kept."), findsOneWidget);
    await _scrollTo(tester, find.text("This round's Scrap Bins weren't kept."));
    expect(find.text("This round's Scrap Bins weren't kept."), findsOneWidget);
  });

  testWidgets('closes when a rematch starts, a meaning sheet and all', (tester) async {
    final s = _session(classicSeries());
    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showRoundReview(context, session: s, series: s.seriesEnd!, round: 3),
          child: const Text('look back'),
        ),
      ),
    );
    await tester.tap(find.text('look back'));
    await tester.pumpAndSettle();
    expect(find.byType(RoundReview), findsOneWidget);
    await _scrollTo(tester, find.byKey(const ValueKey('word-NET')));
    await tester.tap(find.byKey(const ValueKey('word-NET')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(MeaningView), findsOneWidget);

    s.rematch();
    await tester.pumpAndSettle();
    expect(find.byType(MeaningView), findsNothing);
    expect(find.byType(RoundReview), findsNothing);
    expect(find.text('look back'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
