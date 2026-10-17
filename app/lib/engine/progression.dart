/// XP, Smith Level, ranks and level-up rewards (DESIGN.md §3.2, §4.2).
/// Mirrors `server/src/rules/progression.ts`; the server is authoritative.
library;

import 'hints.dart';

/// XP needed to go from [level] to [level] + 1.
int xpToNext(int level) => 50 + 10 * level;

class LevelProgress {
  const LevelProgress(this.level, this.xpIntoLevel, this.xpForNext);

  final int level;
  final int xpIntoLevel;
  final int xpForNext;

  double get fraction => xpForNext == 0 ? 0 : xpIntoLevel / xpForNext;
}

/// The level reached with [totalXp] (everyone starts at level 1 with 0 XP).
LevelProgress levelForTotalXp(int totalXp) {
  var level = 1;
  var remaining = totalXp;
  while (remaining >= xpToNext(level)) {
    remaining -= xpToNext(level);
    level++;
  }
  return LevelProgress(level, remaining, xpToNext(level));
}

enum Rank {
  apprentice('Apprentice', 1),
  journeyman('Journeyman', 10),
  smith('Smith', 25),
  masterSmith('Master Smith', 50),
  grandmaster('Grandmaster', 80),
  legend('Legend', 120);

  const Rank(this.title, this.minLevel);

  final String title;
  final int minLevel;

  static Rank forLevel(int level) =>
      Rank.values.lastWhere((r) => level >= r.minLevel);

  static bool isRankUpLevel(int level) =>
      Rank.values.any((r) => r.minLevel == level && r.minLevel > 1);
}

/// Hints granted for climbing from [fromLevel] to [toLevel] (exclusive of
/// [fromLevel], inclusive of [toLevel]).
Map<HintKind, int> levelUpRewards(int fromLevel, int toLevel) {
  final rewards = {for (final k in HintKind.values) k: 0};
  for (var level = fromLevel + 1; level <= toLevel; level++) {
    rewards[HintKind.hammer] = rewards[HintKind.hammer]! + 1;
    if (level % 5 == 0 && HintKind.chisel.unlockedAt(level)) {
      rewards[HintKind.chisel] = rewards[HintKind.chisel]! + 1;
    }
    if (level % 10 == 0 && HintKind.sparks.unlockedAt(level)) {
      rewards[HintKind.sparks] = rewards[HintKind.sparks]! + 1;
    }
    if (Rank.isRankUpLevel(level)) {
      for (final kind in HintKind.values) {
        if (kind.unlockedAt(level)) rewards[kind] = rewards[kind]! + 1;
      }
    }
  }
  rewards.removeWhere((_, n) => n == 0);
  return rewards;
}

/// XP for forging a solo puzzle.
int soloXp({required int bonusWords}) =>
    10 + (bonusWords < 5 ? bonusWords : 5);
