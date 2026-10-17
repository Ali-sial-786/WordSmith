import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/store.dart';
import '../engine/board.dart';
import '../engine/heat.dart';
import '../engine/hints.dart';
import '../engine/progression.dart';
import '../engine/puzzle.dart';
import '../net/api_client.dart';
import '../net/models.dart';
import 'providers.dart';
import 'solo_game.dart';

/// Today's Daily Commission: a solo puzzle from the server, the same for
/// everyone. Hints come from your stock; the XP and streak come from the
/// server when it's forged (shared/daily.md).
class DailyGame extends SoloGame {
  DailyGame({
    required this.info,
    required this.api,
    required this.store,
    required this.profile,
    Random? rng,
  }) : _rng = rng ?? Random() {
    board = Board(info.puzzle);
    letters = info.puzzle.letters;
    order = List.generate(letters.length, (i) => i);
    _clock.start();
  }

  final DailyInfo info;
  final ApiClient api;
  final Store store;
  final ProfileNotifier profile;
  final Random _rng;

  @override
  late final Board board;
  @override
  late final String letters;
  @override
  late List<int> order;

  final Map<String, int> _hintsUsed = {};
  final Stopwatch _clock = Stopwatch();

  /// The server's answer, once forged.
  DailyOutcome? outcome;
  Future<CompletionReward>? _finishing;

  /// Each heat borrows a chapter's look.
  static const _looks = ['tin', 'copper', 'bronze', 'iron', 'steel', 'gold'];

  @override
  bool get isComplete => board.isComplete;
  @override
  String get look => _looks[(info.heat - 1).clamp(0, _looks.length - 1)];
  @override
  String get title => 'Daily Commission';
  @override
  String get subtitle => '${Heat.fromValue(info.heat.clamp(1, 6)).title} heat · ${info.date}';

  @override
  WordFeedback submit(String word) {
    if (isComplete) return WordFeedback(SubmitResult(SubmitOutcome.alreadyFound, word));
    final result = board.submit(word);
    final smelted = result.outcome == SubmitOutcome.bonus && profile.addBonusWord();
    notifyListeners();
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
      !isComplete && kind.unlockedAt(profile.current.level) && profile.current.hintCount(kind) > 0;

  @override
  RevealResult? useHammer() {
    if (!canUse(HintKind.hammer)) return null;
    final target = board.hammerTarget(_rng);
    return target == null ? null : _spend(HintKind.hammer, [target]);
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
    return targets.isEmpty ? null : _spend(HintKind.sparks, targets);
  }

  RevealResult _spend(HintKind kind, List<CellPos> cells) {
    profile.spendHint(kind);
    _hintsUsed[kind.name] = (_hintsUsed[kind.name] ?? 0) + 1;
    final result = board.reveal(cells);
    notifyListeners();
    return result;
  }

  @override
  void pause() {}

  /// Sends the result; safe to call again after a failure (it retries).
  @override
  Future<CompletionReward> finish() => _finishing ??= _send().catchError((Object e) {
    _finishing = null;
    throw e;
  });

  Future<CompletionReward> _send() async {
    _clock.stop();
    final before = profile.current.progress;
    final result = await api.completeDaily(
      date: info.date,
      foundWords: [for (final i in board.foundSlots) board.puzzle.slots[i].word],
      bonusWords: board.bonusFound.toList(),
      hintsUsed: Map.of(_hintsUsed),
      durationMs: _clock.elapsedMilliseconds,
    );
    outcome = result;
    profile.applyServer(result.profile, pending: store.loadSavedPuzzle());
    final after = profile.current.progress;
    return CompletionReward(
      xp: result.xp,
      before: before,
      after: after,
      hints: levelUpRewards(before.level, after.level),
      unlocked: [
        for (final k in HintKind.values)
          if (!k.unlockedAt(before.level) && k.unlockedAt(after.level)) k,
      ],
      chapterFinished: false,
    );
  }
}
