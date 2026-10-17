import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/ui/widgets/forge_frame.dart';

void main() {
  testWidgets('frames smaller than their corners paint instead of failing', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: SingleChildScrollView(
            child: Column(
              children: [
                for (final kind in ForgeFrameKind.values) ...[
                  SizedBox(width: 10, height: 10, child: ForgeFrame(kind: kind)),
                  SizedBox(width: 200, height: 120, child: ForgeFrame(kind: kind)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(ForgeFrameKind.panel.minSize, const Size(48, 48));
    expect(ForgeFrameKind.plate.minSize, const Size(40, 40));
  });
}
