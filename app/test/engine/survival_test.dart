import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/engine/survival.dart';

void main() {
  test('countdowns match the contract examples', () {
    expect(survivalHeatMs(3, 1, 0), 21600);
    expect(survivalHeatMs(6, 1, 0), 33600);
    expect(survivalHeatMs(4, 6, 0), 14400);
  });

  test('countdowns tighten with saved words, down to 8 s', () {
    expect(survivalHeatMs(4, 5, 1), (16000 * 0.97).round());
    expect(survivalHeatMs(4, 5, 20), survivalHeatMs(4, 5, 50));
    expect(survivalHeatMs(3, 6, 20), 8000);
  });

  test('the first heated slot is one of the shortest, and every slot is in the order', () {
    const lengths = [5, 3, 6, 3, 4];
    for (var seed = 0; seed < 30; seed++) {
      final order = survivalHeatOrder(lengths, Random(seed));
      expect(lengths[order.first], 3);
      expect(order.toSet(), {0, 1, 2, 3, 4});
      expect(order, hasLength(5));
    }
  });

  test('the heated slot skips complete ones', () {
    expect(survivalHeated([2, 0, 1], (s) => s == 2), 0);
    expect(survivalHeated([2, 0, 1], (_) => true), isNull);
  });
}
