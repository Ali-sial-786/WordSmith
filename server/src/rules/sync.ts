/**
 * Checking and applying a batch of offline solo results (docs/TECH.md §8).
 *
 * Pure: the route loads the player's state and the campaign puzzles, calls
 * {@link evaluateSync}, and writes what it returns.
 *
 * Entries are applied in `completedAt` order, so each one's level-up rewards
 * and pickup types use the level the player had when that puzzle started.
 * An entry is rejected (and changes nothing) if:
 *
 * | reason | when |
 * |---|---|
 * | `invalid_entry` | it isn't shaped like a queue entry |
 * | `unknown_stage` | the stage isn't in the campaign |
 * | `puzzle_mismatch` | `puzzleId` isn't that stage's puzzle |
 * | `duplicate` | the stage was already counted (in `solo_results`, or earlier in this batch) |
 * | `bad_completed_at` | `completedAt` is in the future or before the game existed |
 * | `unknown_word` | a found word isn't one of the puzzle's grid words |
 * | `unknown_bonus_word` | a bonus word isn't in the puzzle's bonus list |
 * | `incomplete` | the found words plus the hints used can't have filled every cell |
 * | `too_fast` | under {@link MIN_MS_PER_FOUND_WORD} per found word |
 *
 * An accepted entry grants solo XP (and any level-up rewards), puts its
 * bonus words in the Scrap Bin (each 10 → a Hammer Strike), grants the
 * claimed pickups the server can reproduce, and takes off the hints used.
 * Hint stock never goes below zero: an overdraw is clamped and reported.
 */

import type { CampaignPuzzle } from "./campaign";
import { pickupsFor } from "./pickups";
import {
  addToScrapBin,
  applyXp,
  HINT_KINDS,
  levelFromTotalXp,
  noHints,
  soloPuzzleXp,
  type HintCounts,
  type HintKind,
} from "./progression";
import { normalizeWord } from "./words";

/** Most entries one `POST /v1/solo/sync` may carry; the app sends bigger queues in chunks. */
export const MAX_SYNC_ENTRIES = 100;

/** Plausibility floor: at least this long per word the player typed. Tunable. */
export const MIN_MS_PER_FOUND_WORD = 1000;

/** Letters one Spark Shower reveals (DESIGN.md §3.1). */
export const SPARK_SHOWER_LETTERS = 5;

/** How many different install ids one account may use as pickup seeds. */
export const MAX_INSTALL_SEEDS = 5;

/** The app's pre-account id: `install-` + 16 random bytes in hex (app/lib/data/store.dart). */
export const INSTALL_SEED_PATTERN = /^install-[0-9a-f]{32}$/;

/** How far in the future `completedAt` may be (phones' clocks drift). */
export const MAX_COMPLETED_AT_SKEW_MS = 10 * 60 * 1000;

/** Nothing can have been completed before the game existed. */
export const EARLIEST_COMPLETED_AT = Date.UTC(2026, 0, 1);

// Shape limits for one entry. Real puzzles stay well inside them
// (at most 20 grid words, 8-letter words, a few hundred bonus words).
const MAX_STAGE = 100_000;
const MAX_FOUND_WORDS = 64;
const MAX_BONUS_WORDS = 1000;
const MAX_WORD_LENGTH = 16;
const MAX_PICKUP_CLAIMS = 8;
const MAX_HINTS_USED = 10_000;
const MAX_SEED_LENGTH = 128;
const MAX_DURATION_MS = 30 * 24 * 3600 * 1000;

export interface ClaimedPickup {
  /** Index into the puzzle's letter cells, sorted by row and then column. */
  readonly cell: number;
  readonly kind: HintKind;
}

/** One queue entry as the app writes it (app/lib/game/providers.dart). */
export interface SyncEntry {
  readonly stage: number;
  readonly puzzleId: string;
  readonly foundWords: readonly string[];
  readonly bonusWords: readonly string[];
  readonly hintsUsed: Readonly<HintCounts>;
  readonly pickups: readonly ClaimedPickup[];
  /** The id the pickups were seeded with; `null` means the account's own uid. */
  readonly pickupSeed: string | null;
  readonly durationMs: number;
  readonly completedAt: number;
}

