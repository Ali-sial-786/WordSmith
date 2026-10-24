import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/data/history.dart';
import 'package:wordsmith/engine/board.dart';
import 'package:wordsmith/game/history_records.dart';
import 'package:wordsmith/game/word_history.dart';

import '../fixtures/puzzles.dart';
import '../fixtures/vs_review.dart';

List<String> _words(List<WordEntry> entries) => [for (final e in entries) e.word];

void main() {
  test('every game word and Scrap Bin word in the history, newest game first', () {
    final vs = reviewSession();
    addTearDown(vs.dispose);
    final board = tearPuzzle();
    final history = [
      // Out of order on purpose: the newest game goes first whatever the list says.
      PlayRecord(
        id: 'campaign-1',
        kind: PlayKind.campaign,
        at: 1000,
        title: 'Tin',
        subtitle: 'Puzzle 1 of 12',
        boards: [
          PlayedBoard.fromBoard(Board(board, foundSlots: [0, 2], autoSlots: [1], bonusFound: ['ART'])),
        ],
      ),
      vsRecord(vs, classicSeries(), at: 4000)!,
      PlayRecord(
        id: 'coop-1',
        kind: PlayKind.coop,
        at: 3000,
        title: 'Co-op',
        subtitle: 'With 1 smith',
        boards: [
          PlayedBoard(puzzle: board, found: {0, 2}, owners: {0: 'u2', 2: 'me'}, auto: {1}, bonus: ['TEA', 'ART']),
        ],
        me: 'me',
        result: {
          'scrap': ['ART'],
        },
      ),
      PlayRecord(
        id: 'crucible-1',
        kind: PlayKind.crucible,
        at: 2000,
        title: 'The Crucible',
        subtitle: 'Reached puzzle 2',
        boards: [
          PlayedBoard.fromBoard(Board(board, foundSlots: [1])),
          PlayedBoard.fromBoard(Board(board, foundSlots: [2], bonusFound: ['TEA'])),
        ],
      ),
    ];

    final words = WordHistory.from(history);
    expect(_words(words.game), [
      // Versus, round 4 first: my whole mold, then round 3's three (round 2 I forged nothing), then round 1.
      ...reviewWords,
      'STONE', 'SEAT', 'TONES',
      ...reviewWords,
      // Co-op: only the word I forged, not sam's nor the one the forge filled in.
      'RATE',
      // The Crucible: its second puzzle, then its first.
      'RATE', 'EAT',
      // The campaign: found words, not the one a hammer filled in.
      'TEAR', 'RATE',
    ]);
    expect(_words(words.scrap), [
      'TEN', 'NOTE', 'TOE', 'EAST', 'ONE',
      // Only the co-op bonus word I found; the Crucible has no Scrap Bin.
      'ART',
      'ART',
    ]);
    expect(words.game.first.from, 'Versus');
    expect(words.game.first.kind, PlayKind.vs);
    expect(words.game.first.at, 4000);
    expect(words.scrap.last.from, 'Tin');
    expect(words.scrap.last.at, 1000);
  });

  test('a co-op game from before 0.8 has no Scrap Bin words, and a broken series none at all', () {
    final words = WordHistory.from([
      PlayRecord(
        id: 'coop-old',
        kind: PlayKind.coop,
        at: 2,
        title: 'Co-op',
        subtitle: 'With 1 smith',
        boards: [
          PlayedBoard(puzzle: tearPuzzle(), found: {0}, owners: {0: 'me'}, bonus: ['TEA']),
        ],
        me: 'me',
      ),
      PlayRecord(id: 'vs-broken', kind: PlayKind.vs, at: 1, title: 'Versus', subtitle: '', me: 'me', series: {'x': 1}),
    ]);
    expect(_words(words.game), ['TEAR']);
    expect(words.scrap, isEmpty);
  });
}
