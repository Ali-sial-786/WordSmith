/// Gilded cells and the twelve Masterworks (spec and test vectors:
/// `shared/masterworks.md`).
library;

import 'pickups.dart';

const double gildedChance = 0.25;

/// The gilded cell (index into the puzzle's letter cells) hidden in
/// [puzzleId] for [userId], or null. It never shares a cell with one of the
/// puzzle's [pickups].
int? gildedCellFor({
  required String userId,
  required String puzzleId,
  required int cellCount,
  required List<Pickup> pickups,
}) {
  final rand = mulberry32(fnv1a32('$userId:$puzzleId:gilded'));
  if (cellCount == 0 || rand() >= gildedChance) return null;
  final taken = {for (final p in pickups) p.cellIndex};
  if (taken.length >= cellCount) return null;
  var index = (rand() * cellCount).floor();
  while (taken.contains(index)) {
    index = (index + 1) % cellCount;
  }
  return index;
}

class MasterworkSpec {
  const MasterworkSpec(this.id, this.pieces);

  final String id;
  final int pieces;
}

/// Made in this order. Names and art live in assets/masterworks/.
const List<MasterworkSpec> masterworkSpecs = [
  MasterworkSpec('horseshoe', 6),
  MasterworkSpec('bell', 6),
  MasterworkSpec('dagger', 8),
  MasterworkSpec('lantern', 8),
  MasterworkSpec('helm', 8),
  MasterworkSpec('shield', 10),
  MasterworkSpec('axe', 10),
  MasterworkSpec('crown', 10),
  MasterworkSpec('longsword', 12),
  MasterworkSpec('astrolabe', 12),
  MasterworkSpec('warhammer', 12),
  MasterworkSpec('anvil', 12),
];

/// XP for finishing a Masterwork; it also gives a Chisel and a Spark Shower.
const int masterworkXp = 100;

/// Where a player stands with the Masterworks, given all pieces collected.
class MasterworkProgress {
  factory MasterworkProgress(int pieces) {
    var left = pieces < 0 ? 0 : pieces;
    var finished = 0;
    for (final spec in masterworkSpecs) {
      if (left < spec.pieces) break;
      left -= spec.pieces;
      finished++;
    }
    return MasterworkProgress._(pieces, finished, finished == masterworkSpecs.length ? 0 : left);
  }

  const MasterworkProgress._(this.pieces, this.finished, this.piecesInCurrent);

  final int pieces;

  /// Masterworks completed (0–12).
  final int finished;

  /// Pieces towards the one being built.
  final int piecesInCurrent;

  bool get allDone => finished == masterworkSpecs.length;

  /// The one being built, or null once all are done.
  MasterworkSpec? get current => allDone ? null : masterworkSpecs[finished];

  /// The Masterwork that [extra] more pieces would finish, if any.
  MasterworkSpec? finishedBy(int extra) {
    final after = MasterworkProgress(pieces + extra);
    return after.finished > finished ? masterworkSpecs[after.finished - 1] : null;
  }
}
