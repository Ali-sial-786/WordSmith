import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/campaign.dart';
import '../data/store.dart';
import '../engine/board.dart';
import '../engine/hints.dart';
import '../engine/pickups.dart';
import '../engine/puzzle.dart';
import 'providers.dart';

/// What happened after the player lifted their finger.
class WordFeedback {
  const WordFeedback(this.result, {this.smelted = false});

  final SubmitResult result;

  /// The bonus word filled the Scrap Bin, which became a Hammer Strike.
  final bool smelted;
}

/// Runs one campaign puzzle: the board, the anvil order, hints and saving.
class SoloController extends ChangeNotifier {
  SoloController({
    required this.stage,
    required this.campaign,
    required this.store,
    required this.profile,
    Random? rng,
  }) : puzzle = campaign.puzzle(stage),
       _rng = rng ?? Random() {
    final saved = store.loadSavedPuzzle();
    if (saved != null && saved.stage == stage && saved.puzzleId == puzzle.id) {
      board = saved.toBoard(puzzle);
      letters = saved.letters;
      _hintsUsed.addAll(saved.hintsUsed);
      _elapsedBefore = saved.elapsedMs;
      pickupSeed = saved.pickupSeed.isEmpty ? profile.current.userId : saved.pickupSeed;
    } else {
      final p = profile.current;
      pickupSeed = p.userId;
      board = Board(
        puzzle,
        pickups: pickupsFor(
          userId: pickupSeed,
          puzzleId: puzzle.id,
          cellCount: puzzle.letterCount,
          level: p.level,
        ),
      );
      letters = puzzle.letters;
      _save();
    }
    order = List.generate(letters.length, (i) => i);
    _clock.start();
  }

  final int stage;
  final Campaign campaign;
  final Store store;
  final ProfileNotifier profile;
  final Puzzle puzzle;
  final Random _rng;

  late final Board board;

  /// Tile letters (fixed for the life of this screen).
  late final String letters;

  /// Ring position → tile index.
  late List<int> order;

  /// The id this puzzle's pickups were seeded with.
  late final String pickupSeed;

  final Map<String, int> _hintsUsed = {};
  final Stopwatch _clock = Stopwatch();
  int _elapsedBefore = 0;
  CompletionReward? reward;

  Chapter get chapter => campaign.chapterFor(stage);
  int get stageInChapter => stage - chapter.first + 1;
  bool get isComplete => board.isComplete;
  int get elapsedMs => _elapsedBefore + _clock.elapsedMilliseconds;

  WordFeedback submit(String word) {
    if (isComplete) {
      return WordFeedback(SubmitResult(SubmitOutcome.alreadyFound, word));
    }
    final result = board.submit(word);
    var smelted = false;
    switch (result.outcome) {
      case SubmitOutcome.found:
        _collect(result.collected);
      case SubmitOutcome.bonus:
        smelted = profile.addBonusWord();
      default:
        break;
    }
    _changed();
    return WordFeedback(result, smelted: smelted);
  }

  /// Turn: reshuffle the anvil, never landing on the same arrangement.
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
      !isComplete &&
      kind.unlockedAt(profile.current.level) &&
      profile.current.hintCount(kind) > 0;

  RevealResult? useHammer() {
    if (!canUse(HintKind.hammer)) return null;
    final target = board.hammerTarget(_rng);
    if (target == null) return null;
    return _spend(HintKind.hammer, [target]);
  }

  RevealResult? useChisel(CellPos cell) {
    if (!canUse(HintKind.chisel) || board.isFilled(cell)) return null;
    return _spend(HintKind.chisel, [cell]);
  }

  RevealResult? useSparks() {
    if (!canUse(HintKind.sparks)) return null;
    final targets = board.sparksTargets(_rng);
    if (targets.isEmpty) return null;
    return _spend(HintKind.sparks, targets);
  }

  RevealResult _spend(HintKind kind, List<CellPos> cells) {
    profile.spendHint(kind);
    _hintsUsed[kind.name] = (_hintsUsed[kind.name] ?? 0) + 1;
    final result = board.reveal(cells);
    _collect(result.collected);
    _changed();
    return result;
  }

  void _collect(List<Pickup> pickups) {
    for (final p in pickups) {
      profile.addHint(p.kind);
    }
  }

  void _changed() {
    if (isComplete && reward == null) {
      _clock.stop();
      reward = profile.completeCampaignStage(
        stage: stage,
        board: board,
        hintsUsed: Map.of(_hintsUsed),
        elapsedMs: elapsedMs,
        chapterFinished: stage == chapter.last,
        pickupSeed: pickupSeed,
      );
      store.clearSavedPuzzle();
    } else if (!isComplete) {
      _save();
    }
    notifyListeners();
  }

  void _save() => store.savePuzzle(
    SavedPuzzle.fromBoard(
      stage: stage,
      board: board,
      letters: letters,
      hintsUsed: Map.of(_hintsUsed),
      elapsedMs: elapsedMs,
      pickupSeed: pickupSeed,
    ),
  );

  /// Saves the play time when leaving mid-puzzle.
  void pause() {
    if (!isComplete) _save();
  }
}
