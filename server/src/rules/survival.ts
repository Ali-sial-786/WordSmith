/**
 * Survival (shared/survival.md): one unforged word at a time is **heated**,
 * with a countdown. Forge it in time and the next one heats up; let the
 * countdown run out and it **melts**, which ends the round (or the solo
 * run). Pure, so it's unit-tested in Node.
 *
 * - **Which word heats:** the slots in a random order, the first one among
 *   the shortest ({@link heatOrder}); the heated word is always the first in
 *   that order that isn't complete ({@link nextHeatedSlot}). Each mold works
 *   it out on its own.
 * - **Countdown:** {@link survivalHeatMs}, from the moment the previous
 *   heated slot completed (the round's `startsAt` for the first). In rooms
 *   the referee allows {@link SURVIVAL_GRACE_MS} past the deadline, and a
 *   countdown can be paused while its players are away ({@link HeatClock}).
 * - **The Crucible** (solo, `POST /v1/survival/solo`): checking a run the app
 *   played offline from campaign puzzles, its XP and the player's best run
 *   ({@link checkSurvivalRun}, {@link applySurvivalRun}).
 *
 * Co-op and Versus keep their clocks in their own rounds (coop-round.ts,
 * vs-round.ts); this file has the parts they share.
 *
 * Functions named `apply…`, `pause…` and `resume…` change what they're given in place.
 */

import { editionFor, type CampaignPuzzle } from "./campaign";
import type { HeatTier } from "./heat";
import type { Rand } from "./mold";
import type { PlayFacts } from "./orders";
import { applyXp, HINT_KINDS, noHints, type HintCounts, type XpAward } from "./progression";
import { couldBeFilled, isPlausibleDuration, MAX_COMPLETED_AT_SKEW_MS, parseHintCounts, spendHints, stringList } from "./sync";
import { normalizeWord } from "./words";

/** A room's game variant (CONFIG). Rooms are `classic` until the host picks another. */
export type Variant = "classic" | "survival";

export const VARIANTS: readonly Variant[] = ["classic", "survival"];

export function isVariant(value: unknown): value is Variant {
  return (VARIANTS as readonly unknown[]).includes(value);
}

// ---------------------------------------------------------------------------
// The countdown
// ---------------------------------------------------------------------------

/** How much longer (or shorter) a countdown is at each heat tier. */
export const HEAT_FACTOR: Readonly<Record<HeatTier, number>> = { 1: 1.6, 2: 1.45, 3: 1.3, 4: 1.15, 5: 1.0, 6: 0.9 };

/** No countdown is shorter than this. */
export const MIN_HEAT_MS = 8000;
/** Each word saved so far takes 3% off the next countdown, for the first 20. */
export const SAVED_SHRINK = 0.97;
export const SAVED_SHRINK_CAP = 20;

/** Rooms: a SUBMIT the referee handles this long past the deadline still counts. */
export const SURVIVAL_GRACE_MS = 300;
/** Rooms: a survival round's `endsAt` is only a safety cap, this long after `startsAt`. */
export const SURVIVAL_CAP_MS = 10 * 60_000;

/**
 * The countdown, in ms, for a slot of `len` letters at heat tier `heat`,
 * after `saved` words saved so far (shared/survival.md "Countdown"):
 * `max(8000, round((6000 + 2500 × len) × HEAT_FACTOR[heat] × 0.97 ^ min(saved, 20)))`.
 */
export function survivalHeatMs(len: number, heat: HeatTier, saved: number): number {
  const shrink = Math.pow(SAVED_SHRINK, Math.min(Math.max(saved, 0), SAVED_SHRINK_CAP));
  return Math.max(MIN_HEAT_MS, Math.round((6000 + 2500 * len) * HEAT_FACTOR[heat] * shrink));
}

// ---------------------------------------------------------------------------
// Which word heats
// ---------------------------------------------------------------------------

