/**
 * The Daily Commission (shared/daily.md): one puzzle a day, the same for
 * everyone, solved solo with the answers on the phone and checked by the
 * server when it's sent, with a streak of days in a row. Pure: the route
 * reads the day's puzzle and the player's completions and writes what these
 * return. The checks and the hint, Scrap Bin and XP arithmetic are solo
 * sync's (sync.ts, progression.ts).
 */

import type { CampaignPuzzle } from "./campaign";
import type { HeatTier } from "./heat";
import { fnv1a32 } from "./pickups";
import { addToScrapBin, applyXp, noHints, type HintCounts, type ScrapBinResult, type XpAward } from "./progression";
import { couldBeFilled, isPlausibleDuration, parseHintCounts, spendHints, stringList } from "./sync";
import { normalizeWord } from "./words";

/** XP for a day's first completion: 25, plus 5 per streak day beyond the first, up to +30. */
export const DAILY_BASE_XP = 25;
export const DAILY_STREAK_XP = 5;
export const DAILY_STREAK_XP_CAP = 30;
/** Yesterday's puzzle may still be sent this long into the new UTC day. */
export const DAILY_GRACE_MS = 3600_000;

const DAY_MS = 86_400_000;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
// Shape limits, as for a solo sync entry.
const MAX_FOUND_WORDS = 64;
const MAX_BONUS_WORDS = 1000;
const MAX_DURATION_MS = 30 * DAY_MS;

// ---------------------------------------------------------------------------
// Days
// ---------------------------------------------------------------------------

/** The UTC date of `ms`, `YYYY-MM-DD`. */
export function utcDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/** Whether `value` is a real `YYYY-MM-DD` date. */
export function isDate(value: unknown): value is string {
  return typeof value === "string" && DATE_RE.test(value) && !Number.isNaN(Date.parse(`${value}T00:00:00Z`)) && utcDate(Date.parse(`${value}T00:00:00Z`)) === value;
}

/** `date` moved by `days` (negative goes back). */
export function addDays(date: string, days: number): string {
  return utcDate(Date.parse(`${date}T00:00:00Z`) + days * DAY_MS);
}

/** Heat by weekday (getUTCDay order, Sunday first): Sun 3, Mon 1, Tue 2, Wed 3, Thu 4, Fri 5, Sat 6. */
const WEEKDAY_HEAT: readonly HeatTier[] = [3, 1, 2, 3, 4, 5, 6];

/** The day's heat: Monday Ember (1) up to Saturday White Heat (6); Sunday is Cherry Red (3). */
export function dailyHeat(date: string): HeatTier {
  return WEEKDAY_HEAT[new Date(`${date}T00:00:00Z`).getUTCDay()]!;
}

/** Which of `count` candidates (size-1 bank puzzles at the day's heat, ordered by id) is the day's puzzle. */
export function dailyIndex(date: string, count: number): number {
  if (!Number.isInteger(count) || count < 1) throw new RangeError(`need at least one candidate, got ${count}`);
  return fnv1a32(`daily:${date}`) % count;
}

/** The id the day's puzzle goes by (shared/daily.md). */
export function dailyPuzzleId(date: string): string {
  return `daily-${date}`;
}

/** A completion sent at `now` may be for today, or for yesterday within the first hour of today. */
export function isCompletableDay(date: string, now: number): boolean {
  const today = utcDate(now);
  if (date === today) return true;
  return date === addDays(today, -1) && now - Date.parse(`${today}T00:00:00Z`) < DAILY_GRACE_MS;
}

// ---------------------------------------------------------------------------
// Streaks and XP
// ---------------------------------------------------------------------------

/** Days completed in a row, ending on `end` (0 if `end` itself wasn't completed). */
export function streakEndingOn(days: ReadonlySet<string>, end: string): number {
  let n = 0;
  for (let d = end; days.has(d); d = addDays(d, -1)) n++;
  return n;
}

export interface Streaks {
  /** Days in a row ending today, or yesterday if today isn't done yet. */
  readonly streak: number;
  /** The longest run ever. */
  readonly best: number;
}

export function streaks(completed: Iterable<string>, today: string): Streaks {
  const days = new Set(completed);
  const streak = days.has(today) ? streakEndingOn(days, today) : streakEndingOn(days, addDays(today, -1));
  let best = 0;
  for (const d of days) {
    // Count each run once, from its first day.
    if (days.has(addDays(d, -1))) continue;
    let n = 0;
    for (let x = d; days.has(x); x = addDays(x, 1)) n++;
    best = Math.max(best, n);
  }
  return { streak, best };
}

/** XP for a day's first completion, with `streak` counting that day: 25 to 55. */
export function dailyXp(streak: number): number {
  return DAILY_BASE_XP + Math.min(DAILY_STREAK_XP * Math.max(streak - 1, 0), DAILY_STREAK_XP_CAP);
}

