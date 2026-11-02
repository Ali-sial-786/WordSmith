import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../app_info.dart';

/// How long this phone takes to make each frame, screen by screen, for a
/// performance report the player can copy (Settings, Troubleshooting) and
/// send. Flutter hands the timings over in batches; each batch counts for
/// whatever [screenOf] says is showing when it arrives.
class FrameStats {
  FrameStats._();

  static final instance = FrameStats._();

  /// The screen showing now (a route, plus a room's mode and phase).
  String Function() screenOf = () => '?';

  final _screens = <String, _Screen>{};
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_add);
  }

  void _add(List<FrameTiming> timings) {
    String name;
    try {
      name = screenOf();
    } on Object {
      name = '?';
    }
    final screen = _screens.putIfAbsent(name, _Screen.new);
    for (final t in timings) {
      screen.add(t.buildDuration.inMicroseconds, t.rasterDuration.inMicroseconds);
    }
  }

  /// As Flutter does, for tests.
  @visibleForTesting
  void addTimings(List<FrameTiming> timings) => _add(timings);

  void clear() => _screens.clear();

  /// A plain-text report: for each screen, how many frames, the build (UI
  /// thread) and raster (GPU thread) times at the median, 90th and 99th
  /// percentiles, and the share of frames that missed the display's budget.
  String report({required String device, required String graphics, required double refreshRate}) {
    final budget = 1e6 / (refreshRate > 0 ? refreshRate : 60);
    final b = StringBuffer()
      ..writeln('Wordsmith $appVersion performance report')
      ..writeln('Device: $device')
      ..writeln('Graphics: $graphics, ${refreshRate.round()} Hz (${(budget / 1000).toStringAsFixed(1)} ms a frame)')
      ..writeln('Times in ms: build (UI) and raster (GPU), median / 90% / 99%; slow = over budget')
      ..writeln();
    final screens = _screens.entries.toList()..sort((a, b) => b.value.count.compareTo(a.value.count));
    if (screens.isEmpty) b.writeln('No frames yet: use the game a little, then copy again.');
    for (final MapEntry(key: name, value: s) in screens) {
      b
        ..writeln('$name: ${s.count} frames, ${(s.slowShare(budget) * 100).toStringAsFixed(0)}% slow')
        ..writeln('  build ${s.build.summary}  raster ${s.raster.summary}');
    }
    return b.toString();
  }
}

class _Screen {
  final build = _Samples();
  final raster = _Samples();
  int get count => build.total;

  void add(int buildUs, int rasterUs) {
    build.add(buildUs);
    raster.add(rasterUs);
  }

  double slowShare(double budgetUs) {
    final n = min(build.values.length, raster.values.length);
    if (n == 0) return 0;
    var slow = 0;
    for (var i = 0; i < n; i++) {
      if (build.values[i] > budgetUs || raster.values[i] > budgetUs) slow++;
    }
    return slow / n;
  }
}

/// The latest [_keep] values (microseconds), and how many there have been.
class _Samples {
  static const _keep = 3000;

  final values = <int>[];
  int total = 0;

  void add(int us) {
    if (values.length < _keep) {
      values.add(us);
    } else {
      values[total % _keep] = us;
    }
    total++;
  }

  String get summary {
    if (values.isEmpty) return '-';
    final sorted = [...values]..sort();
    String at(double p) => (sorted[min(sorted.length - 1, (sorted.length * p).floor())] / 1000).toStringAsFixed(1);
    return '${at(0.5)} / ${at(0.9)} / ${at(0.99)}';
  }
}
