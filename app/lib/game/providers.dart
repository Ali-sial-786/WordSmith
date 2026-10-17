import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/sfx.dart';
import '../data/campaign.dart';
import '../data/profile.dart';
import '../data/store.dart';
import '../engine/board.dart';
import '../engine/hints.dart';
import '../engine/progression.dart';

/// Overridden in main() once loaded.
final storeProvider = Provider<Store>((_) => throw UnimplementedError());
final campaignProvider = Provider<Campaign>((_) => throw UnimplementedError());
final sfxProvider = Provider<Sfx>((_) => Sfx.silent());

final profileProvider = NotifierProvider<ProfileNotifier, Profile>(
  ProfileNotifier.new,
);

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(
  SettingsNotifier.new,
);

/// What the player earned for forging a campaign puzzle.
class CompletionReward {
  const CompletionReward({
    required this.xp,
    required this.before,
    required this.after,
    required this.hints,
    required this.unlocked,
    required this.chapterFinished,
  });

  final int xp;
  final LevelProgress before;
  final LevelProgress after;

  /// Level-up hint rewards.
  final Map<HintKind, int> hints;

  /// Hint types that became available with this level-up.
  final List<HintKind> unlocked;
  final bool chapterFinished;

  bool get leveledUp => after.level > before.level;
}

class ProfileNotifier extends Notifier<Profile> {
  Store get _store => ref.read(storeProvider);

  @override
  Profile build() => _store.loadProfile();

  /// The profile right now, for code outside widgets.
  Profile get current => state;

  void _set(Profile next) {
    state = next;
    _store.saveProfile(next);
  }

  /// Spends one hint of [kind]; false if the player has none.
  bool spendHint(HintKind kind) {
    if (state.hintCount(kind) <= 0) return false;
    _set(state.withHints(kind, -1));
    return true;
  }

  void addHint(HintKind kind, [int count = 1]) =>
      _set(state.withHints(kind, count));

  /// Drops a bonus word in the Scrap Bin. Returns true when the bin was
  /// full and got smelted into a Hammer Strike.
  bool addBonusWord() {
    var bin = state.scrapBin + 1;
    var next = state.copyWith(
      stats: state.stats.copyWith(bonusWords: state.stats.bonusWords + 1),
    );
    final smelted = bin >= scrapBinCapacity;
    if (smelted) {
      bin -= scrapBinCapacity;
      next = next.withHints(HintKind.hammer, 1);
    }
    _set(next.copyWith(scrapBin: bin));
    return smelted;
  }

  CompletionReward completeCampaignStage({
    required int stage,
    required Board board,
    required Map<String, int> hintsUsed,
    required int elapsedMs,
    required bool chapterFinished,
  }) {
    final before = state.progress;
    final xp = soloXp(bonusWords: board.bonusFound.length);
    var next = state.copyWith(totalXp: state.totalXp + xp);
    final after = next.progress;
    final hints = levelUpRewards(before.level, after.level);
    for (final e in hints.entries) {
      next = next.withHints(e.key, e.value);
    }
    final typed = [for (final i in board.foundSlots) board.puzzle.slots[i].word];
    var longest = state.stats.longestWord;
    for (final w in typed) {
      if (w.length > longest.length) longest = w;
    }
    next = next.copyWith(
      campaignStage: stage + 1 > state.campaignStage
          ? stage + 1
          : state.campaignStage,
      stats: next.stats.copyWith(
        wordsForged: next.stats.wordsForged + typed.length,
        longestWord: longest,
        soloDone: next.stats.soloDone + 1,
      ),
    );
    _set(next);
    _store.enqueueSync({
      'stage': stage,
      'puzzleId': board.puzzle.id,
      'foundWords': typed,
      'bonusWords': board.bonusFound.toList(),
      'hintsUsed': hintsUsed,
      'pickups': [
        for (final i in board.collectedPickups) board.pickups[i].toJson(),
      ],
      // The id pickups were seeded with (the install id before sign-in).
      'pickupSeed': state.userId,
      'durationMs': elapsedMs,
      'completedAt': DateTime.now().millisecondsSinceEpoch,
    });
    return CompletionReward(
      xp: xp,
      before: before,
      after: after,
      hints: hints,
      unlocked: [
        for (final k in HintKind.values)
          if (!k.unlockedAt(before.level) && k.unlockedAt(after.level)) k,
      ],
      chapterFinished: chapterFinished,
    );
  }
}

class SettingsNotifier extends Notifier<Settings> {
  @override
  Settings build() => ref.read(storeProvider).loadSettings();

  void update(Settings Function(Settings) change) {
    state = change(state);
    ref.read(storeProvider).saveSettings(state);
    ref.read(sfxProvider).applySettings(state);
  }
}
