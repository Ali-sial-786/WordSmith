import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/engine/board.dart';
import 'package:wordsmith/engine/hints.dart';
import 'package:wordsmith/engine/pickups.dart';
import 'package:wordsmith/engine/puzzle.dart';

import '../fixtures/puzzles.dart';

void main() {
  late Puzzle puzzle;
  setUp(() => puzzle = tearPuzzle());

  test('parses cells in row-then-column order', () {
    expect(puzzle.letterCount, 9);
    expect(puzzle.cells.first, (x: 0, y: 0));
    expect(puzzle.cells[4], (x: 1, y: 1));
    expect(puzzle.cells.last, (x: 3, y: 3));
    expect(puzzle.letterAt[(x: 3, y: 0)], 'R');
    expect(puzzle.slotsAt[(x: 1, y: 0)]!.map((s) => s.word), ['TEAR', 'EAT']);
  });

  test('rejects puzzles whose crossings disagree', () {
    final bad = tearJson();
    (bad['words'] as List)[1] = {'w': 'OAT', 'x': 1, 'y': 0, 'd': 'd'};
    expect(() => Puzzle.fromJson(bad), throwsFormatException);
  });

  test('forging, repeats, bonus and invalid words', () {
    final board = Board(puzzle);
    final eat = board.submit('eat');
    expect(eat.outcome, SubmitOutcome.found);
    expect(eat.newCells, [(x: 1, y: 0), (x: 1, y: 1), (x: 1, y: 2)]);

    final tear = board.submit('TEAR');
    expect(tear.outcome, SubmitOutcome.found);
    expect(tear.newCells, [(x: 0, y: 0), (x: 2, y: 0), (x: 3, y: 0)],
        reason: 'E was already filled by EAT');

    expect(board.submit('EAT').outcome, SubmitOutcome.alreadyFound);
    expect(board.submit('art').outcome, SubmitOutcome.bonus);
    expect(board.submit('ART').outcome, SubmitOutcome.alreadyBonus);
    expect(board.submit('TRAE').outcome, SubmitOutcome.invalid);
    expect(board.submit('at').outcome, SubmitOutcome.tooShort);
    expect(board.isComplete, isFalse);

    final rate = board.submit('rate');
    expect(rate.newCells.length, 3);
    expect(board.isComplete, isTrue);
    expect(board.foundSlots, {0, 1, 2});
  });

  test('revealing every letter of a word completes it automatically', () {
    final board = Board(puzzle)..submit('TEAR');
    final r = board.reveal([(x: 3, y: 1), (x: 3, y: 2), (x: 3, y: 3)]);
    expect(r.cells.length, 3);
    expect(r.completedSlots.map((s) => s.word), ['RATE']);
    expect(board.autoSlots, {2});
    expect(board.reveal([(x: 3, y: 1)]).isEmpty, isTrue,
        reason: 'already-filled cells are not revealed twice');
  });

  test('a crossing word fills when its last gap is forged', () {
    final board = Board(puzzle)..reveal([(x: 0, y: 0), (x: 2, y: 0)]);
    board.submit('EAT');
    final rate = board.submit('RATE');
    expect(rate.completedSlots.map((s) => s.word), ['RATE', 'TEAR']);
    expect(board.autoSlots, {0});
    expect(board.isComplete, isTrue);
  });

  test('pickups are collected when a word covering them completes', () {
    // Cell index 2 is (2,0), the A of TEAR.
    final board = Board(puzzle, pickups: const [Pickup(2, HintKind.chisel)]);
    expect(board.pickupAt((x: 2, y: 0))?.kind, HintKind.chisel);
    expect(board.submit('EAT').collected, isEmpty);
    expect(board.submit('TEAR').collected, [const Pickup(2, HintKind.chisel)]);
    expect(board.pickupAt((x: 2, y: 0)), isNull);
    expect(board.collectedPickups, {0});
  });

  test('hint targets only pick empty cells', () {
    final board = Board(puzzle)..submit('TEAR');
    final rng = Random(4);
    for (var i = 0; i < 20; i++) {
      expect(board.isFilled(board.hammerTarget(rng)!), isFalse);
    }
    final sparks = board.sparksTargets(rng);
    expect(sparks.length, 5, reason: '5 of the 5 empty cells');
    expect(sparks.toSet().length, 5);
    expect(sparks.every((c) => !board.isFilled(c)), isTrue);
    board.reveal(sparks);
    expect(board.isComplete, isTrue);
    expect(board.hammerTarget(rng), isNull);
  });
}
