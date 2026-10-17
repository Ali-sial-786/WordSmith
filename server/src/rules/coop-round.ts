/**
 * One co-op round as the referee keeps it (shared/room-protocol.md,
 * docs/DESIGN.md §8): who forged what, hinted letters, embers, scores and
 * the results. Pure: the RoomDO stores a {@link CoopRound} in its own
 * storage, calls these to change it, and sends what they return.
 *
 * Functions named `apply…` change the round they're given in place.
 */

import {
  bonusWordPoints,
  coopStars,
  decideClaim,
  gridWordPoints,
  pickMvp,
  standingsFromClaims,
  type ScoredClaim,
  type Stars,
} from "./coop";
import { coopTimerMs, type HeatTier } from "./heat";
import {
  cellKey,
  hammerCell,
  indexMold,
  newlyComplete,
  placeEmbers,
  shuffleLetters,
  sparkCells,
  type Cell,
  type CellKey,
  type MoldIndex,
  type MpPuzzle,
  type Pos,
  type Rand,
} from "./mold";
import { addToScrapBin, applyXp, coopRoundXp, type HintKind, type ScrapBinResult, type XpAward } from "./progression";

export interface ClaimRecord {
  readonly slot: number;
  readonly word: string;
  readonly by: string;
  readonly points: number;
  /** Arrival order across claims and bonus words (for the MVP tie-break). */
  readonly n: number;
}

export interface SlotWord {
  readonly slot: number;
  readonly word: string;
}

export interface BonusRecord {
  readonly word: string;
  readonly by: string;
  readonly points: number;
  readonly n: number;
}

export interface RevealedCell {
  readonly x: number;
  readonly y: number;
  readonly letter: string;
}

export interface EmberRecord extends Pos {
  readonly by: string;
  readonly kind: HintKind;
}

export interface HintRecord {
  readonly by: string;
  readonly kind: HintKind;
}

/** Everything about a round in progress. Plain JSON, so it goes straight into storage. */
export interface CoopRound {
  readonly round: number;
  readonly heat: HeatTier;
  /** The `matches` row this round becomes. */
  readonly matchId: string;
  readonly puzzle: MpPuzzle;
  /** The anvil as sent, shuffled once for the round. */
  readonly letters: string;
  readonly startsAt: number;
  readonly endsAt: number;
  /** Everyone who takes part: the room's players at the start. */
  readonly playerIds: readonly string[];
  claims: ClaimRecord[];
  auto: SlotWord[];
  bonus: BonusRecord[];
  revealed: RevealedCell[];
  /** Ember cells still waiting on the mold. */
  embers: Pos[];
  collected: EmberRecord[];
  hints: HintRecord[];
  /** Next arrival number. */
  n: number;
}

export interface NewRoundInput {
  readonly round: number;
  readonly heat: HeatTier;
  readonly matchId: string;
  readonly puzzle: MpPuzzle;
  readonly playerIds: readonly string[];
  readonly startsAt: number;
  readonly rand: Rand;
}

/** Sets up a round: shuffles the anvil, places any embers, starts the clock at `startsAt`. */
export function newCoopRound(input: NewRoundInput): CoopRound {
  const { puzzle, rand } = input;
  const index = indexMold(puzzle);
  const fullLength = new Set(puzzle.slots.filter((s) => s.len === puzzle.letters.length).map((s) => s.word));
  return {
    round: input.round,
    heat: input.heat,
    matchId: input.matchId,
    puzzle,
    letters: shuffleLetters(puzzle.letters, rand, fullLength),
    startsAt: input.startsAt,
    endsAt: input.startsAt + coopTimerMs(input.heat),
    playerIds: [...input.playerIds],
    claims: [],
    auto: [],
    bonus: [],
    revealed: [],
    embers: placeEmbers(index, rand),
    collected: [],
    hints: [],
    n: 0,
  };
}

export function roundLengthMs(r: CoopRound): number {
  return r.endsAt - r.startsAt;
}

// ---------------------------------------------------------------------------
// What clients see
// ---------------------------------------------------------------------------

