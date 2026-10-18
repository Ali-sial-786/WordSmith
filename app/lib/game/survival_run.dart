import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/campaign.dart';
import '../data/history.dart';
import '../data/store.dart';
import '../engine/board.dart';
import '../engine/hints.dart';
import '../engine/puzzle.dart';
import '../engine/survival.dart';
import 'providers.dart';

enum CrucibleStage {
  /// A puzzle is on and its heated word is counting down.
  playing,

  /// The puzzle is forged; the next one comes after a short break.
  cleared,

  /// A heated word melted: the run is over.
  melted,
}

/// The Crucible: solo Survival (shared/survival.md). Campaign puzzles one
/// after another, each with a heated word on a countdown; a melt ends the run.
/// Hints come from the player's stock; nothing else is collected.
class SurvivalRun extends ChangeNotifier {
  SurvivalRun({
    required this.campaign,
    required this.store,
    required this.profile,
    required int furthestStage,
    Random? rng,
    DateTime Function()? now,
    Stopwatch? clock,
    this.onFinished,
  }) : _rng = rng ?? Random(),
       _now = now ?? DateTime.now,
       _clock = clock ?? Stopwatch() {
    final last = min(campaign.stageCount, max(furthestStage, 20));
    final stages = List.generate(last, (i) => i + 1);
    final size = {for (final s in stages) s: campaign.puzzle(s).letterCount};
    _pool = stages..sort((a, b) => size[a]!.compareTo(size[b]!));
    runId = _newId();
    startedAt = _now().millisecondsSinceEpoch;
    _startPuzzle();
  }

  final Campaign campaign;
  final Store store;
  final ProfileNotifier profile;

  /// Called once when a run that played anything ends (for the history).
  final void Function(SurvivalRun run)? onFinished;
  final Random _rng;
  final DateTime Function() _now;

  /// Reached campaign stages, smallest puzzle first.
  late final List<int> _pool;
  final Set<int> _used = {};

  late final String runId;
  late final int startedAt;

  CrucibleStage stage = CrucibleStage.playing;
  late int puzzleStage;
  late Puzzle puzzle;
  late Board board;
  late List<int> order;
  late List<int> _heatOrder;
  Map<String, int> _hintsUsed = {};

  /// The heated slot, and its countdown in play-clock milliseconds.
  Slot? heated;
  int heatDurationMs = 0;
  int _heatEndsAt = 0;

  /// The melted slot's empty cells, once it melts.
  List<CellPos> meltedCells = const [];

  /// Heated words saved over the whole run.
  int saved = 0;

  /// Finished puzzles, in the shape the server wants.
  final List<Map<String, Object>> puzzles = [];

  /// The run's boards as they ended, the one left unfinished included (for the history).
  final List<PlayedBoard> playedBoards = [];

  /// Runs while a puzzle is being played and the app is in front.
  final Stopwatch _clock;
  Timer? _watch;
  Timer? _next;
  bool _paused = false;

  int get cleared => puzzles.where((p) => p['cleared'] == true).length;
  int get words =>
      puzzles.fold(0, (n, p) => n + (p['foundWords'] as List).length) +
      (stage == CrucibleStage.playing ? board.foundSlots.length : 0);
  String get letters => puzzle.letters;
  bool get over => stage == CrucibleStage.melted;

  /// The result has been queued; nothing more counts.
  bool finished = false;

  /// Puzzle number in the run, from 1.
  int get number => puzzles.length + 1;

  int get remainingMs => max(0, _heatEndsAt - _clock.elapsedMilliseconds);

