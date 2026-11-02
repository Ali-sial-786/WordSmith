import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/data/frame_stats.dart';

/// A frame that took [build] ms on the UI thread and [raster] ms on the GPU's.
FrameTiming _frame(double build, double raster) {
  final b = (build * 1000).round(), r = (raster * 1000).round();
  return FrameTiming(
    vsyncStart: 0,
    buildStart: 0,
    buildFinish: b,
    rasterStart: b,
    rasterFinish: b + r,
    rasterFinishWallTime: b + r,
  );
}

void main() {
  test('the report says, screen by screen, how long frames take and how many miss the budget', () {
    final stats = FrameStats.instance..clear();
    var screen = '/';
    stats.screenOf = () => screen;
    stats.addTimings([for (var i = 0; i < 90; i++) _frame(2, 4), for (var i = 0; i < 10; i++) _frame(3, 20)]);
    screen = 'room rune round';
    stats.addTimings([for (var i = 0; i < 20; i++) _frame(12, 3)]);

    final report = stats.report(device: 'samsung SM-S928W', graphics: 'vulkan', refreshRate: 120);
    expect(report, contains('Device: samsung SM-S928W'));
    expect(report, contains('Graphics: vulkan, 120 Hz (8.3 ms a frame)'));
    expect(report, contains('/: 100 frames, 10% slow'));
    expect(report, contains('  build 2.0 / 3.0 / 3.0  raster 4.0 / 20.0 / 20.0'));
    expect(report, contains('room rune round: 20 frames, 100% slow'));
    expect(report.indexOf('/: 100'), lessThan(report.indexOf('room rune round')), reason: 'busiest first');
    stats.clear();
  });
}
