import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Seconds for slow effects (the forge fire, drifting embers), stepped about
/// 30 times a second (40 at 120 Hz) rather than on every display frame: each
/// step redraws the whole screen, and slow flames look the same. Effects on
/// one clock step on the same frame, so together they cost one redraw.
///
/// The ticker takes one frame, then waits [step] before asking for the next,
/// so each step still lands on a frame. [hold] stops it for a while (the
/// screen is scrolling, say); a muted ticker (the route is covered, the app
/// is away) stops it too. Time doesn't jump on when it starts again.
class StepClock extends ValueNotifier<double> {
  StepClock(TickerProvider vsync, {double start = 0}) : super(start) {
    _ticker = vsync.createTicker(_frame);
  }

  static const step = Duration(milliseconds: 20);

  /// The most one step moves time on, however long it has been.
  static const _maxStep = 0.1;

  late final Ticker _ticker;
  Timer? _next, _held;
  Duration? _last;
  bool _running = false;

  bool get running => _running;

  void _frame(Duration _) {
    // Frame time, not a stopwatch, so tests see the same flames every run.
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    final last = _last;
    _last = now;
    if (last != null) value += ((now - last).inMicroseconds / 1e6).clamp(0.0, _maxStep);
    _ticker.stop();
    _next = Timer(step, _ask);
  }

  void _ask() {
    _next = null;
    if (_running && _held == null && !_ticker.isActive) _ticker.start();
  }

  void start() {
    _running = true;
    if (_next == null) _ask();
  }

  void stop() {
    _running = false;
    _ticker.stop();
    _next?.cancel();
    _next = null;
  }

  /// Stands still for [d], or until [d] after the last hold.
  void hold(Duration d) {
    _held?.cancel();
    _held = Timer(d, () {
      _held = null;
      if (_next == null) _ask();
    });
    _ticker.stop();
  }

  @override
  void dispose() {
    _next?.cancel();
    _held?.cancel();
    _ticker.dispose();
    super.dispose();
  }
}
