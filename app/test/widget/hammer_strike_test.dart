import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/engine/board.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/theme/palette.dart';

import '../fixtures/puzzles.dart';

void main() {
  testWidgets('each Hammer Strike swings one hammer, however many came before', (tester) async {
    final puzzle = tearPuzzle();
    final cues = MoldCues();
    final cells = puzzle.slots.expand((s) => s.cells).toSet().toList();
    Widget grid(Key key) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          key: key,
          width: 360,
          height: 360,
          child: MoldGrid(mold: BoardMold(Board(puzzle)), metal: MetalStyle.forChapter('tin'), cues: cues),
        ),
      ),
    );
    await tester.pumpWidget(grid(const ValueKey(1)));

    // Four strikes, one after another: the fourth swings alone.
    for (final cell in cells.take(4)) {
      cues.strike(cell);
      await tester.pumpWidget(grid(const ValueKey(1)));
      expect(find.byType(HammerStrike), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(cues.strikes, isEmpty, reason: 'finished swings leave');

    // A grid built afresh (a new look, a new screen) doesn't swing them again.
    await tester.pumpWidget(grid(const ValueKey(2)));
    expect(find.byType(HammerStrike), findsNothing);

    // Two strikes close together both swing, each once.
    cues
      ..strike(cells[0])
      ..strike(cells[1]);
    await tester.pumpWidget(grid(const ValueKey(2)));
    expect(find.byType(HammerStrike), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 1));
    expect(cues.strikes, isEmpty);
  });
}
