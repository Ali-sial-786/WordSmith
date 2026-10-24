import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/board.dart';
import 'package:wordsmith/engine/puzzle.dart';

import '../fixtures/puzzles.dart';

/// The same id with another grid, as a new campaign has at the same stage.
Puzzle _changed() => Puzzle.fromJson({
  ...tearJson(),
  'letters': 'NOTE',
  'cols': 4,
  'rows': 3,
  'words': [
    {'w': 'NOTE', 'x': 0, 'y': 0, 'd': 'a'},
    {'w': 'TON', 'x': 2, 'y': 0, 'd': 'd'},
  ],
  'bonus': ['ONE', 'TOE'],
});

SavedPuzzle _saveOn(Puzzle puzzle, {String letters = 'RTAE'}) => SavedPuzzle.fromBoard(
  stage: 1,
  board: Board(puzzle)..submit('EAT'),
  letters: letters,
  hintsUsed: const {},
  elapsedMs: 0,
  pickupSeed: 'u',
);

/// A save as older versions of the app wrote it: no grid fingerprint.
SavedPuzzle _legacy(SavedPuzzle s) => SavedPuzzle.fromJson(s.toJson()..remove('grid'));

void main() {
  test('a save fits the puzzle it was made on, and keeps its fingerprint', () {
    final saved = SavedPuzzle.fromJson(_saveOn(tearPuzzle()).toJson());
    expect(saved.fingerprint, tearPuzzle().fingerprint);
    expect(saved.fits(tearPuzzle()), isTrue);
  });

  test('a save does not fit another grid under the same id', () {
    expect(_saveOn(tearPuzzle()).fits(_changed()), isFalse);
    expect(_saveOn(_changed(), letters: 'NOTE').fits(tearPuzzle()), isFalse);
    expect(tearPuzzle().fingerprint, isNot(_changed().fingerprint));
  });

  test('an old save without a fingerprint must fit: letters, slots, cells, bonus words', () {
    final old = _legacy(_saveOn(tearPuzzle()));
    expect(old.fingerprint, isNull);
    expect(old.fits(tearPuzzle()), isTrue);
    expect(old.fits(_changed()), isFalse, reason: 'other letters');
    // Same letters, but a slot past the end, or a bonus word the puzzle doesn't have.
    final json = old.toJson();
    expect(
      SavedPuzzle.fromJson({
        ...json,
        'found': [7],
      }).fits(tearPuzzle()),
      isFalse,
    );
    expect(
      SavedPuzzle.fromJson({
        ...json,
        'bonus': ['ONE'],
      }).fits(tearPuzzle()),
      isFalse,
    );
    expect(
      SavedPuzzle.fromJson({
        ...json,
        'revealed': [
          [9, 9],
        ],
      }).fits(tearPuzzle()),
      isFalse,
    );
    expect(SavedPuzzle.fromJson({...json, 'puzzleId': 'c-0002'}).fits(tearPuzzle()), isFalse);
  });
}