/** `ROUND_START` fields. Slot shapes only: never the words. */
export interface RoundStartFields {
  readonly round: number;
  readonly heat: HeatTier;
  readonly startsAt: number;
  readonly endsAt: number;
  readonly serverNow: number;
  readonly letters: string;
  readonly cols: number;
  readonly rows: number;
  readonly slots: readonly { slot: number; x: number; y: number; d: "a" | "d"; len: number }[];
  readonly pickups: readonly Pos[];
}

/** What `ROUND_START` is built from: any mode's round (co-op's {@link CoopRound}, or a Versus round). */
export interface RoundBoard {
  readonly round: number;
  readonly heat: HeatTier;
  readonly puzzle: MpPuzzle;
  readonly letters: string;
  readonly startsAt: number;
  readonly endsAt: number;
  /** Ember cells still showing. */
  readonly embers: readonly Pos[];
}

export function roundStartFields(r: RoundBoard, serverNow: number): RoundStartFields {
  return {
    round: r.round,
    heat: r.heat,
    startsAt: r.startsAt,
    endsAt: r.endsAt,
    serverNow,
    letters: r.letters,
    cols: r.puzzle.cols,
    rows: r.puzzle.rows,
    slots: r.puzzle.slots.map(({ slot, x, y, d, len }) => ({ slot, x, y, d, len })),
    pickups: r.embers.map(({ x, y }) => ({ x, y })),
  };
}

/** The `round` part of a `SNAPSHOT`: the round so far. */
export interface RoundSnapshot extends RoundStartFields {
  readonly claims: readonly { slot: number; word: string; by: string; points: number }[];
  readonly auto: readonly SlotWord[];
  readonly bonus: readonly { word: string; by: string }[];
  readonly revealed: readonly RevealedCell[];
  readonly scores: Record<string, number>;
}

export function roundSnapshot(r: CoopRound, serverNow: number): RoundSnapshot {
  return {
    ...roundStartFields(r, serverNow),
    claims: r.claims.map(({ slot, word, by, points }) => ({ slot, word, by, points })),
    auto: r.auto.map(({ slot, word }) => ({ slot, word })),
    bonus: r.bonus.map(({ word, by }) => ({ word, by })),
    revealed: r.revealed.map(({ x, y, letter }) => ({ x, y, letter })),
    scores: scoresOf(r),
  };
}

/** Points so far for every player in the round (0 for those with none). */
export function scoresOf(r: CoopRound): Record<string, number> {
  const scores: Record<string, number> = {};
  for (const id of r.playerIds) scores[id] = 0;
  for (const c of r.claims) scores[c.by] = (scores[c.by] ?? 0) + c.points;
  for (const b of r.bonus) scores[b.by] = (scores[b.by] ?? 0) + b.points;
  return scores;
}

// ---------------------------------------------------------------------------
// The board
// ---------------------------------------------------------------------------

/** Letter cells showing now: every forged or self-completed slot, plus hinted letters. */
export function filledCells(r: CoopRound, index: MoldIndex = indexMold(r.puzzle)): Set<CellKey> {
  const filled = new Set<CellKey>();
  for (const s of [...r.claims, ...r.auto]) for (const k of index.slotKeys[s.slot]!) filled.add(k);
  for (const c of r.revealed) filled.add(cellKey(c.x, c.y));
  return filled;
}

function doneSlots(r: CoopRound): Set<number> {
  return new Set([...r.claims, ...r.auto].map((s) => s.slot));
}

/** Every slot forged or filled in by itself: the team has finished the mold. */
export function isComplete(r: CoopRound): boolean {
  return r.claims.length + r.auto.length >= r.puzzle.slots.length;
}

/** Marks every slot the filled cells now complete as filled in by itself (scoring nothing). */
function applyAuto(r: CoopRound, index: MoldIndex, filled: ReadonlySet<CellKey>): SlotWord[] {
  const auto = newlyComplete(index, filled, doneSlots(r)).map((s) => ({ slot: s.slot, word: s.word }));
  r.auto.push(...auto);
  return auto;
}

// ---------------------------------------------------------------------------
// SUBMIT
// ---------------------------------------------------------------------------

export type SubmitOutcome =
  | { readonly result: "invalid" }
  | { readonly result: "already"; readonly word: string; readonly by: string | null }
  | { readonly result: "bonus"; readonly word: string; readonly points: number }
  | {
      readonly result: "claimed";
      readonly word: string;
      readonly slot: number;
      readonly points: number;
      /** Crossing slots this claim completed: they fill in and score nothing. */
      readonly auto: readonly SlotWord[];
      /** The ember on this word's cells, if there was one: `by` collects it. */
      readonly ember: Pos | null;
      readonly complete: boolean;
    };