/**
 * The order slots heat up in for one round (or solo puzzle): a random
 * order, except that the first is one of the shortest slots (each of them
 * equally likely).
 */
export function heatOrder(slots: readonly { readonly slot: number; readonly len: number }[], rand: Rand): number[] {
  const order = slots.map((s) => s.slot);
  for (let i = order.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [order[i], order[j]] = [order[j]!, order[i]!];
  }
  const lenOf = new Map(slots.map((s) => [s.slot, s.len]));
  const shortest = Math.min(...slots.map((s) => s.len));
  // The first shortest one in a random order is a random one of them.
  const first = order.findIndex((slot) => lenOf.get(slot) === shortest);
  if (first > 0) order.unshift(...order.splice(first, 1));
  return order;
}

/** The heated slot: the first in `order` that isn't in `done` (forged, filled in by crossings, or revealed by hints). `null` once all are. */
export function nextHeatedSlot(order: readonly number[], done: ReadonlySet<number>): number | null {
  return order.find((slot) => !done.has(slot)) ?? null;
}

// ---------------------------------------------------------------------------
// One mold's clock, in a room
// ---------------------------------------------------------------------------

/** One mold's countdown: the co-op team's, or one Versus racer's. Plain JSON, kept in the round. */
export interface HeatClock {
  /** The heated slot, or `null` once every slot is complete. */
  slot: number | null;
  /** When this countdown started. */
  startsAt: number;
  /** When the slot melts (the referee allows {@link SURVIVAL_GRACE_MS} more). */
  deadline: number;
  durationMs: number;
  /** Heated words completed before their deadline so far this round. */
  saved: number;
  /** While paused (nobody there to forge): when the pause began. */
  pausedAt: number | null;
}

/** The first countdown of a round, from `startsAt` (when the countdown phase ends). */
export function firstClock(order: readonly number[], lenOf: (slot: number) => number, heat: HeatTier, startsAt: number): HeatClock {
  const slot = order[0] ?? null;
  const durationMs = slot === null ? 0 : survivalHeatMs(lenOf(slot), heat, 0);
  return { slot, startsAt, deadline: startsAt + durationMs, durationMs, saved: 0, pausedAt: null };
}

/**
 * After the mold changed at `now`: if the heated slot is now complete, it
 * counts as saved and the next one heats up, its countdown starting now.
 * True if the heated slot changed (the caller sends HEATED while one glows).
 */
export function applyHeatProgress(
  clock: HeatClock,
  order: readonly number[],
  done: ReadonlySet<number>,
  lenOf: (slot: number) => number,
  heat: HeatTier,
  now: number,
): boolean {
  if (clock.slot === null || !done.has(clock.slot)) return false;
  clock.saved += 1;
  clock.slot = nextHeatedSlot(order, done);
  clock.durationMs = clock.slot === null ? 0 : survivalHeatMs(lenOf(clock.slot), heat, clock.saved);
  clock.startsAt = now;
  clock.deadline = now + clock.durationMs;
  return true;
}

/** When the referee melts this clock's slot (its deadline plus the grace), or `null` while nothing glows or it's paused. */
export function meltAt(clock: HeatClock): number | null {
  return clock.slot === null || clock.pausedAt !== null ? null : clock.deadline + SURVIVAL_GRACE_MS;
}

/**
 * Pauses the countdown at `now`. False if it already was, nothing glows,
 * or the melt is already due (a pause can't save it).
 */
export function pauseClock(clock: HeatClock, now: number): boolean {
  const melt = meltAt(clock);
  if (melt === null || now >= melt) return false;
  clock.pausedAt = now;
  return true;
}

/**
 * Resumes a paused countdown at `now`: the deadline (and `startsAt`, so
 * `durationMs` still spans them) moves on by the pause. Time before the
 * countdown started (a pause during the round's countdown phase) isn't a
 * pause. False if it wasn't paused.
 */
