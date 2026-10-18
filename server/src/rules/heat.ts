/**
 * Heat tiers: puzzle difficulty and round timers (docs/DESIGN.md §5).
 */

export type HeatTier = 1 | 2 | 3 | 4 | 5 | 6;

/**
 * The host's pick for a room's heat (CONFIG): a tier, or `"auto"`, which
 * is the host's level in co-op and the median level in Versus.
 */
export type HeatChoice = HeatTier | "auto";

export function isHeatTier(value: unknown): value is HeatTier {
  return typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= 6;
}

export function isHeatChoice(value: unknown): value is HeatChoice {
  return value === "auto" || isHeatTier(value);
}

export interface HeatTierInfo {
  readonly tier: HeatTier;
  readonly name: string;
  /** Lowest Smith Level in this tier. */
  readonly minLevel: number;
  /** Highest Smith Level in this tier, or `null` for the open-ended top tier. */
  readonly maxLevel: number | null;
  /** Co-op round length in milliseconds. */
  readonly coopTimerMs: number;
  /** Versus round length in milliseconds. */
  readonly vsRoundTimerMs: number;
}

const SECOND = 1000;
const MINUTE = 60 * SECOND;

/** The DESIGN.md §5 table, from coolest to hottest. */
export const HEAT_TIERS: readonly HeatTierInfo[] = [
  { tier: 1, name: "Ember", minLevel: 1, maxLevel: 5, coopTimerMs: 3 * MINUTE, vsRoundTimerMs: 2 * MINUTE },
  { tier: 2, name: "Dull Red", minLevel: 6, maxLevel: 15, coopTimerMs: 3 * MINUTE, vsRoundTimerMs: 2 * MINUTE },
  { tier: 3, name: "Cherry Red", minLevel: 16, maxLevel: 30, coopTimerMs: 3 * MINUTE + 30 * SECOND, vsRoundTimerMs: 2 * MINUTE + 30 * SECOND },
  { tier: 4, name: "Orange", minLevel: 31, maxLevel: 50, coopTimerMs: 3 * MINUTE + 30 * SECOND, vsRoundTimerMs: 2 * MINUTE + 30 * SECOND },
  { tier: 5, name: "Yellow", minLevel: 51, maxLevel: 80, coopTimerMs: 4 * MINUTE, vsRoundTimerMs: 3 * MINUTE },
  { tier: 6, name: "White Heat", minLevel: 81, maxLevel: null, coopTimerMs: 4 * MINUTE, vsRoundTimerMs: 3 * MINUTE },
];

/** Details for a tier. */
export function heatInfo(tier: HeatTier): HeatTierInfo {
  const info = HEAT_TIERS[tier - 1];
  if (info === undefined) throw new RangeError(`unknown heat tier ${tier}`);
  return info;
}

/**
 * The heat tier for a Smith Level. Levels below 1 are treated as 1.
 * Co-op uses the host's level; Versus uses {@link medianLevel}.
 */
export function heatForLevel(level: number): HeatTier {
  const info = HEAT_TIERS.find((t) => t.maxLevel === null || level <= t.maxLevel);
  return info!.tier; // the top tier is open-ended, so a tier is always found
}

export function heatName(tier: HeatTier): string {
  return heatInfo(tier).name;
}

export function coopTimerMs(tier: HeatTier): number {
  return heatInfo(tier).coopTimerMs;
}

export function vsRoundTimerMs(tier: HeatTier): number {
  return heatInfo(tier).vsRoundTimerMs;
}

/**
 * Median Smith Level of a Versus room, as a whole level.
 *
 * With an even number of players the two middle levels are averaged and
 * rounded down, so the room never runs hotter than the true median.
 */
export function medianLevel(levels: readonly number[]): number {
  if (levels.length === 0) throw new RangeError("medianLevel needs at least one level");
  const sorted = [...levels].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  const upper = sorted[mid]!;
  if (sorted.length % 2 === 1) return upper;
  const lower = sorted[mid - 1]!;
  return Math.floor((lower + upper) / 2);
}

/** Heat for a Versus room: the tier of the median level. */
export function vsHeat(levels: readonly number[]): HeatTier {
  return heatForLevel(medianLevel(levels));
}

/** The heat a room plays: the host's pick, or what `"auto"` gives (`auto`). */
export function chosenHeat(choice: HeatChoice, auto: HeatTier): HeatTier {
  return choice === "auto" ? auto : choice;
}