/**
 * Referees one word from `by`. Words are handled strictly in arrival order,
 * so the first sender of an unfound word gets it.
 *
 * A grid word earns 10 per letter a hint didn't reveal; a bonus word 3 per
 * letter, once per round. Embers on the word's cells go to its claimer;
 * an ember left on a slot that fills in by itself is lost.
 */
export function applySubmit(r: CoopRound, by: string, raw: string): SubmitOutcome {
  const index = indexMold(r.puzzle);
  const found = new Map<string, string | null>();
  for (const c of r.claims) found.set(c.word, c.by);
  for (const a of r.auto) found.set(a.word, null);
  for (const b of r.bonus) found.set(b.word, b.by);
  const decision = decideClaim(raw, {
    letters: r.puzzle.letters,
    answers: new Set(index.slotByWord.keys()),
    bonus: new Set(r.puzzle.bonus),
    found,
  });

  switch (decision.result) {
    case "invalid":
      return { result: "invalid" };
    case "already":
      return { result: "already", word: decision.word, by: decision.by };
    case "bonus": {
      const points = bonusWordPoints(decision.word.length);
      r.bonus.push({ word: decision.word, by, points, n: r.n++ });
      return { result: "bonus", word: decision.word, points };
    }
    case "claimed": {
      const slot = index.slotByWord.get(decision.word)!;
      const keys = index.slotKeys[slot.slot]!;
      const revealed = new Set(r.revealed.map((c) => cellKey(c.x, c.y)));
      const points = gridWordPoints(slot.len, keys.filter((k) => revealed.has(k)).length);
      r.claims.push({ slot: slot.slot, word: slot.word, by, points, n: r.n++ });

      const auto = applyAuto(r, index, filledCells(r, index));
      const mine = new Set(keys);
      const lost = new Set(auto.flatMap((a) => index.slotKeys[a.slot]!));
      const ember = r.embers.find((e) => mine.has(cellKey(e.x, e.y))) ?? null;
      r.embers = r.embers.filter((e) => e !== ember && !lost.has(cellKey(e.x, e.y)));
      return { result: "claimed", word: slot.word, slot: slot.slot, points, auto, ember, complete: isComplete(r) };
    }
  }
}

/** Notes that `by` collected an ember as a `kind` hint. */
export function applyEmberCollected(r: CoopRound, ember: Pos, by: string, kind: HintKind): void {
  r.collected.push({ x: ember.x, y: ember.y, by, kind });
}

// ---------------------------------------------------------------------------
// HINT
// ---------------------------------------------------------------------------

export type HintTarget = { readonly kind: "hammer" | "sparks" } | { readonly kind: "chisel"; readonly x: number; readonly y: number };

/** Whether a hint can be used now, before spending it. A Chisel needs an empty letter cell. */
export function hintProblem(r: CoopRound, target: HintTarget): "bad_cell" | null {
  const index = indexMold(r.puzzle);
  const filled = filledCells(r, index);
  if (target.kind === "chisel") {
    const key = cellKey(target.x, target.y);
    return index.cells.has(key) && !filled.has(key) ? null : "bad_cell";
  }
  return filled.size < index.cells.size ? null : "bad_cell";
}

export type HintOutcome =
  | { readonly ok: false; readonly code: "bad_cell" }
  | {
      readonly ok: true;
      readonly cells: readonly RevealedCell[];
      /** Slots the revealed letters completed: they fill in and score nothing. */
      readonly auto: readonly SlotWord[];
      readonly complete: boolean;
    };

/**
 * Reveals letters for the whole team: a Hammer Strike shows one random
 * empty cell, a Chisel the chosen cell, a Spark Shower up to 5 cells spread
 * across slots. Hinted letters then score for nobody.
 */