export type RejectReason =
  | "invalid_entry"
  | "unknown_stage"
  | "puzzle_mismatch"
  | "duplicate"
  | "bad_completed_at"
  | "unknown_word"
  | "unknown_bonus_word"
  | "incomplete"
  | "too_fast";

export type ParsedEntry =
  | { readonly ok: true; readonly entry: SyncEntry }
  | { readonly ok: false; readonly stage: number | null; readonly detail: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isCount(value: unknown, max: number): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= max;
}

/** A list of at most `maxItems` strings, each short enough to be a word; `null` if it isn't one. */
export function stringList(value: unknown, maxItems: number): string[] | null {
  if (!Array.isArray(value) || value.length > maxItems) return null;
  if (!value.every((w) => typeof w === "string" && w.length <= MAX_WORD_LENGTH)) return null;
  return value as string[];
}

/**
 * `{hammer, chisel, sparks}` hint counts, each optional (0); missing or
 * `null` is no hints. Returns the name of the bad field if there is one.
 */
export function parseHintCounts(raw: unknown): { readonly ok: true; readonly hints: HintCounts } | { readonly ok: false; readonly detail: string } {
  const hints = noHints();
  if (raw === undefined || raw === null) return { ok: true, hints };
  if (!isRecord(raw)) return { ok: false, detail: "hintsUsed" };
  for (const kind of HINT_KINDS) {
    const n = raw[kind];
    if (n === undefined) continue;
    if (!isCount(n, MAX_HINTS_USED)) return { ok: false, detail: `hintsUsed.${kind}` };
    hints[kind] = n;
  }
  return { ok: true, hints };
}

const HINT_KIND_SET: ReadonlySet<string> = new Set(HINT_KINDS);

/** Checks the shape of one queue entry. Optional fields default to empty. */
export function parseSyncEntry(raw: unknown): ParsedEntry {
  if (!isRecord(raw)) return { ok: false, stage: null, detail: "entry is not an object" };
  const stage = isCount(raw.stage, MAX_STAGE) && raw.stage >= 1 ? raw.stage : null;
  const bad = (detail: string): ParsedEntry => ({ ok: false, stage, detail });
  if (stage === null) return bad("stage");
  if (typeof raw.puzzleId !== "string" || raw.puzzleId.length > 32) return bad("puzzleId");

  const foundWords = stringList(raw.foundWords, MAX_FOUND_WORDS);
  if (foundWords === null) return bad("foundWords");
  const bonusWords = raw.bonusWords === undefined ? [] : stringList(raw.bonusWords, MAX_BONUS_WORDS);
  if (bonusWords === null) return bad("bonusWords");

  const parsedHints = parseHintCounts(raw.hintsUsed);
  if (!parsedHints.ok) return bad(parsedHints.detail);
  const hintsUsed = parsedHints.hints;

  // The app writes `pickups`; docs/TECH.md §8 calls it `pickupsCollected`.
  const rawPickups = raw.pickups ?? raw.pickupsCollected ?? [];
  if (!Array.isArray(rawPickups) || rawPickups.length > MAX_PICKUP_CLAIMS) return bad("pickups");
  const pickups: ClaimedPickup[] = [];
  for (const p of rawPickups) {
    if (!isRecord(p) || !isCount(p.cell, 1000) || typeof p.kind !== "string" || !HINT_KIND_SET.has(p.kind)) {
      return bad("pickups");
    }
    pickups.push({ cell: p.cell, kind: p.kind as HintKind });
  }

  let pickupSeed: string | null = null;
  if (raw.pickupSeed !== undefined && raw.pickupSeed !== null) {
    if (typeof raw.pickupSeed !== "string" || raw.pickupSeed === "" || raw.pickupSeed.length > MAX_SEED_LENGTH) {
      return bad("pickupSeed");
    }
    pickupSeed = raw.pickupSeed;
  }

  if (!isCount(raw.durationMs, MAX_DURATION_MS)) return bad("durationMs");
  if (typeof raw.completedAt !== "number" || !Number.isSafeInteger(raw.completedAt)) return bad("completedAt");

  return {
    ok: true,
    entry: {
      stage,
      puzzleId: raw.puzzleId,
      foundWords,
      bonusWords,
      hintsUsed,
      pickups,
      pickupSeed,
      durationMs: raw.durationMs,
      completedAt: raw.completedAt,
    },
  };
}

