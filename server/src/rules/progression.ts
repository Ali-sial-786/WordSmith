/**
 * XP, Smith Level, ranks and hint rewards (docs/DESIGN.md §3 and §4.2).
 *
 * XP is stored as a running lifetime total; the level is derived from it.
 */

import { heatForLevel, type HeatTier } from "./heat";

// ---------------------------------------------------------------------------
// Hint types and unlocks (DESIGN.md §3.1)
// ---------------------------------------------------------------------------

export type HintKind = "hammer" | "chisel" | "sparks";

export const HINT_KINDS: readonly HintKind[] = ["hammer", "chisel", "sparks"];

export type HintCounts = Record<HintKind, number>;

/** The Smith Level at which each hint type becomes usable. */
export const HINT_UNLOCK_LEVEL: Readonly<HintCounts> = { hammer: 1, chisel: 5, sparks: 12 };

/** Hint stock for a brand-new player. */
export const STARTING_HINTS: Readonly<HintCounts> = { hammer: 3, chisel: 0, sparks: 0 };

export function noHints(): HintCounts {
  return { hammer: 0, chisel: 0, sparks: 0 };
}

export function isHintUnlocked(kind: HintKind, level: number): boolean {
  return level >= HINT_UNLOCK_LEVEL[kind];
}

export function unlockedHints(level: number): HintKind[] {
  return HINT_KINDS.filter((kind) => isHintUnlocked(kind, level));
}

// ---------------------------------------------------------------------------
// Levels (DESIGN.md §4.2)
// ---------------------------------------------------------------------------

/** XP needed to go from `level` to `level + 1`: 50 + 10 × level. */
export function xpToNext(level: number): number {
  return 50 + 10 * level;
}

/** Lifetime XP at which a player reaches `level` (level 1 starts at 0 XP). */
export function totalXpForLevel(level: number): number {
  if (level <= 1) return 0;
  // Sum of xpToNext(k) for k = 1 .. level-1.
  return (level - 1) * (50 + 5 * level);
}

/** Smith Level for a lifetime XP total. */
export function levelFromTotalXp(totalXp: number): number {
  let level = 1;
  while (totalXp >= totalXpForLevel(level + 1)) level++;
  return level;
}

export interface LevelProgress {
  readonly level: number;
  /** XP earned since reaching the current level. */
  readonly xpIntoLevel: number;
  /** XP the current level takes in total (the XP bar's length). */
  readonly xpForLevel: number;
}

/** Where a lifetime XP total sits on the XP bar. */
export function levelProgress(totalXp: number): LevelProgress {
  const level = levelFromTotalXp(totalXp);
  return {
    level,
    xpIntoLevel: Math.max(0, totalXp) - totalXpForLevel(level),
    xpForLevel: xpToNext(level),
  };
}

// ---------------------------------------------------------------------------
// Ranks (DESIGN.md §4.2)
// ---------------------------------------------------------------------------

export interface Rank {
  readonly name: string;
  readonly minLevel: number;
}

export const RANKS: readonly Rank[] = [
  { name: "Apprentice", minLevel: 1 },
  { name: "Journeyman", minLevel: 10 },
  { name: "Smith", minLevel: 25 },
  { name: "Master Smith", minLevel: 50 },
  { name: "Grandmaster", minLevel: 80 },
  { name: "Legend", minLevel: 120 },
];

/** Levels that start a new rank: 10, 25, 50, 80, 120. */
export const RANK_UP_LEVELS: readonly number[] = RANKS.slice(1).map((r) => r.minLevel);

export function rankForLevel(level: number): Rank {
  let rank = RANKS[0]!;
  for (const r of RANKS) if (level >= r.minLevel) rank = r;
  return rank;
}

export function isRankUpLevel(level: number): boolean {
  return RANK_UP_LEVELS.includes(level);
}

// ---------------------------------------------------------------------------
// Level-up rewards (DESIGN.md §3.2)
// ---------------------------------------------------------------------------

/** Hints granted for arriving at exactly `level` by levelling up. */
export function rewardsForReachingLevel(level: number): HintCounts {
  const rewards = noHints();
  if (level <= 1) return rewards;
  rewards.hammer += 1;
  if (level % 5 === 0 && isHintUnlocked("chisel", level)) rewards.chisel += 1;
  if (level % 10 === 0 && isHintUnlocked("sparks", level)) rewards.sparks += 1;
  if (isRankUpLevel(level)) {
    for (const kind of unlockedHints(level)) rewards[kind] += 1;
  }
  return rewards;
}

/**
 * Total hints granted for levelling up from `fromLevel` to `toLevel`, i.e.
 * the sum of {@link rewardsForReachingLevel} for every level in
 * (fromLevel, toLevel]. "Unlocked" is judged at each level being reached.
 * Returns all zeros if `toLevel <= fromLevel`.
 */
export function levelUpRewards(fromLevel: number, toLevel: number): HintCounts {
  const total = noHints();
  for (let level = Math.max(fromLevel, 1) + 1; level <= toLevel; level++) {
    const r = rewardsForReachingLevel(level);
    for (const kind of HINT_KINDS) total[kind] += r[kind];
  }
  return total;
}

