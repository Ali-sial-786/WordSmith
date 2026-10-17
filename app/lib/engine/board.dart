/// One player's view of a mold: what's been forged, revealed and collected.
library;

import 'dart:math';

import 'hints.dart';
import 'pickups.dart';
import 'puzzle.dart';
import 'words.dart';

enum SubmitOutcome {
  /// A grid word, newly forged.
  found,

  /// A valid word that isn't in the grid, newly found.
  bonus,

  /// A grid word that's already in the mold.
  alreadyFound,

  /// A bonus word already found in this puzzle.
  alreadyBonus,

  /// Not a word we accept.
  invalid,

  /// Fewer than three letters.
  tooShort,
}

class SubmitResult {
  const SubmitResult(
    this.outcome,
    this.word, {
    this.slot,
    this.completedSlots = const [],
    this.newCells = const [],
    this.collected = const [],
  });

  final SubmitOutcome outcome;
  final String word;

  /// The slot for [SubmitOutcome.found] / [SubmitOutcome.alreadyFound].
  final Slot? slot;

  /// Every slot completed by this action (the forged one plus any crossing
  /// slot whose last empty letter it filled).
  final List<Slot> completedSlots;

  /// Cells that changed from empty to filled, in word order.
  final List<CellPos> newCells;

  /// Pickups collected by this action.
  final List<Pickup> collected;
}

class RevealResult {
  const RevealResult(this.cells, this.completedSlots, this.collected);

  final List<CellPos> cells;
  final List<Slot> completedSlots;
  final List<Pickup> collected;

  bool get isEmpty => cells.isEmpty;
}

class Board {
  Board(
    this.puzzle, {
    Iterable<int> foundSlots = const [],
    Iterable<int> autoSlots = const [],
    Iterable<CellPos> revealed = const [],
    Iterable<String> bonusFound = const [],
    List<Pickup> pickups = const [],
    Iterable<int> collectedPickups = const [],
  }) : _found = {...foundSlots},
       _auto = {...autoSlots},
       _revealed = {...revealed},
       _bonusFound = {...bonusFound},
       pickups = List.unmodifiable(pickups),
       _collected = {...collectedPickups};

  final Puzzle puzzle;
  final List<Pickup> pickups;

  final Set<int> _found;
  final Set<int> _auto;
  final Set<CellPos> _revealed;
  final Set<String> _bonusFound;
  final Set<int> _collected;

  /// Slots the player forged by entering the word.
  Set<int> get foundSlots => Set.unmodifiable(_found);

  /// Slots that filled in without being typed: every letter was revealed by
  /// hints or by crossing words. They score nothing in co-op.
  Set<int> get autoSlots => Set.unmodifiable(_auto);

  /// Cells revealed by hints.
  Set<CellPos> get revealed => Set.unmodifiable(_revealed);

  Set<String> get bonusFound => Set.unmodifiable(_bonusFound);

  /// Indices (into [pickups]) already collected.
  Set<int> get collectedPickups => Set.unmodifiable(_collected);

  bool isSlotComplete(Slot slot) =>
      _found.contains(slot.index) || _auto.contains(slot.index);

  /// A cell shows its letter once revealed or part of a completed slot.
  bool isFilled(CellPos cell) =>
      _revealed.contains(cell) ||
      (puzzle.slotsAt[cell]?.any(isSlotComplete) ?? false);

  bool get isComplete => puzzle.slots.every(isSlotComplete);

  int get filledCount => puzzle.cells.where(isFilled).length;

  List<CellPos> get emptyCells =>
      [for (final c in puzzle.cells) if (!isFilled(c)) c];

  /// The pickup sitting in [cell] that hasn't been collected yet.
  Pickup? pickupAt(CellPos cell) {
    for (var i = 0; i < pickups.length; i++) {
      if (_collected.contains(i)) continue;
      if (puzzle.cells[pickups[i].cellIndex] == cell) return pickups[i];
    }
    return null;
  }

  SubmitResult submit(String raw) {
    final word = normalizeWord(raw);
    if (word.length < minWordLength) {
      return SubmitResult(SubmitOutcome.tooShort, word);
    }
    final slot = puzzle.slotByWord[word];
    if (slot != null) {
      if (isSlotComplete(slot)) {
        return SubmitResult(SubmitOutcome.alreadyFound, word, slot: slot);
      }
      final before = {for (final c in slot.cells) c: isFilled(c)};
      _found.add(slot.index);
      final newCells = [
        for (final c in slot.cells)
          if (!before[c]!) c,
      ];
      final completed = [slot, ..._completeCrossings(slot.cells)];
      return SubmitResult(
        SubmitOutcome.found,
        word,
        slot: slot,
        completedSlots: completed,
        newCells: newCells,
        collected: _collectFor(completed),
      );
    }
    if (puzzle.bonus.contains(word)) {
      if (!_bonusFound.add(word)) {
        return SubmitResult(SubmitOutcome.alreadyBonus, word);
      }
      return SubmitResult(SubmitOutcome.bonus, word);
    }
    return SubmitResult(SubmitOutcome.invalid, word);
  }

  /// Reveals [cells] (hint effects). Slots whose letters are now all shown
  /// complete automatically (see [autoSlots]).
  RevealResult reveal(Iterable<CellPos> cells) {
    final newly = [
      for (final c in cells)
        if (puzzle.letterAt.containsKey(c) && !isFilled(c)) c,
    ];
    if (newly.isEmpty) return const RevealResult([], [], []);
    _revealed.addAll(newly);
    final completed = <Slot>[];
    for (final slot in puzzle.slots) {
      if (isSlotComplete(slot)) continue;
      if (slot.cells.every(isFilled)) {
        _auto.add(slot.index);
        completed.add(slot);
      }
    }
    return RevealResult(newly, completed, _collectFor(completed));
  }

  /// Where a Hammer Strike lands: a random empty cell.
  CellPos? hammerTarget(Random rng) {
    final empty = emptyCells;
    return empty.isEmpty ? null : empty[rng.nextInt(empty.length)];
  }

  /// Where a Spark Shower lands: up to [sparkShowerLetters] empty cells,
  /// spread across different slots where possible.
  List<CellPos> sparksTargets(Random rng) {
    final empty = emptyCells..shuffle(rng);
    final picked = <CellPos>[];
    final usedSlots = <int>{};
    for (final c in empty) {
      if (picked.length == sparkShowerLetters) break;
      final slots = puzzle.slotsAt[c]!.map((s) => s.index);
      if (slots.any(usedSlots.contains)) continue;
      picked.add(c);
      usedSlots.addAll(slots);
    }
    for (final c in empty) {
      if (picked.length == sparkShowerLetters) break;
      if (!picked.contains(c)) picked.add(c);
    }
    return picked;
  }

  /// Crossing slots that became complete because [cells] filled their
  /// last gaps.
  List<Slot> _completeCrossings(List<CellPos> cells) {
    final done = <Slot>[];
    for (final c in cells) {
      for (final other in puzzle.slotsAt[c]!) {
        if (isSlotComplete(other) || done.contains(other)) continue;
        if (other.cells.every(isFilled)) {
          _auto.add(other.index);
          done.add(other);
        }
      }
    }
    return done;
  }

  List<Pickup> _collectFor(List<Slot> completed) {
    final got = <Pickup>[];
    for (var i = 0; i < pickups.length; i++) {
      if (_collected.contains(i)) continue;
      final cell = puzzle.cells[pickups[i].cellIndex];
      if (completed.any((s) => s.cells.contains(cell))) {
        _collected.add(i);
        got.add(pickups[i]);
      }
    }
    return got;
  }
}