/** Upper-cases and de-duplicates words; `null` if any isn't plain A–Z. */
function normalizedSet(words: readonly string[]): Set<string> | null {
  const out = new Set<string>();
  for (const raw of words) {
    const word = normalizeWord(raw);
    if (word === null) return null;
    out.add(word);
  }
  return out;
}

/**
 * Why `entry` can't be counted, or `null` if it can. `completed` holds the
 * stages already counted for this player.
 */
export function checkEntry(
  entry: SyncEntry,
  puzzle: CampaignPuzzle | undefined,
  completed: ReadonlySet<number>,
  now: number,
): RejectReason | null {
  if (puzzle === undefined) return "unknown_stage";
  if (entry.puzzleId !== puzzle.id) return "puzzle_mismatch";
  if (completed.has(entry.stage)) return "duplicate";
  if (entry.completedAt > now + MAX_COMPLETED_AT_SKEW_MS || entry.completedAt < EARLIEST_COMPLETED_AT) {
    return "bad_completed_at";
  }

  const found = normalizedSet(entry.foundWords);
  if (found === null || [...found].some((w) => !puzzle.gridWords.has(w))) return "unknown_word";
  const bonus = normalizedSet(entry.bonusWords);
  if (bonus === null || [...bonus].some((w) => !puzzle.bonus.has(w))) return "unknown_bonus_word";

  if (!couldBeFilled(puzzle, found, entry.hintsUsed)) return "incomplete";
  if (!isPlausibleDuration(entry.durationMs, found.size)) return "too_fast";
  return null;
}

/**
 * Whether typing `found` (grid words) and using these hints can have
 * filled every letter cell. A cell no typed word covers can only have been
 * shown by a hint (a slot that completes itself only does so once all its
 * cells are already showing), so the hints used must account for all of them.
 */
export function couldBeFilled(puzzle: CampaignPuzzle, found: ReadonlySet<string>, used: Readonly<HintCounts>): boolean {
  const covered = new Set<number>();
  for (const word of found) for (const cell of puzzle.wordCells.get(word) ?? []) covered.add(cell);
  const revealable = used.hammer + used.chisel + SPARK_SHOWER_LETTERS * used.sparks;
  return puzzle.cellCount - covered.size <= revealable;
}

/** At least {@link MIN_MS_PER_FOUND_WORD} for each word typed. */
export function isPlausibleDuration(durationMs: number, typedWords: number): boolean {
  return durationMs >= MIN_MS_PER_FOUND_WORD * typedWords;
}

/**
 * Takes the hints used in a puzzle off the stock. `gained` arrived during
 * it (pickups, Scrap Bin hammers), so it can pay for them; `rewards`
 * (level-ups) only come at the end. Stock never goes below zero: an
 * overdraw is reported as `clamped`.
 */
export function spendHints(
  stock: Readonly<HintCounts>,
  gained: Readonly<HintCounts>,
  used: Readonly<HintCounts>,
  rewards: Readonly<HintCounts>,
): { readonly hints: HintCounts; readonly clamped: HintCounts | null } {
  const hints = noHints();
  const clamped = noHints();
  let anyClamped = false;
  for (const kind of HINT_KINDS) {
    const available = stock[kind] + gained[kind];
    if (used[kind] > available) {
      clamped[kind] = used[kind] - available;
      anyClamped = true;
    }
    hints[kind] = Math.max(available - used[kind], 0) + rewards[kind];
  }
  return { hints, clamped: anyClamped ? clamped : null };
}

