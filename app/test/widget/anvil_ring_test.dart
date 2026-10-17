import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/ui/anvil/anvil_ring.dart';

void main() {
  late List<String> selections;
  late List<String> submitted;

  Future<void> pumpRing(WidgetTester tester, {List<int>? order}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: AnvilRing(
            letters: 'ABCDE',
            order: order ?? const [0, 1, 2, 3, 4],
            size: 300,
            onSelectionChanged: selections.add,
            onSubmit: submitted.add,
          ),
        ),
      ),
    );
  }

  Offset tile(WidgetTester tester, String letter) => tester.getCenter(
    find.descendant(of: find.byType(AnvilRing), matching: find.text(letter)),
  );

  setUp(() {
    selections = [];
    submitted = [];
  });

  testWidgets('swiping back onto the previous tile drops the last letter', (tester) async {
    await pumpRing(tester);
    final g = await tester.startGesture(tile(tester, 'A'));
    for (final l in ['B', 'C', 'B', 'D']) {
      await g.moveTo(tile(tester, l));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(selections, ['A', 'AB', 'ABC', 'AB', 'ABD', '']);
    expect(submitted, ['ABD']);
  });

  testWidgets('a tile already in the word is not added twice', (tester) async {
    await pumpRing(tester);
    final g = await tester.startGesture(tile(tester, 'A'));
    for (final l in ['B', 'C', 'A']) {
      await g.moveTo(tile(tester, l));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(submitted, ['ABC']);
  });

  testWidgets('starting off a tile does nothing', (tester) async {
    await pumpRing(tester);
    final center = tester.getCenter(find.byType(AnvilRing));
    final g = await tester.startGesture(center);
    await g.moveTo(tile(tester, 'C'));
    await g.up();
    await tester.pump();
    expect(submitted, isEmpty);
  });

  testWidgets('tiles glide to new places on a Turn and ignore input meanwhile', (tester) async {
    await pumpRing(tester);
    final before = tile(tester, 'A');
    await pumpRing(tester, order: const [4, 3, 2, 1, 0]);
    final g = await tester.startGesture(tile(tester, 'C'));
    await g.up();
    await tester.pump();
    expect(submitted, isEmpty, reason: 'input is paused while tiles move');
    await tester.pumpAndSettle();
    expect(tile(tester, 'A'), isNot(before));
  });
}
