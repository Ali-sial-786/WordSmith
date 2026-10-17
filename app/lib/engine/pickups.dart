/// Seeded hint pickups (spec and test vectors: `shared/pickups.md`).
///
/// Arithmetic is kept to exact 32-bit operations so results match the
/// TypeScript server on every platform, including the web preview build.
library;

import 'dart:convert';

import 'hints.dart';

const double pickupChance = 0.20;
const double secondPickupChance = 0.15;

class Pickup {
  const Pickup(this.cellIndex, this.kind);

  /// Index into [Puzzle.cells].
  final int cellIndex;
  final HintKind kind;

  Map<String, Object> toJson() => {'cell': cellIndex, 'kind': kind.name};

  factory Pickup.fromJson(Map<String, dynamic> json) =>
      Pickup(json['cell'] as int, HintKind.byName(json['kind'] as String));

  @override
  bool operator ==(Object other) =>
      other is Pickup && other.cellIndex == cellIndex && other.kind == kind;

  @override
  int get hashCode => Object.hash(cellIndex, kind);

  @override
  String toString() => 'Pickup($cellIndex, ${kind.name})';
}

const int _mask32 = 0xffffffff;

/// 32-bit multiply (like JavaScript's Math.imul), unsigned result.
int imul32(int a, int b) {
  final ah = (a >> 16) & 0xffff;
  final al = a & 0xffff;
  final bh = (b >> 16) & 0xffff;
  final bl = b & 0xffff;
  final high = ((ah * bl + al * bh) & 0xffff) << 16;
  return (al * bl + high) & _mask32;
}

int fnv1a32(String input) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = imul32(hash, 0x01000193);
  }
  return hash;
}

/// mulberry32 PRNG; each call returns a double in [0, 1).
double Function() mulberry32(int seed) {
  var a = seed & _mask32;
  return () {
    a = (a + 0x6D2B79F5) & _mask32;
    var t = a;
    t = imul32(t ^ (t >>> 15), t | 1);
    t = (t ^ ((t + imul32(t ^ (t >>> 7), t | 61)) & _mask32)) & _mask32;
    return ((t ^ (t >>> 14)) & _mask32) / 4294967296.0;
  };
}

/// The pickups hidden in [puzzleId] for [userId], given the puzzle's
/// [cellCount] and the player's Smith [level] when the puzzle starts.
List<Pickup> pickupsFor({
  required String userId,
  required String puzzleId,
  required int cellCount,
  required int level,
}) {
  final rand = mulberry32(fnv1a32('$userId:$puzzleId'));
  if (cellCount == 0 || rand() >= pickupChance) return const [];
  final count = rand() < secondPickupChance ? 2 : 1;
  final used = <int>{};
  final out = <Pickup>[];
  for (var i = 0; i < count && used.length < cellCount; i++) {
    var index = (rand() * cellCount).floor();
    while (used.contains(index)) {
      index = (index + 1) % cellCount;
    }
    used.add(index);
    final t = rand();
    var kind = t < 0.70
        ? HintKind.hammer
        : t < 0.95
        ? HintKind.chisel
        : HintKind.sparks;
    if (!kind.unlockedAt(level)) kind = HintKind.hammer;
    out.add(Pickup(index, kind));
  }
  return out;
}