// ---------------------------------------------------------------------------
// Checking a completion
// ---------------------------------------------------------------------------

/** `POST /v1/daily/complete`'s body. */
export interface DailyCompletion {
  readonly date: string;
  readonly foundWords: readonly string[];
  readonly bonusWords: readonly string[];
  readonly hintsUsed: Readonly<HintCounts>;
  readonly durationMs: number;
}

export type ParsedCompletion = { readonly ok: true; readonly completion: DailyCompletion } | { readonly ok: false; readonly detail: string };

/** Checks the body's shape. `bonusWords` and `hintsUsed` may be left out. */
export function parseDailyCompletion(raw: Readonly<Record<string, unknown>>): ParsedCompletion {
  const bad = (detail: string): ParsedCompletion => ({ ok: false, detail });
  if (!isDate(raw.date)) return bad("date");
  const foundWords = stringList(raw.foundWords, MAX_FOUND_WORDS);
  if (foundWords === null) return bad("foundWords");
  const bonusWords = raw.bonusWords === undefined ? [] : stringList(raw.bonusWords, MAX_BONUS_WORDS);
  if (bonusWords === null) return bad("bonusWords");
  const hints = parseHintCounts(raw.hintsUsed);
  if (!hints.ok) return bad(hints.detail);
  const d = raw.durationMs;
  if (typeof d !== "number" || !Number.isSafeInteger(d) || d < 0 || d > MAX_DURATION_MS) return bad("durationMs");
  return { ok: true, completion: { date: raw.date, foundWords, bonusWords, hintsUsed: hints.hints, durationMs: d } };
}

/** The grid words among those typed, and the puzzle's bonus words among those found (others are ignored). */
function wordsOf(c: DailyCompletion, puzzle: CampaignPuzzle): { readonly found: Set<string>; readonly bonus: Set<string> } {
  const keep = (words: readonly string[], allowed: ReadonlySet<string>) => {
    const out = new Set<string>();
    for (const raw of words) {
      const w = normalizeWord(raw);
      if (w !== null && allowed.has(w)) out.add(w);
    }
    return out;
  };
  return { found: keep(c.foundWords, puzzle.gridWords), bonus: keep(c.bonusWords, puzzle.bonus) };
}

export type DailyProblem = "incomplete" | "too_fast";

/**
 * Why a completion can't count, as in solo sync: the typed grid words and
 * the hints used must be able to fill every letter cell (`incomplete`;
 * slots that filled in by themselves needn't be typed), and it must have
 * taken at least 1 s per word typed (`too_fast`).
 */
export function checkDaily(c: DailyCompletion, puzzle: CampaignPuzzle): DailyProblem | null {
  const { found } = wordsOf(c, puzzle);
  if (!couldBeFilled(puzzle, found, c.hintsUsed)) return "incomplete";
  if (!isPlausibleDuration(c.durationMs, found.size)) return "too_fast";
  return null;
}

// ---------------------------------------------------------------------------
// Applying one
// ---------------------------------------------------------------------------

/** A player's numbers a completion changes. */
export interface DailyState {
  readonly totalXp: number;
  readonly scrapBin: number;
  readonly hints: Readonly<HintCounts>;
  readonly wordsForged: number;
  readonly longestWord: string;
}

export interface DailyAward {
  readonly xp: number;
  readonly award: XpAward;
  readonly scrap: ScrapBinResult;
  /** Hints used beyond the stock (never taken below zero), or `null`. */
  readonly hintsClamped: HintCounts | null;
  readonly state: DailyState;
}

/**
 * A day's first completion, with `streak` counting that day: daily XP and
 * any level-up rewards, the valid bonus words into the Scrap Bin, and the
 * hints used taken off the stock (after the Scrap Bin's hammers, before
 * the level-up rewards, as in solo sync). Typed grid words count as words
 * forged.
 */
export function applyDaily(state: DailyState, c: DailyCompletion, puzzle: CampaignPuzzle, streak: number): DailyAward {
  const { found, bonus } = wordsOf(c, puzzle);
  const xp = dailyXp(streak);
  const award = applyXp(state.totalXp, xp);
  const scrap = addToScrapBin(state.scrapBin, bonus.size);
  const gained = noHints();
  gained.hammer += scrap.hammers;
  const spent = spendHints(state.hints, gained, c.hintsUsed, award.rewards);
  let longestWord = state.longestWord;
  for (const w of found) if (w.length > longestWord.length) longestWord = w;
  return {
    xp,
    award,
    scrap,
    hintsClamped: spent.clamped,
    state: { totalXp: award.totalXp, scrapBin: scrap.bin, hints: spent.hints, wordsForged: state.wordsForged + found.size, longestWord },
  };
}