  void _startPuzzle() {
    final k = puzzles.length;
    // The run escalates: a window that slides up the puzzles by size.
    final n = _pool.length;
    final lo = (n * min(0.6, 0.12 * k)).floor();
    final hi = max(lo + 1, (n * min(1.0, 0.35 + 0.12 * k)).ceil());
    var window = _pool.sublist(lo, min(n, hi)).where((s) => !_used.contains(s)).toList();
    if (window.isEmpty) window = _pool.where((s) => !_used.contains(s)).toList();
    if (window.isEmpty) {
      _used.clear();
      window = _pool;
    }
    puzzleStage = window[_rng.nextInt(window.length)];
    _used.add(puzzleStage);
    puzzle = campaign.puzzle(puzzleStage);
    board = Board(puzzle);
    order = List.generate(puzzle.letters.length, (i) => i);
    _hintsUsed = {};
    _heatOrder = survivalHeatOrder([for (final s in puzzle.slots) s.length], _rng);
    stage = CrucibleStage.playing;
    heated = null;
    _heatNext();
    if (!_paused) _clock.start();
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(milliseconds: 100), (_) => _checkMelt());
  }

  void _heatNext() {
    final i = survivalHeated(_heatOrder, (s) => board.isSlotComplete(puzzle.slots[s]));
    heated = i == null ? null : puzzle.slots[i];
    if (heated == null) return;
    heatDurationMs = survivalHeatMs(heated!.length, puzzle.heat, saved);
    _heatEndsAt = _clock.elapsedMilliseconds + heatDurationMs;
  }

  /// Melts the heated word if its time is up (also checked 10 times a second).
  @visibleForTesting
  void checkMelt() => _checkMelt();

  void _checkMelt() {
    if (stage != CrucibleStage.playing || heated == null || remainingMs > 0) return;
    meltedCells = [
      for (final c in heated!.cells)
        if (!board.isFilled(c)) c,
    ];
    _end(cleared: false);
    stage = CrucibleStage.melted;
    notifyListeners();
  }

  /// After the board changed: saves the heated word, or moves on.
  void _changed() {
    if (heated != null && board.isSlotComplete(heated!)) {
      saved++;
      _heatNext();
    }
    if (board.isComplete) {
      _end(cleared: true);
      stage = CrucibleStage.cleared;
      _next = Timer(const Duration(milliseconds: 1800), () {
        _startPuzzle();
        notifyListeners();
      });
    }
    _saveOpen();
    notifyListeners();
  }

  void _end({required bool cleared}) {
    _clock.stop();
    _watch?.cancel();
    playedBoards.add(PlayedBoard.fromBoard(board, melted: cleared ? null : heated?.index));
    puzzles.add({
      'stage': puzzleStage,
      'puzzleId': puzzle.id,
      'foundWords': [for (final i in board.foundSlots.toList()..sort()) puzzle.slots[i].word],
      'hintsUsed': Map.of(_hintsUsed),
      'cleared': cleared,
    });
  }

  SubmitResult submit(String word) {
    if (stage != CrucibleStage.playing) return SubmitResult(SubmitOutcome.alreadyFound, word);
    final result = board.submit(word);
    if (result.outcome == SubmitOutcome.found) _changed();
    return result;
  }

  void turn() {
    if (order.length < 2) return;
    final next = [...order];
    do {
      next.shuffle(_rng);
    } while (listEquals(next, order));
    order = next;
    notifyListeners();
  }

  bool canUse(HintKind kind) =>
      stage == CrucibleStage.playing && kind.unlockedAt(profile.current.level) && profile.current.hintCount(kind) > 0;

  RevealResult? useHammer() {
    if (!canUse(HintKind.hammer)) return null;
    // Aim at the heated word while it has empty letters.
    final empty = heated?.cells.where((c) => !board.isFilled(c) && !board.revealed.contains(c)).toList() ?? [];
    final target = empty.isNotEmpty ? empty[_rng.nextInt(empty.length)] : board.hammerTarget(_rng);
    return target == null ? null : _spend(HintKind.hammer, [target]);
  }

  RevealResult? useChisel(CellPos cell) {
    if (!canUse(HintKind.chisel) || board.isFilled(cell)) return null;
    return _spend(HintKind.chisel, [cell]);
  }

  RevealResult? useSparks() {
    if (!canUse(HintKind.sparks)) return null;
    final targets = board.sparksTargets(_rng);
    return targets.isEmpty ? null : _spend(HintKind.sparks, targets);
  }

  RevealResult _spend(HintKind kind, List<CellPos> cells) {
    profile.spendHint(kind);
    _hintsUsed[kind.name] = (_hintsUsed[kind.name] ?? 0) + 1;
    final result = board.reveal(cells);
    _changed();
    return result;
  }

  /// Stops the clock while the game is in the background or a sheet is up.
  void pause() {
    _paused = true;
    _clock.stop();
  }

  void resume() {
    _paused = false;
    if (stage == CrucibleStage.playing) _clock.start();
  }

  /// The run so far, as `POST /v1/survival/solo` wants it.
  Map<String, Object> report() => {
    'runId': runId,
    'startedAt': startedAt,
    'endedAt': _now().millisecondsSinceEpoch,
    'saved': saved,
    'puzzles': [
      ...puzzles,
      // Leaving mid-puzzle counts like a melt.
      if (stage == CrucibleStage.playing)
        {
          'stage': puzzleStage,
          'puzzleId': puzzle.id,
          'foundWords': [for (final i in board.foundSlots.toList()..sort()) puzzle.slots[i].word],
          'hintsUsed': Map.of(_hintsUsed),
          'cleared': false,
        },
    ],
  };

  /// Kept on the phone after every change, so a run cut short by the app
  /// closing still counts.
  void _saveOpen() => store.saveOpenSurvival(report());

  /// Ends the run (melted, or the player left) and queues its result.
  /// Returns the report, or null if nothing was played.
  Map<String, Object>? finish() {
    if (finished) return null;
    finished = true;
    _watch?.cancel();
    _next?.cancel();
    _clock.stop();
    final run = report();
    store.saveOpenSurvival(null);
    final played = (run['puzzles'] as List).any(
      (p) => ((p as Map)['foundWords'] as List).isNotEmpty || (p['hintsUsed'] as Map).isNotEmpty,
    );
    if (!played) return null;
    store.enqueueSurvival(run);
    // Left mid-puzzle: that board too, as it was.
    if (stage == CrucibleStage.playing && (board.foundSlots.isNotEmpty || board.revealed.isNotEmpty)) {
      playedBoards.add(PlayedBoard.fromBoard(board));
    }
    onFinished?.call(this);
    return run;
  }

  @override
  void dispose() {
    _watch?.cancel();
    _next?.cancel();
    super.dispose();
  }

  String _newId() {
    final r = Random.secure();
    String hex(int n) => List.generate(n, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return '${hex(4)}-${hex(2)}-${hex(2)}-${hex(2)}-${hex(6)}';
  }
}
