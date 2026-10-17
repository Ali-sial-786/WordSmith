import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/campaign.dart';
import '../data/store.dart';
import '../engine/board.dart';
import '../engine/hints.dart';
import '../engine/masterworks.dart';
import '../engine/pickups.dart';
import '../engine/puzzle.dart';
import 'providers.dart';
import 'solo_game.dart';

export 'solo_game.dart';

/// Runs one campaign puzzle: the board, the anvil order, hints and saving.
class SoloController extends SoloGame {
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
      final pickups = pickupsFor(
        userId: pickupSeed,
        puzzleId: puzzle.id,
        cellCount: puzzle.letterCount,
        level: p.level,
      );
      board = Board(
        puzzle,
        pickups: pickups,
        gilded: gildedCellFor(
          userId: pickupSeed,
          puzzleId: puzzle.id,
          cellCount: puzzle.letterCount,
          pickups: pickups,
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

  @override
  late final Board board;

  @override
  late final String letters;

  @override
  late List<int> order;

  /// The id this puzzle's pickups were seeded with.
  late final String pickupSeed;

  final Map<String, int> _hintsUsed = {};
  final Stopwatch _clock = Stopwatch();
  int _elapsedBefore = 0;
  CompletionReward? reward;

  Chapter get chapter => campaign.chapterFor(stage);
  int get stageInChapter => stage - chapter.first + 1;
  @override
  bool get isComplete => board.isComplete;
  @override
  String get look => chapter.id;
  @override
  String get title => chapter.name;
  @override
  String get subtitle =>
      campaign.isMaster(stage) ? 'Puzzle $stageInChapter' : 'Puzzle $stageInChapter of ${chapter.count}';

  @override
  Future<CompletionReward> finish() async => reward!;
  int get elapsedMs => _elapsedBefore + _clock.elapsedMilliseconds;

  @override
  WordFeedback submit(String word) {
    if (isComplete) {
      return WordFeedback(SubmitResult(SubmitOutcome.alreadyFound, word));
    }
    final result = board.submit(word);
    var smelted = false;
    switch (result.outcome) {
      case SubmitOutcome.found:
        _collect(result.collected, gilded: result.gilded);
      case SubmitOutcome.bonus:
        smelted = profile.addBonusWord();
      default:
        break;
    }
    _changed();
    return WordFeedback(result, smelted: smelted);
  }

  @override
  void turn() {
    if (order.length < 2) return;
    final next = [...order];
    do {
      next.shuffle(_rng);
    } while (listEquals(next, order));
    order = next;
    notifyListeners();
  }

  @override
  bool canUse(HintKind kind) =>
      !isComplete &&
      kind.unlockedAt(profile.current.level) &&
      profile.current.hintCount(kind) > 0;

  @override
  RevealResult? useHammer() {
    if (!canUse(HintKind.hammer)) return null;
    final target = board.hammerTarget(_rng);
    if (target == null) return null;
    return _spend(HintKind.hammer, [target]);
  }

  @override
  RevealResult? useChisel(CellPos cell) {
    if (!canUse(HintKind.chisel) || board.isFilled(cell)) return null;
    return _spend(HintKind.chisel, [cell]);
  }

  @override
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
    _collect(result.collected, gilded: result.gilded);
    _changed();
    return result;
  }

  void _collect(List<Pickup> pickups, {required bool gilded}) {
    for (final p in pickups) {
      profile.addHint(p.kind);
    }
    if (gilded) profile.addMasterworkPiece();
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

  @override
  void pause() {
    if (!isComplete) _save();
  }
}
