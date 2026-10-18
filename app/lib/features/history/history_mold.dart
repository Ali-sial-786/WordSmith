import 'dart:ui';

import '../../data/history.dart';
import '../../engine/puzzle.dart';
import '../../ui/mold/mold_model.dart';

/// A finished board from the history: every letter shows. Words that were
/// forged (or filled in by themselves) are filled; missed ones glow, like the
/// end of a round. In co-op each word keeps its smith's colour and initial.
class HistoryMold implements MoldModel {
  HistoryMold(this.board, {this.colorOf, this.initialOf});

  final PlayedBoard board;

  /// Co-op: a player's colour and initial, by user id.
  final Color? Function(String id)? colorOf;
  final String? Function(String id)? initialOf;

  Puzzle get _puzzle => board.puzzle;

  @override
  int get cols => _puzzle.cols;
  @override
  int get rows => _puzzle.rows;
  @override
  List<CellPos> get cells => _puzzle.cells;

  @override
  String letterAt(CellPos cell) => _puzzle.letterAt[cell] ?? '';

  @override
  CellFill fillOf(CellPos cell) =>
      (_puzzle.slotsAt[cell] ?? const <Slot>[]).any((s) => board.isDone(s.index)) ? CellFill.filled : CellFill.revealed;

  @override
  String? pickupAt(CellPos cell) => null;
  @override
  bool isGilded(CellPos cell) => false;

  String? _ownerOf(CellPos cell) {
    for (final s in _puzzle.slotsAt[cell] ?? const <Slot>[]) {
      if (board.owners[s.index] case final id?) return id;
    }
    return null;
  }

  @override
  Color? ownerColor(CellPos cell) {
    final id = _ownerOf(cell);
    return id == null ? null : colorOf?.call(id);
  }

  @override
  String? ownerInitial(CellPos cell) {
    for (final s in _puzzle.slotsAt[cell] ?? const <Slot>[]) {
      final id = board.owners[s.index];
      if (id != null && s.cells.first == cell) return initialOf?.call(id);
    }
    return null;
  }

  /// The words through [cell], to look up.
  List<String> wordsAt(CellPos cell) => [for (final s in _puzzle.slotsAt[cell] ?? const <Slot>[]) s.word];
}
