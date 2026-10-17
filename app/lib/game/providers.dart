import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/sfx.dart';
import '../data/campaign.dart';
import '../data/profile.dart';
import '../data/store.dart';
import '../engine/board.dart';
import '../engine/hints.dart';
import '../engine/masterworks.dart';
import '../engine/progression.dart';
import '../net/models.dart';

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
    this.gildedPiece = false,
    this.masterwork,
    this.masterworkHints = const {},
  });

  final int xp;
  final LevelProgress before;
  final LevelProgress after;

  /// Level-up hint rewards.
  final Map<HintKind, int> hints;

  /// Hint types that became available with this level-up.
  final List<HintKind> unlocked;
  final bool chapterFinished;

  /// Whether this puzzle's gilded cell gave a blueprint piece.
  final bool gildedPiece;

  /// The Masterwork that piece finished. Its XP is in [xp]; its hints are
  /// [masterworkHints].
  final MasterworkSpec? masterwork;
  final Map<HintKind, int> masterworkHints;

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

  /// Takes the server's profile as the truth after a sync. [pending] is the
  /// puzzle in progress on this phone: its hint use, pickups and bonus words
  /// aren't on the server until it's finished, so they're applied on top.
  void applyServer(ServerProfile server, {SavedPuzzle? pending}) {
    final hints = {for (final k in HintKind.values) k: server.hints[k] ?? 0};
    var bin = server.scrapBin;
    if (pending != null) {
      for (final e in pending.hintsUsed.entries) {
        final k = HintKind.byName(e.key);
        hints[k] = (hints[k]! - e.value).clamp(0, 1 << 30);
      }
      for (final p in pending.collectedPickups) {
        hints[p.kind] = hints[p.kind]! + 1;
      }
      bin += pending.bonusFound.length;
      while (bin >= scrapBinCapacity) {
        bin -= scrapBinCapacity;
        hints[HintKind.hammer] = hints[HintKind.hammer]! + 1;
      }
    }
    final local = current;
    final s = server.stats;
    _set(
      local.copyWith(
        masterworkPieces: server.masterworkPieces + (pending?.gildedCollected == true ? 1 : 0),
        userId: server.id,
        totalXp: server.totalXp,
        campaignStage: server.nextStage > local.campaignStage
            ? server.nextStage
            : local.campaignStage,
        scrapBin: bin,
        hints: hints,
        stats: local.stats.copyWith(
          wordsForged: s.wordsForged,
          longestWord: s.longestWord.length >= local.stats.longestWord.length
              ? s.longestWord
              : local.stats.longestWord,
          soloDone: s.soloDone,
        ),
      ),
    );
  }

  /// Starts over with a fresh local profile (after deleting the account).
  Future<void> resetLocal() async {
    await _store.clearAll();
    state = _store.loadProfile();
  }

  /// Spends one hint of [kind]; false if the player has none.
  bool spendHint(HintKind kind) {
    if (state.hintCount(kind) <= 0) return false;
    _set(state.withHints(kind, -1));
    return true;
  }

  void addHint(HintKind kind, [int count = 1]) =>
      _set(state.withHints(kind, count));

  /// A blueprint piece from a gilded cell. Finishing a Masterwork is
  /// rewarded when the puzzle is forged.
  void addMasterworkPiece() => _set(state.copyWith(masterworkPieces: state.masterworkPieces + 1));

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
    required String pickupSeed,
  }) {
    final before = state.progress;
    // The piece was counted when it was collected; did it finish one?
    final masterwork = board.gildedCollected
        ? MasterworkProgress(state.masterworkPieces - 1).finishedBy(1)
        : null;
    final xp = soloXp(bonusWords: board.bonusFound.length) + (masterwork == null ? 0 : masterworkXp);
    var next = state.copyWith(totalXp: state.totalXp + xp);
    final after = next.progress;
    final hints = levelUpRewards(before.level, after.level);
    final masterworkHints = <HintKind, int>{};
    if (masterwork != null) {
      // Locked types become Hammer Strikes, judged after the puzzle's own XP.
      final level = levelForTotalXp(state.totalXp + xp - masterworkXp).level;
      for (final kind in [HintKind.chisel, HintKind.sparks]) {
        final k = kind.unlockedAt(level) ? kind : HintKind.hammer;
        masterworkHints[k] = (masterworkHints[k] ?? 0) + 1;
      }
    }
    for (final e in [...hints.entries, ...masterworkHints.entries]) {
      next = next.withHints(e.key, e.value);
    }
    final typed = [
      for (final i in board.foundSlots) board.puzzle.slots[i].word,
    ];
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
      'gilded': [?(board.gildedCollected ? board.gilded : null)],
      // The id pickups were seeded with (the install id before sign-in).
      'pickupSeed': pickupSeed,
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
      gildedPiece: board.gildedCollected,
      masterwork: masterwork,
      masterworkHints: masterworkHints,
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
