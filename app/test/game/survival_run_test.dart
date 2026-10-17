import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/hints.dart';
import 'package:wordsmith/engine/survival.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/survival_run.dart';

import '../fixtures/puzzles.dart';

/// A stopwatch the test moves by hand.
class _Clock implements Stopwatch {
  int ms = 0;
  bool running = false;

  @override
  int get elapsedMilliseconds => ms;
  @override
  int get elapsedMicroseconds => ms * 1000;
  @override
  Duration get elapsed => Duration(milliseconds: ms);
  @override
  int get elapsedTicks => elapsedMicroseconds;
  @override
  int get frequency => 1000000;
  @override
  bool get isRunning => running;
  @override
  void start() => running = true;
  @override
  void stop() => running = false;
  @override
  void reset() => ms = 0;
}

void main() {
  late Store store;
  late ProviderContainer container;
  late _Clock clock;
  late SurvivalRun run;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'profile.v1': jsonEncode({
        'userId': 'abc',
        'hints': {'hammer': 2},
      }),
    });
    store = await Store.open();
    final second = tearJson()..['id'] = 'c-0002';
    final campaign = Campaign.fromJson({
      'version': 1,
      'chapters': [
        {'id': 'tin', 'name': 'Tin', 'first': 1, 'count': 2},
      ],
      'puzzles': [tearJson(), second],
    });
    container = ProviderContainer(overrides: [storeProvider.overrideWithValue(store)]);
    clock = _Clock();
    run = SurvivalRun(
      campaign: campaign,
      store: store,
      profile: container.read(profileProvider.notifier),
      furthestStage: 0,
      rng: Random(1),
      clock: clock,
    );
  });

  tearDown(() {
    run.dispose();
    container.dispose();
  });

  test('the first heated word is one of the shortest, with the contract countdown', () {
    expect(run.heated!.word, 'EAT');
    expect(run.heatDurationMs, survivalHeatMs(3, 1, 0));
    expect(run.remainingMs, run.heatDurationMs);
  });

  test('forging the heated word saves it and heats the next', () {
    clock.ms = 5000;
    run.submit('EAT');
    expect(run.saved, 1);
    expect(run.heated, isNotNull);
    expect(run.heated!.word, isNot('EAT'));
    expect(run.heatDurationMs, survivalHeatMs(4, 1, 1));
    expect(run.remainingMs, run.heatDurationMs);
  });

  test('other words can be forged without stopping the clock', () {
    final heated = run.heated!;
    final other = ['TEAR', 'RATE'].firstWhere((w) => w != heated.word);
    clock.ms = 3000;
    run.submit(other);
    expect(run.heated, heated);
    expect(run.remainingMs, run.heatDurationMs - 3000);
  });

  test('clearing a puzzle records it, and the next puzzle comes', () async {
    // Each heated word in turn.
    while (run.heated != null) {
      run.submit(run.heated!.word);
    }
    expect(run.stage, CrucibleStage.cleared);
    expect(run.cleared, 1);
    await Future<void>.delayed(const Duration(milliseconds: 1900));
    expect(run.stage, CrucibleStage.playing);
    expect(run.number, 2);
    expect(run.saved, 3);
    // The second puzzle starts on a fresh board with the tighter timers.
    expect(run.heatDurationMs, survivalHeatMs(run.heated!.length, 1, 3));
  });

  test('when time runs out the heated word melts and the run is over', () {
    run.submit('TEAR');
    clock.ms = run.heatDurationMs + 1;
    run.checkMelt();
    expect(run.stage, CrucibleStage.melted);
    // EAT's E is TEAR's: only its empty cells melt.
    expect(run.meltedCells, [(x: 1, y: 1), (x: 1, y: 2)]);
    final report = run.finish()!;
    final puzzles = (report['puzzles'] as List).cast<Map>();
    expect(puzzles, hasLength(1));
    expect(puzzles.single['foundWords'], ['TEAR']);
    expect(puzzles.single['cleared'], false);
    expect(store.loadSurvivalQueue().single['runId'], run.runId);
  });

  test('hints come from the stock and aim at the heated word', () {
    final r = run.useHammer()!;
    expect(run.heated!.cells, contains(r.cells.single));
    expect(container.read(profileProvider).hintCount(HintKind.hammer), 1);
    // Still owed to the server: kept off the profile when it syncs.
    expect(store.pendingSurvivalHints(), {'hammer': 1});
  });

  test('a paused clock stops the countdown', () {
    run.pause();
    expect(clock.running, isFalse);
    run.resume();
    expect(clock.running, isTrue);
  });

  test('a run the app was closed in is queued at the next start', () async {
    run.submit('EAT');
    await store.closeOpenSurvival();
    final queued = store.loadSurvivalQueue().single;
    expect(queued['runId'], run.runId);
    expect(((queued['puzzles'] as List).single as Map)['foundWords'], ['EAT']);
  });
}
