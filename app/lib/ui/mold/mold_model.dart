import 'dart:ui';

import '../../engine/board.dart';
import '../../engine/puzzle.dart';

enum CellFill { empty, revealed, filled }

/// What the mold grid needs to draw. Solo play adapts a [Board]; co-op
/// builds it from what the server has revealed (the app never sees the
/// answers there).
abstract interface class MoldModel {
  int get cols;
  int get rows;

  /// Every letter cell.
  List<CellPos> get cells;

  /// The cell's letter, or '' while it's still unknown.
  String letterAt(CellPos cell);
  CellFill fillOf(CellPos cell);

  /// Hint kind name of an ember still sitting in [cell].
  String? pickupAt(CellPos cell);

  /// Co-op: the colour of the player who forged the word through [cell].
  /// Null uses the chapter's metal.
  Color? ownerColor(CellPos cell);

  /// Co-op: that player's initial, shown on the first cell of their word.
  String? ownerInitial(CellPos cell);
}

/// A solo [Board] seen as a mold.
class BoardMold implements MoldModel {
  BoardMold(this.board);

  final Board board;

  @override
  int get cols => board.puzzle.cols;
  @override
  int get rows => board.puzzle.rows;
  @override
  List<CellPos> get cells => board.puzzle.cells;
  @override
  String letterAt(CellPos cell) => board.puzzle.letterAt[cell] ?? '';

  @override
  CellFill fillOf(CellPos cell) {
    if (board.puzzle.slotsAt[cell]!.any(board.isSlotComplete)) return CellFill.filled;
    return board.revealed.contains(cell) ? CellFill.revealed : CellFill.empty;
  }

  @override
  String? pickupAt(CellPos cell) => board.isFilled(cell) ? null : board.pickupAt(cell)?.kind.name;
  @override
  Color? ownerColor(CellPos cell) => null;
  @override
  String? ownerInitial(CellPos cell) => null;
}