export function applyHint(r: CoopRound, by: string, target: HintTarget, rand: Rand): HintOutcome {
  if (hintProblem(r, target) !== null) return { ok: false, code: "bad_cell" };
  const index = indexMold(r.puzzle);
  const filled = filledCells(r, index);
  let cells: Cell[];
  if (target.kind === "chisel") cells = [index.cells.get(cellKey(target.x, target.y))!];
  else if (target.kind === "hammer") cells = [hammerCell(index, filled, rand)!];
  else cells = sparkCells(index, filled, rand);

  const revealed = cells.map(({ x, y, letter }) => ({ x, y, letter }));
  r.revealed.push(...revealed);
  r.hints.push({ by, kind: target.kind });
  for (const c of cells) filled.add(c.key);
  const auto = applyAuto(r, index, filled);
  return { ok: true, cells: revealed, auto, complete: isComplete(r) };
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

export type RoundEndReason = "complete" | "timeout";

export interface CoopPlayerResult {
  readonly id: string;
  readonly points: number;
  /** Grid words this player forged. */
  readonly words: number;
  /** Their longest forged grid word, or "" if none. */
  readonly longest: string;
  /** Bonus words they found (they go into their Scrap Bin). */
  readonly bonus: number;
}

export interface CoopResults {
  readonly reason: RoundEndReason;
  readonly teamScore: number;
  /** Letter cells filled at the end, by words or hints. */
  readonly filled: number;
  readonly total: number;
  readonly stars: Stars;
  readonly players: readonly CoopPlayerResult[];
  readonly mvp: string | null;
  /** Every grid word, so the app can show the ones nobody found. */
  readonly answers: readonly SlotWord[];
}

/** The round's outcome when it ends at `now`, completed or timed out. */
export function coopResults(r: CoopRound, reason: RoundEndReason, now: number): CoopResults {
  const index = indexMold(r.puzzle);
  const scores = scoresOf(r);
  const events: (ScoredClaim & { n: number })[] = [
    ...r.claims.map((c) => ({ playerId: c.by, points: c.points, n: c.n })),
    ...r.bonus.map((b) => ({ playerId: b.by, points: b.points, n: b.n })),
  ].sort((a, b) => a.n - b.n);
  const mvp = pickMvp(standingsFromClaims(r.playerIds, events));

  const roundMs = roundLengthMs(r);
  const filled = filledCells(r, index).size;
  const total = index.cells.size;
  const timeLeftMs = reason === "complete" ? Math.min(roundMs, Math.max(0, r.endsAt - now)) : 0;
  const ids = [...r.playerIds];
  for (const id of Object.keys(scores)) if (!ids.includes(id)) ids.push(id);

  return {
    reason,
    teamScore: Object.values(scores).reduce((a, b) => a + b, 0),
    filled,
    total,
    stars: coopStars({ filledCells: filled, totalCells: total, timeLeftMs, roundMs }),
    players: ids.map((id) => {
      const mine = r.claims.filter((c) => c.by === id);
      let longest = "";
      for (const c of mine) if (c.word.length > longest.length) longest = c.word;
      return { id, points: scores[id] ?? 0, words: mine.length, longest, bonus: r.bonus.filter((b) => b.by === id).length };
    }),
    mvp,
    answers: r.puzzle.slots.map(({ slot, word }) => ({ slot, word })),
  };
}

/** The grid words each player forged (claimed), in order, for their Work Orders (shared/forge-board.md). */
export function forgedWords(r: CoopRound): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const id of r.playerIds) out[id] = [];
  for (const c of r.claims) (out[c.by] ??= []).push(c.word);
  return out;
}

// ---------------------------------------------------------------------------
// XP and the Scrap Bin (DESIGN.md §4.2, §3.2)
// ---------------------------------------------------------------------------

export interface CoopAward {
  readonly amount: number;
  readonly xp: XpAward;
  readonly scrap: ScrapBinResult;
}

/**
 * What one player gets for a round: co-op XP (with any level-ups and their
 * rewards), and their bonus words smelted in the Scrap Bin.
 */
export function coopAward(
  player: CoopPlayerResult,
  results: Pick<CoopResults, "reason" | "mvp">,
  profile: { readonly totalXp: number; readonly scrapBin: number },
): CoopAward {
  const amount = coopRoundXp({ points: player.points, teamFilledMold: results.reason === "complete", isMvp: results.mvp === player.id });
  return { amount, xp: applyXp(profile.totalXp, amount), scrap: addToScrapBin(profile.scrapBin, player.bonus) };
}