export function resumeClock(clock: HeatClock, now: number): boolean {
  if (clock.pausedAt === null) return false;
  const shift = Math.max(0, now - Math.max(clock.pausedAt, clock.startsAt));
  clock.startsAt += shift;
  clock.deadline += shift;
  clock.pausedAt = null;
  return true;
}

/** `HEATED` (without `op`), and `heated` in `ROUND_START` and `SNAPSHOT`. */
export interface HeatedFields {
  readonly slot: number;
  readonly startsAt: number;
  readonly deadline: number;
  readonly durationMs: number;
  readonly saved: number;
  readonly serverNow: number;
}

/** What clients see of a clock, or `null` while nothing glows. */
export function heatedFields(clock: HeatClock, serverNow: number): HeatedFields | null {
  if (clock.slot === null) return null;
  return { slot: clock.slot, startsAt: clock.startsAt, deadline: clock.deadline, durationMs: clock.durationMs, saved: clock.saved, serverNow };
}

/** Co-op XP for a survival round: 2 per word saved, up to +30 (on top of `coopRoundXp`). */
export const SAVED_XP = 2;
export const SAVED_XP_CAP = 30;

export function survivalCoopBonusXp(saved: number): number {
  return Math.min(SAVED_XP * Math.max(saved, 0), SAVED_XP_CAP);
}

// ---------------------------------------------------------------------------
// The Crucible: checking a solo run (POST /v1/survival/solo)
// ---------------------------------------------------------------------------

/** Most puzzles one run may have. */
export const MAX_RUN_PUZZLES = 50;
/** A run's times may be this old at most when it's sent. */
export const MAX_RUN_AGE_MS = 24 * 3600_000;
/** XP: 1 per grid word found, 8 per puzzle cleared, at most 150 per run. */
export const RUN_WORD_XP = 1;
export const RUN_CLEARED_XP = 8;
export const RUN_XP_CAP = 150;
/** Stages a run may reach: up to the highest stage in `solo_results` plus this, and never less than {@link RUN_MIN_STAGE_LIMIT}. */
export const RUN_STAGE_REACH = 10;
export const RUN_MIN_STAGE_LIMIT = 30;

// Shape limits, as for a solo sync entry (sync.ts).
const MAX_STAGE = 100_000;
const MAX_FOUND_WORDS = 64;
const MAX_RUN_ID_LENGTH = 64;
const RUN_ID = /^[A-Za-z0-9_-]+$/;

/** One puzzle of a run, as the app sends it. */
export interface RunPuzzle {
  readonly stage: number;
  readonly puzzleId: string;
  readonly foundWords: readonly string[];
  readonly hintsUsed: Readonly<HintCounts>;
  readonly cleared: boolean;
}

/** `POST /v1/survival/solo`'s body. */
export interface SurvivalRun {
  readonly runId: string;
  readonly startedAt: number;
  readonly endedAt: number;
  /** Heated words saved over the whole run. */
  readonly saved: number;
  readonly puzzles: readonly RunPuzzle[];
}

export type ParsedRun = { readonly ok: true; readonly run: SurvivalRun } | { readonly ok: false; readonly detail: string };

