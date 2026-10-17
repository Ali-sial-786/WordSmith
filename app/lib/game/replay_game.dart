import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/campaign.dart';
import '../engine/board.dart';
import '../engine/hints.dart';
import '../engine/puzzle.dart';
import 'providers.dart';
import 'solo_game.dart';

/// A campaign puzzle played again from the chapter map, just for fun: no
/// hints, pickups, gilded cells, Scrap Bin or XP, and nothing is saved.
class ReplayGame extends SoloGame {
  ReplayGame({required this.stage, required this.campaign, required this.profile, Random? rng})
    : puzzle = campaign.puzzle(stage),
      _rng = rng ?? Random() {
    board = Board(puzzle);
    order = List.generate(letters.length, (i) => i);
  }

  final int stage;
  final Campaign campaign;
  final ProfileNotifier profile;
  final Puzzle puzzle;
  final Random _rng;

  @override
  late final Board board;
  @override
  String get letters => puzzle.letters;
  @override
  late List<int> order;

  Chapter get chapter => campaign.chapterFor(stage);
  @override
  bool get isComplete => board.isComplete;
  @override
  String get look => chapter.id;
  @override
  String get title => chapter.name;
  @override
  String get subtitle => campaign.isMaster(stage)
      ? 'Replay · Puzzle ${stage - chapter.first + 1}'
      : 'Replay · Puzzle ${stage - chapter.first + 1} of ${chapter.count}';

  @override
  WordFeedback submit(String word) {
    if (isComplete) return WordFeedback(SubmitResult(SubmitOutcome.alreadyFound, word));
    final result = board.submit(word);
    notifyListeners();
    return WordFeedback(result);
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
  bool canUse(HintKind kind) => false;
  @override
  RevealResult? useHammer() => null;
  @override
  RevealResult? useChisel(CellPos cell) => null;
  @override
  RevealResult? useSparks() => null;
  @override
  void pause() {}

  @override
  Future<CompletionReward> finish() async {
    final now = profile.current.progress;
    return CompletionReward(xp: 0, before: now, after: now, hints: const {}, unlocked: const [], chapterFinished: false);
  }
}