export interface PickupCheck {
  readonly granted: readonly ClaimedPickup[];
  readonly rejected: number;
  /** An install id to remember for this account, if this entry used a new one. */
  readonly newSeed: string | null;
}

/**
 * Which claimed pickups the server can reproduce with
 * `pickupsFor(seed, puzzleId, cellCount, levelAtStart)`. A claim on the
 * right cell gets the server's type (the level decides whether a Chisel or
 * Spark Shower is downgraded to a Hammer Strike, and the server's level wins).
 */
export function checkPickups(
  uid: string,
  entry: SyncEntry,
  puzzle: CampaignPuzzle,
  levelAtStart: number,
  knownSeeds: ReadonlySet<string>,
): PickupCheck {
  const none: PickupCheck = { granted: [], rejected: entry.pickups.length, newSeed: null };
  if (entry.pickups.length === 0) return { granted: [], rejected: 0, newSeed: null };

  const seed = entry.pickupSeed ?? uid;
  let newSeed: string | null = null;
  if (seed !== uid) {
    if (!INSTALL_SEED_PATTERN.test(seed)) return none;
    if (!knownSeeds.has(seed)) {
      if (knownSeeds.size >= MAX_INSTALL_SEEDS) return none;
      newSeed = seed;
    }
  }

  const expected = pickupsFor(seed, puzzle.id, puzzle.cellCount, levelAtStart);
  const claimed = new Set<number>();
  const granted: ClaimedPickup[] = [];
  let rejected = 0;
  for (const claim of entry.pickups) {
    const match = claimed.has(claim.cell) ? undefined : expected.find((p) => p.index === claim.cell);
    claimed.add(claim.cell);
    if (match === undefined) rejected++;
    else granted.push({ cell: match.index, kind: match.kind });
  }
  return { granted, rejected, newSeed: granted.length > 0 ? newSeed : null };
}

/** A player's solo-relevant numbers, before or after a sync. */
export interface SoloState {
  readonly totalXp: number;
  readonly scrapBin: number;
  readonly hints: Readonly<HintCounts>;
  /** Highest campaign stage completed (0 = none). */
  readonly campaignCompleted: number;
  readonly wordsForged: number;
  readonly longestWord: string;
  readonly soloDone: number;
  /** Stages already counted (at least every stage named in the batch). */
  readonly completedStages: ReadonlySet<number>;
  /** Install ids this account already uses as pickup seeds. */
  readonly installSeeds: ReadonlySet<string>;
}

interface ResultBase {
  /** The entry's stage, or `null` if it didn't have a usable one. */
  readonly stage: number | null;
  readonly xp: number;
  readonly levelUps: number;
  /** Level-up hint rewards. */
  readonly rewards: Readonly<HintCounts>;
}

export interface AcceptedResult extends ResultBase {
  readonly accepted: true;
  /** Smith Level after this entry. */
  readonly level: number;
  /** Hammer Strikes smelted from the Scrap Bin by this entry's bonus words. */
  readonly scrapHammers: number;
  /** Pickups granted, with the server's types. */
  readonly pickups: readonly ClaimedPickup[];
  /** Claimed pickups the server couldn't reproduce (not granted). */
  readonly pickupsRejected: number;
  /** Hints used beyond the stock the server knew of; only present if any. */
  readonly hintsClamped?: Readonly<HintCounts>;
}

export interface RejectedResult extends ResultBase {
  readonly accepted: false;
  readonly reason: RejectReason;
  /** For `invalid_entry`: which field was wrong. */
  readonly detail?: string;
}

export type EntryResult = AcceptedResult | RejectedResult;

/** What to write for an accepted entry. */
export interface AcceptedEntry {
  readonly stage: number;
  readonly puzzleId: string;
  readonly completedAt: number;
  readonly xp: number;
}

export interface SyncOutcome {
  /** One per input entry, in input order. */
  readonly results: readonly EntryResult[];
  /** Accepted entries in the order they were applied. */
  readonly accepted: readonly AcceptedEntry[];
  readonly state: SoloState;
  readonly newInstallSeeds: readonly string[];
}