function isCount(value: unknown, max: number): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= max;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Checks the body's shape (`invalid_run` with `detail` otherwise). `hintsUsed` may be left out. */
export function parseSurvivalRun(raw: Readonly<Record<string, unknown>>): ParsedRun {
  const bad = (detail: string): ParsedRun => ({ ok: false, detail });
  const { runId, startedAt, endedAt, saved } = raw;
  if (typeof runId !== "string" || runId.length > MAX_RUN_ID_LENGTH || !RUN_ID.test(runId)) return bad("runId");
  if (typeof startedAt !== "number" || !Number.isSafeInteger(startedAt)) return bad("startedAt");
  if (typeof endedAt !== "number" || !Number.isSafeInteger(endedAt)) return bad("endedAt");
  if (!isCount(saved, 100_000)) return bad("saved");
  if (!Array.isArray(raw.puzzles)) return bad("puzzles");
  if (raw.puzzles.length > MAX_RUN_PUZZLES) return bad(`puzzles: more than ${MAX_RUN_PUZZLES}`);

  const puzzles: RunPuzzle[] = [];
  for (const [i, p] of raw.puzzles.entries()) {
    const where = `puzzles[${i}]`;
    if (!isRecord(p)) return bad(where);
    if (!isCount(p.stage, MAX_STAGE) || p.stage < 1) return bad(`${where}.stage`);
    if (typeof p.puzzleId !== "string" || p.puzzleId.length > 32) return bad(`${where}.puzzleId`);
    const foundWords = stringList(p.foundWords, MAX_FOUND_WORDS);
    if (foundWords === null) return bad(`${where}.foundWords`);
    const hints = parseHintCounts(p.hintsUsed);
    if (!hints.ok) return bad(`${where}.${hints.detail}`);
    if (typeof p.cleared !== "boolean") return bad(`${where}.cleared`);
    puzzles.push({ stage: p.stage, puzzleId: p.puzzleId, foundWords, hintsUsed: hints.hints, cleared: p.cleared });
  }
  return { ok: true, run: { runId, startedAt, endedAt, saved, puzzles } };
}

/** The furthest stage a run may play: `max(highest stage in solo_results + 10, 30)`. */
export function runStageLimit(highestSoloStage: number): number {
  return Math.max(highestSoloStage + RUN_STAGE_REACH, RUN_MIN_STAGE_LIMIT);
}

/** A puzzle's found words, upper-cased and de-duplicated; `null` if any isn't plain A–Z. */
function foundSet(p: RunPuzzle): Set<string> | null {
  const out = new Set<string>();
  for (const raw of p.foundWords) {
    const word = normalizeWord(raw);
    if (word === null) return null;
    out.add(word);
  }
  return out;
}

/**
 * Why a run can't count (the `invalid_run` detail), or `null` if it can.
 * `puzzles` has the checking model of every stage in the run that's in the
 * campaign (or the Master Forge); `highestSoloStage` is the player's
 * highest stage in `solo_results` (0 for none).
 *
 * - every stage is in the campaign, with its own `puzzleId`, and no further than {@link runStageLimit};
 * - every found word is a grid word of its puzzle (or of an earlier
 *   campaign's puzzle at that stage, campaign.ts `editionFor`);
 * - a `cleared` puzzle's found words and hints could fill the mold (sync's `incomplete` check);
 * - `startedAt` ≤ `endedAt`, neither more than 24 h old or more than 10 minutes ahead;
 * - at least 1 s per found word over the whole run;
 * - `saved` is no more than the run's grid words.
 */
export function checkSurvivalRun(run: SurvivalRun, puzzles: ReadonlyMap<number, CampaignPuzzle>, highestSoloStage: number, now: number): string | null {
  const limit = runStageLimit(highestSoloStage);
  let words = 0;
  let slots = 0;
  for (const [i, p] of run.puzzles.entries()) {
    const where = `puzzles[${i}]`;
    const stagePuzzle = puzzles.get(p.stage);
    if (stagePuzzle === undefined) return `${where}: stage ${p.stage} isn't in the campaign`;
    if (p.puzzleId !== stagePuzzle.id) return `${where}: puzzleId isn't stage ${p.stage}'s`;
    if (p.stage > limit) return `${where}: stage ${p.stage} is beyond ${limit}`;
    const found = foundSet(p);
    // A run played on an earlier campaign is checked against its puzzles.
    const puzzle = editionFor(stagePuzzle, found ?? []);
    if (found === null || [...found].some((w) => !puzzle.gridWords.has(w))) return `${where}: a found word isn't a grid word`;
    if (p.cleared && !couldBeFilled(puzzle, found, p.hintsUsed)) return `${where}: incomplete`;
    words += found.size;
    slots += puzzle.gridWords.size;
  }
  if (run.endedAt < run.startedAt) return "endedAt is before startedAt";
  if (run.startedAt < now - MAX_RUN_AGE_MS) return "the run is more than 24 h old";
  if (run.endedAt > now + MAX_COMPLETED_AT_SKEW_MS) return "the run ends in the future";
  if (!isPlausibleDuration(run.endedAt - run.startedAt, words)) return "too_fast";
  if (run.saved > slots) return "saved is more than the run's words";
  return null;
}

