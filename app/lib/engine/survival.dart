/// Survival's rules, as the server has them (shared/survival.md).
library;

import 'dart:math';

/// How much longer (or shorter) a heated word lasts at each heat tier.
const survivalHeatFactor = {1: 1.6, 2: 1.45, 3: 1.3, 4: 1.15, 5: 1.0, 6: 0.9};

/// The countdown for a heated word of [length] letters at [heat], after
/// [saved] words saved so far.
int survivalHeatMs(int length, int heat, int saved) =>
    max(8000, ((6000 + 2500 * length) * survivalHeatFactor[heat.clamp(1, 6)]! * pow(0.97, min(saved, 20))).round());

/// The order slots heat up in: random, except that the first is one of the
/// shortest. [lengths] are the slots' lengths by index.
List<int> survivalHeatOrder(List<int> lengths, Random rng) {
  final order = List.generate(lengths.length, (i) => i)..shuffle(rng);
  if (order.isEmpty) return order;
  final shortest = lengths.reduce(min);
  final first = order.indexWhere((i) => lengths[i] == shortest);
  return [order[first], ...order.sublist(0, first), ...order.sublist(first + 1)];
}

/// The heated slot: the first in [order] that isn't [complete] yet.
int? survivalHeated(List<int> order, bool Function(int slot) complete) {
  for (final i in order) {
    if (!complete(i)) return i;
  }
  return null;
}
