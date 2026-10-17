import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/board.dart';
import 'package:wordsmith/engine/hints.dart';
import 'package:wordsmith/engine/masterworks.dart';
import 'package:wordsmith/engine/pickups.dart';

import '../fixtures/puzzles.dart';

int? gildedFor(String user, String puzzle, int cells, int level) => gildedCellFor(
  userId: user,
  puzzleId: puzzle,
  cellCount: cells,
  pickups: pickupsFor(userId: user, puzzleId: puzzle, cellCount: cells, level: level),
);

void main() {
  group('gilded cells match shared/masterworks.md', () {
    test('vectors', () {
      expect(gildedFor('user-123', 'c-0010', 30, 20), isNull);
      expect(gildedFor('abc', 'c-0001', 12, 1), isNull);
      expect(gildedFor('friend-7', 'c-0200', 40, 30), 14);
      expect(gildedFor('user-123', 'c-0074', 30, 12), 23);
      expect(gildedFor('u1', 'c-0003', 9, 5), 4);
    });

    test('steps past a pickup in the same cell', () {
      // Both land on cell 0 of 3; the gilded cell moves to 1.
      expect(pickupsFor(userId: 'user-123', puzzleId: 'c-0025', cellCount: 3, level: 20), [
        const Pickup(0, HintKind.hammer),
      ]);
      expect(gildedFor('user-123', 'c-0025', 3, 20), 1);
      expect(gildedFor('user-123', 'c-0025', 12, 20), 4);
      expect(gildedFor('user-123', 'c-0205', 3, 20), 0, reason: 'wraps round');
      expect(gildedFor('user-123', 'c-1306', 3, 20), 2, reason: 'steps past two pickups');
      expect(gildedFor('user-123', 'c-0025', 1, 20), isNull, reason: 'the only cell holds a pickup');
    });

    test('no room when every cell holds a pickup', () {
      final rand = mulberry32(fnv1a32('user-123:c-0025:gilded'));
      expect(rand() < gildedChance, isTrue);
      expect(
        gildedCellFor(
          userId: 'user-123',
          puzzleId: 'c-0025',
          cellCount: 2,
          pickups: const [Pickup(0, HintKind.hammer), Pickup(1, HintKind.chisel)],
        ),
        isNull,
      );
    });

    test('roughly one puzzle in four is gilded', () {
      var gilded = 0;
      for (var i = 1; i <= 2000; i++) {
        if (gildedCellFor(userId: 'u', puzzleId: 'c-$i', cellCount: 20, pickups: const []) != null) gilded++;
      }
      expect(gilded / 2000, closeTo(0.25, 0.04));
    });
  });

  group('Masterwork progress', () {
    test('counts finished ones and pieces towards the next', () {
      expect(masterworkSpecs.fold(0, (a, s) => a + s.pieces), 114);
      var p = MasterworkProgress(0);
      expect((p.finished, p.piecesInCurrent, p.current!.id), (0, 0, 'horseshoe'));
      p = MasterworkProgress(5);
      expect((p.finished, p.piecesInCurrent), (0, 5));
      expect(p.finishedBy(1)!.id, 'horseshoe');
      p = MasterworkProgress(6);
      expect((p.finished, p.piecesInCurrent, p.current!.id), (1, 0, 'bell'));
      expect(p.finishedBy(1), isNull);
      p = MasterworkProgress(13);
      expect((p.finished, p.piecesInCurrent, p.current!.id), (2, 1, 'dagger'));
      p = MasterworkProgress(114);
      expect((p.finished, p.allDone, p.current), (12, true, null));
      expect(MasterworkProgress(200).finishedBy(1), isNull);
      expect(MasterworkProgress(113).finishedBy(1)!.id, 'anvil');
    });
  });

  group('the board', () {
    // TEAR across, EAT and RATE down. Cell 1 is the E of TEAR (and of EAT).
    test('collects the piece when a word through the gilded cell completes', () {
      final board = Board(tearPuzzle(), gilded: 1);
      expect(board.isGilded((x: 1, y: 0)), isTrue);
      expect(board.submit('RATE').gilded, isFalse);
      final r = board.submit('EAT');
      expect(r.gilded, isTrue);
      expect(board.gildedCollected, isTrue);
      expect(board.isGilded((x: 1, y: 0)), isFalse);
      expect(board.submit('TEAR').gilded, isFalse, reason: 'only once');
    });

    test('hints that complete the word collect it too', () {
      final board = Board(tearPuzzle(), gilded: 1);
      final r = board.reveal([(x: 1, y: 0), (x: 1, y: 1), (x: 1, y: 2)]);
      expect(r.gilded, isTrue);
    });

    test('a saved puzzle keeps the gilded cell', () {
      final board = Board(tearPuzzle(), gilded: 1)..submit('EAT');
      final saved = SavedPuzzle.fromBoard(
        stage: 1,
        board: board,
        letters: 'RTAE',
        hintsUsed: const {},
        elapsedMs: 0,
        pickupSeed: 'u',
      );
      final back = SavedPuzzle.fromJson(saved.toJson()).toBoard(tearPuzzle());
      expect((back.gilded, back.gildedCollected), (1, true));
    });
  });
}