/** What a run achieved, which is what best runs are compared by. */
export interface RunScore {
  /** Puzzles cleared. */
  readonly puzzles: number;
  /** Grid words found (each puzzle's counted once). */
  readonly words: number;
  readonly saved: number;
}

/** A player's best run (`best` and the profile's `survivalBest`): `at` is when it ended. */
export interface SurvivalBest extends RunScore {
  readonly at: number;
}

/** A run that passed {@link checkSurvivalRun}: what it scored. */
export function runScore(run: SurvivalRun): RunScore {
  let words = 0;
  for (const p of run.puzzles) words += foundSet(p)?.size ?? 0;
  return { puzzles: run.puzzles.filter((p) => p.cleared).length, words, saved: run.saved };
}

/** XP for a run: 1 per grid word found plus 8 per puzzle cleared, at most 150. */
export function runXp(score: RunScore): number {
  return Math.min(RUN_WORD_XP * score.words + RUN_CLEARED_XP * score.puzzles, RUN_XP_CAP);
}

/** Whether `score` beats `best`: more puzzles cleared, then more words, then more saved. A tie doesn't. */
export function isBetterRun(score: RunScore, best: RunScore | null): boolean {
  if (best === null) return true;
  if (score.puzzles !== best.puzzles) return score.puzzles > best.puzzles;
  if (score.words !== best.words) return score.words > best.words;
  return score.saved > best.saved;
}

/** A player's numbers a run changes. */
export interface SurvivalState {
  readonly totalXp: number;
  readonly hints: Readonly<HintCounts>;
  readonly wordsForged: number;
  readonly longestWord: string;
  readonly best: SurvivalBest | null;
}

export interface SurvivalAward {
  readonly score: RunScore;
  readonly xp: number;
  readonly award: XpAward;
  /** Hints used beyond the stock (never taken below zero), or `null`. */
  readonly hintsClamped: HintCounts | null;
  readonly state: SurvivalState;
  /** The run beat the player's best (or they had none), and is now `state.best`. */
  readonly newBest: boolean;
  /** What it counts towards the player's Work Orders. */
  readonly facts: PlayFacts;
}

/**
 * A checked run: its XP and any level-up rewards, the hints used taken off
 * the stock (never below zero, before the level-up rewards, as in solo
 * sync), its found words as words forged, and the best run.
 */
export function applySurvivalRun(state: SurvivalState, run: SurvivalRun): SurvivalAward {
  const score = runScore(run);
  const xp = runXp(score);
  const award = applyXp(state.totalXp, xp);
  const used = noHints();
  for (const p of run.puzzles) for (const kind of HINT_KINDS) used[kind] += p.hintsUsed[kind];
  const spent = spendHints(state.hints, noHints(), used, award.rewards);

  const forged = run.puzzles.flatMap((p) => [...(foundSet(p) ?? [])]);
  let longestWord = state.longestWord;
  for (const w of forged) if (w.length > longestWord.length) longestWord = w;
  const newBest = isBetterRun(score, state.best);
  return {
    score,
    xp,
    award,
    hintsClamped: spent.clamped,
    state: {
      totalXp: award.totalXp,
      hints: spent.hints,
      wordsForged: state.wordsForged + forged.length,
      longestWord,
      best: newBest ? { ...score, at: run.endedAt } : state.best,
    },
    newBest,
    facts: { soloPuzzles: score.puzzles, forged },
  };
}
