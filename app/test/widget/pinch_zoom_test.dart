import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/ui/widgets/pinch_zoom.dart';

double _scaleOf(WidgetTester tester) => tester
    .widget<Transform>(find.descendant(of: find.byType(PinchZoom), matching: find.byType(Transform)))
    .transform
    .getMaxScaleOnAxis();

void main() {
  testWidgets('two fingers zoom in and back out; one finger still plays', (tester) async {
    var pans = 0, cancels = 0, taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PinchZoom(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: GestureDetector(
                  onPanEnd: (_) => pans++,
                  onPanCancel: () => cancels++,
                  child: ColoredBox(
                    color: Colors.brown,
                    child: Center(
                      child: TextButton(onPressed: () => taps++, child: const Text('Forge')),
                    ),
                  ),
                ),
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    // One finger: the game's own swipe, no zoom.
    await tester.dragFrom(const Offset(400, 150), const Offset(80, 0));
    await tester.pump();
    expect(pans, 1);
    expect(_scaleOf(tester), 1);

    // Two fingers spreading apart: zoom in, and the swipe they started is let go.
    final a = await tester.startGesture(const Offset(350, 150), pointer: 1);
    await a.moveBy(const Offset(-20, 0));
    final b = await tester.startGesture(const Offset(450, 150), pointer: 2);
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-10, 0));
      await b.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pump();
    expect(_scaleOf(tester), greaterThan(1.5));
    expect(pans, 1, reason: 'the pinch forged nothing');
    expect(cancels, greaterThanOrEqualTo(1));

    // Taps land on the zoomed view.
    await tester.tap(find.text('Forge'));
    expect(taps, 1);

    // Pinching back in snaps home.
    final c = await tester.startGesture(const Offset(200, 300), pointer: 3);
    final d = await tester.startGesture(const Offset(600, 300), pointer: 4);
    for (var i = 0; i < 10; i++) {
      await c.moveBy(const Offset(19, 0));
      await d.moveBy(const Offset(-19, 0));
      await tester.pump();
    }
    await c.up();
    await d.up();
    await tester.pump();
    expect(_scaleOf(tester), 1);
  });

  testWidgets('a mouse never zooms', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PinchZoom(child: SizedBox.expand())));
    final a = await tester.startGesture(const Offset(300, 300), pointer: 1, kind: PointerDeviceKind.mouse);
    final b = await tester.startGesture(const Offset(400, 300), pointer: 2, kind: PointerDeviceKind.mouse);
    await a.moveBy(const Offset(-100, 0));
    await b.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(_scaleOf(tester), 1);
    await a.up();
    await b.up();
  });
}