export interface SyncInput {
  readonly uid: string;
  readonly now: number;
  readonly state: SoloState;
  readonly entries: readonly unknown[];
  readonly puzzles: ReadonlyMap<number, CampaignPuzzle>;
}

function rejected(stage: number | null, reason: RejectReason, detail?: string): RejectedResult {
  const base = { stage, accepted: false as const, reason, xp: 0, levelUps: 0, rewards: noHints() };
  return detail === undefined ? base : { ...base, detail };
}

/** Checks and applies a batch of queue entries. See the module comment for the rules. */
export function evaluateSync(input: SyncInput): SyncOutcome {
  const { uid, now, state, entries, puzzles } = input;
  const results: EntryResult[] = new Array<EntryResult>(entries.length);

  const valid: { index: number; entry: SyncEntry }[] = [];
  entries.forEach((raw, index) => {
    const parsed = parseSyncEntry(raw);
    if (parsed.ok) valid.push({ index, entry: parsed.entry });
    else results[index] = rejected(parsed.stage, "invalid_entry", parsed.detail);
  });
  valid.sort(
    (a, b) => a.entry.completedAt - b.entry.completedAt || a.entry.stage - b.entry.stage || a.index - b.index,
  );

  let { totalXp, scrapBin, campaignCompleted, wordsForged, longestWord, soloDone } = state;
  let hints: HintCounts = { ...state.hints };
  const completed = new Set(state.completedStages);
  const seeds = new Set(state.installSeeds);
  const newInstallSeeds: string[] = [];
  const accepted: AcceptedEntry[] = [];

  for (const { index, entry } of valid) {
    const puzzle = puzzles.get(entry.stage);
    const reason = checkEntry(entry, puzzle, completed, now);
    if (reason !== null || puzzle === undefined) {
      results[index] = rejected(entry.stage, reason ?? "unknown_stage");
      continue;
    }

    const found = normalizedSet(entry.foundWords)!;
    const bonusCount = normalizedSet(entry.bonusWords)!.size;
    const levelAtStart = levelFromTotalXp(totalXp);

    const xp = soloPuzzleXp(bonusCount);
    const award = applyXp(totalXp, xp);
    const scrap = addToScrapBin(scrapBin, bonusCount);
    const pickups = checkPickups(uid, entry, puzzle, levelAtStart, seeds);
    if (pickups.newSeed !== null) {
      seeds.add(pickups.newSeed);
      newInstallSeeds.push(pickups.newSeed);
    }

    // Pickups and Scrap Bin hammers arrive mid-puzzle, so they can pay for
    // hints used in it; level-up rewards only come at the end.
    const gained = noHints();
    gained.hammer += scrap.hammers;
    for (const p of pickups.granted) gained[p.kind] += 1;
    const spent = spendHints(hints, gained, entry.hintsUsed, award.rewards);
    hints = spent.hints;

    totalXp = award.totalXp;
    scrapBin = scrap.bin;
    campaignCompleted = Math.max(campaignCompleted, entry.stage);
    wordsForged += found.size;
    for (const word of found) if (word.length > longestWord.length) longestWord = word;
    soloDone += 1;
    completed.add(entry.stage);
    accepted.push({ stage: entry.stage, puzzleId: puzzle.id, completedAt: entry.completedAt, xp });

    const result: AcceptedResult = {
      stage: entry.stage,
      accepted: true,
      xp,
      levelUps: award.levelsGained,
      level: award.level,
      rewards: award.rewards,
      scrapHammers: scrap.hammers,
      pickups: pickups.granted,
      pickupsRejected: pickups.rejected,
    };
    results[index] = spent.clamped !== null ? { ...result, hintsClamped: spent.clamped } : result;
  }

  return {
    results,
    accepted,
    state: {
      totalXp,
      scrapBin,
      hints,
      campaignCompleted,
      wordsForged,
      longestWord,
      soloDone,
      completedStages: completed,
      installSeeds: seeds,
    },
    newInstallSeeds,
  };
}