export interface XpAward {
  readonly previousTotalXp: number;
  readonly totalXp: number;
  readonly previousLevel: number;
  readonly level: number;
  readonly levelsGained: number;
  readonly rank: Rank;
  readonly rankChanged: boolean;
  readonly rewards: HintCounts;
}

/** Adds `amount` XP to a lifetime total and works out any level-ups. */
export function applyXp(previousTotalXp: number, amount: number): XpAward {
  if (!Number.isInteger(amount) || amount < 0) {
    throw new RangeError(`XP amount must be a non-negative integer, got ${amount}`);
  }
  const totalXp = previousTotalXp + amount;
  const previousLevel = levelFromTotalXp(previousTotalXp);
  const level = levelFromTotalXp(totalXp);
  const rank = rankForLevel(level);
  return {
    previousTotalXp,
    totalXp,
    previousLevel,
    level,
    levelsGained: level - previousLevel,
    rank,
    rankChanged: rank !== rankForLevel(previousLevel),
    rewards: levelUpRewards(previousLevel, level),
  };
}

// ---------------------------------------------------------------------------
// XP per mode (DESIGN.md §4.2)
// ---------------------------------------------------------------------------

export const SOLO_BONUS_XP_CAP = 5;

/** Solo puzzle forged: 10, plus 1 per bonus word found (max +5). */
export function soloPuzzleXp(bonusWordsFound: number): number {
  return 10 + Math.min(Math.max(bonusWordsFound, 0), SOLO_BONUS_XP_CAP);
}

export interface CoopXpInput {
  /** The player's own points this round. */
  readonly points: number;
  /** Whether the team filled the whole mold before time ran out. */
  readonly teamFilledMold: boolean;
  readonly isMvp: boolean;
}

/** Co-op round: 20 for taking part, +1 per 10 points, +20 if the mold was filled, +10 for MVP. */
export function coopRoundXp(input: CoopXpInput): number {
  return (
    20 +
    Math.floor(Math.max(input.points, 0) / 10) +
    (input.teamFilledMold ? 20 : 0) +
    (input.isMvp ? 10 : 0)
  );
}

export interface VsXpInput {
  readonly roundsPlayed: number;
  readonly roundsWon: number;
  readonly wonSeries: boolean;
}

/** Versus series: 5 per round played, +10 per round won, +30 for winning the series. */
export function vsSeriesXp(input: VsXpInput): number {
  return 5 * input.roundsPlayed + 10 * input.roundsWon + (input.wonSeries ? 30 : 0);
}

// ---------------------------------------------------------------------------
// XP and heat (shared/room-protocol.md "XP and heat")
// ---------------------------------------------------------------------------

/** Co-op and Versus XP multiplier by heat tier, in tenths: ×1.0 at Ember up to ×2.0 at White Heat. */
export const HEAT_XP_TENTHS: Readonly<Record<HeatTier, number>> = { 1: 10, 2: 12, 3: 14, 4: 16, 5: 18, 6: 20 };
/** Added to the multiplier, in tenths, for each tier the game ran above the player's own (+1.0 at most, 5 tiers up). */
export const PLAYING_UP_XP_TENTHS = 2;

export interface HeatXp {
  /** The XP at this heat. */
  readonly xp: number;
  /** What the heat added: `xp` less the XP before it. */
  readonly heatBonus: number;
  /** Tiers the game ran above the player's own (the tier for their level); 0 at or below it. */
  readonly tiersAbove: number;
}

/**
 * Room XP at the heat played: `base` times the tier's multiplier, plus 0.2
 * for each tier above the tier for the player's `level`, rounded. So a
 * newcomer in a hot game earns clearly more, and a strong player who picks
 * a cool heat gets only that heat's multiplier.
 */
export function heatXp(base: number, heat: HeatTier, level: number): HeatXp {
  const tiersAbove = Math.max(0, heat - heatForLevel(level));
  const xp = Math.round((base * (HEAT_XP_TENTHS[heat] + PLAYING_UP_XP_TENTHS * tiersAbove)) / 10);
  return { xp, heatBonus: xp - base, tiersAbove };
}

// ---------------------------------------------------------------------------
// Scrap Bin (DESIGN.md §3.2 item 3)
// ---------------------------------------------------------------------------

/** Bonus words smelted into one Hammer Strike. */
export const SCRAP_BIN_SIZE = 10;

export interface ScrapBinResult {
  /** Bonus words left in the bin (0–9). */
  readonly bin: number;
  /** Hammer Strikes smelted from the bin. */
  readonly hammers: number;
}

/** Adds bonus words to the Scrap Bin; every 10 become a Hammer Strike. */
export function addToScrapBin(bin: number, bonusWords: number): ScrapBinResult {
  const total = bin + bonusWords;
  return { bin: total % SCRAP_BIN_SIZE, hammers: Math.floor(total / SCRAP_BIN_SIZE) };
}
