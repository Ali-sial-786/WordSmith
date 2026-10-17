/**
 * One Versus ("Anvil Clash") round and the series around it, as the referee
 * keeps them (shared/room-protocol.md "Versus (M4)", docs/DESIGN.md §9).
 * Pure: the RoomDO stores a {@link VsRound} and a {@link VsSeries} in its
 * own storage, calls these to change them, and sends what they return. The
 * decisions themselves (round winner, clinch, sudden death, podium) are in
 * vs.ts.
 *
 * - Everyone races the same puzzle and anvil, each on their **own mold**: a
 *   forged word fills only that racer's mold, and crossing slots it
 *   completes there fill in too.
 * - Progress is letter cells filled. Every change takes the next value of a
 *   per-round counter as its `reachedAt`, so "who got there first" never ties.
 * - **Embers** sit on the same cells for everyone. Each racer who forges a
 *   word through one collects it once; the hints are granted after the series.
 * - **Bonus words** count for nothing in the round, but go to the Scrap Bin.
 * - A racer who leaves or runs out of rejoin time is **out**: they keep
 *   their wins (and the podium shows them) but can't win any more rounds,
 *   and the series is decided among the racers still in it.
 *
 * Functions named `apply…`, `record…` and `mark…` change what they're given in place.
 */

import { decideClaim } from "./coop";
import { roundStartFields, type RoundStartFields, type SlotWord } from "./coop-round";
import { vsRoundTimerMs, type HeatTier } from "./heat";
import { cellKey, indexMold, newlyComplete, placeEmbers, shuffleLetters, type CellKey, type MoldIndex, type MpPuzzle, type Pos, type Rand } from "./mold";
import { addToScrapBin, applyXp, HINT_KINDS, noHints, vsSeriesXp, type HintCounts, type HintKind, type ScrapBinResult, type XpAward } from "./progression";
import { podium, resolveVsRound, seriesStatus, type SeriesLength, type VsRoundHow, type VsRoundResult } from "./vs";

/** Series length until the host picks one (CONFIG). */
export const DEFAULT_SERIES: SeriesLength = 3;
/** How long the standings show between rounds before the next countdown starts by itself. */
export const STANDINGS_MS = 10_000;

// ---------------------------------------------------------------------------
// A round
// ---------------------------------------------------------------------------

/** An ember a racer collected, as the hint it became. */
export interface VsPickup extends Pos {
  readonly kind: HintKind;
}

/** One racer's own copy of the mold. */
export interface VsMold {
  /** Words this racer forged, in order. */
  claims: SlotWord[];
  /** Crossing slots that filled in by themselves on this mold. */
  auto: SlotWord[];
  /** Bonus words found this round (Scrap Bin). */
  bonus: string[];
  pickups: VsPickup[];
  /** Letter cells filled. */
  filled: number;
  /** The round's counter when `filled` was reached (0 while empty). */
  reachedAt: number;
}

/** Everything about a Versus round. Plain JSON, so it goes straight into storage. */
export interface VsRound {
  /** 1, 2, … within the series, sudden death included. */
  readonly round: number;
  /** 1…series for a regular round, `null` for sudden death. */
  readonly regular: number | null;
  readonly heat: HeatTier;
  readonly puzzle: MpPuzzle;
  /** The anvil as sent, shuffled once for everyone. */
  readonly letters: string;
  readonly startsAt: number;
  readonly endsAt: number;
  /** Letter cells in the mold. */
  readonly total: number;
  /** Racing this round (just the tied leaders in sudden death); everyone else watches. */
  readonly playerIds: readonly string[];
  /** Ember cells, the same for everyone; they stay for racers who haven't collected them. */
  readonly embers: readonly Pos[];
  readonly molds: Record<string, VsMold>;
  /** The last value handed out as a `reachedAt`. */
  n: number;
}

export interface NewVsRoundInput {
  readonly round: number;
  readonly suddenDeath: boolean;
  readonly heat: HeatTier;
  readonly puzzle: MpPuzzle;
  readonly playerIds: readonly string[];
  readonly startsAt: number;
  readonly rand: Rand;
}

function emptyMold(): VsMold {
  return { claims: [], auto: [], bonus: [], pickups: [], filled: 0, reachedAt: 0 };
}

/** Sets up a round: one shuffled anvil and one set of embers for everyone, and the VS clock from `startsAt`. */
export function newVsRound(input: NewVsRoundInput): VsRound {
  const { puzzle, rand } = input;
  const index = indexMold(puzzle);
  const fullLength = new Set(puzzle.slots.filter((s) => s.len === puzzle.letters.length).map((s) => s.word));
  return {
    round: input.round,
    regular: input.suddenDeath ? null : input.round,
    heat: input.heat,
    puzzle,
    letters: shuffleLetters(puzzle.letters, rand, fullLength),
    startsAt: input.startsAt,
    endsAt: input.startsAt + vsRoundTimerMs(input.heat),
    total: index.cells.size,
    playerIds: [...input.playerIds],
    embers: placeEmbers(index, rand),
    molds: Object.fromEntries(input.playerIds.map((id) => [id, emptyMold()])),
    n: 0,
  };
}

function moldCells(mold: VsMold, index: MoldIndex): Set<CellKey> {
  const filled = new Set<CellKey>();
  for (const s of [...mold.claims, ...mold.auto]) for (const k of index.slotKeys[s.slot]!) filled.add(k);
  return filled;
}

export type VsSubmitOutcome =
  | { readonly result: "invalid" }
  /** The racer already has this word (forged it, it filled in by itself, or found it as a bonus word). */
  | { readonly result: "already"; readonly word: string }
  | { readonly result: "bonus"; readonly word: string }
  | {
      readonly result: "claimed";
      readonly word: string;
      readonly slot: number;
      /** Crossing slots this completed on the racer's own mold. */
      readonly auto: readonly SlotWord[];
      /** An ember on this word's cells that the racer hadn't collected yet. */
      readonly ember: Pos | null;
      readonly filled: number;
      readonly total: number;
      /** Every letter of the racer's mold is filled: they win the round. */
      readonly complete: boolean;
    };

/**
 * Referees one word from `by` against their own mold. `by` must be racing
 * this round (the caller checks); anyone else's word is `invalid`.
 */
export function applyVsSubmit(r: VsRound, by: string, raw: string): VsSubmitOutcome {
  const mold = r.molds[by];
  if (mold === undefined) return { result: "invalid" };
  const index = indexMold(r.puzzle);
  const found = new Map<string, string | null>();
  for (const c of mold.claims) found.set(c.word, by);
  for (const a of mold.auto) found.set(a.word, null);
  for (const w of mold.bonus) found.set(w, by);
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
      return { result: "already", word: decision.word };
    case "bonus":
      mold.bonus.push(decision.word);
      return { result: "bonus", word: decision.word };
    case "claimed": {
      const slot = index.slotByWord.get(decision.word)!;
      mold.claims.push({ slot: slot.slot, word: slot.word });
      const filled = moldCells(mold, index);
      const done = new Set([...mold.claims, ...mold.auto].map((s) => s.slot));
      const auto = newlyComplete(index, filled, done).map((s) => ({ slot: s.slot, word: s.word }));
      mold.auto.push(...auto);
      if (filled.size > mold.filled) {
        mold.filled = filled.size;
        mold.reachedAt = ++r.n;
      }
      // Two embers never share a slot, so one word collects at most one.
      const mine = new Set(index.slotKeys[slot.slot]);
      const ember = r.embers.find((e) => mine.has(cellKey(e.x, e.y)) && !mold.pickups.some((p) => p.x === e.x && p.y === e.y));
      return {
        result: "claimed",
        word: slot.word,
        slot: slot.slot,
        auto,
        ember: ember === undefined ? null : { x: ember.x, y: ember.y },
        filled: mold.filled,
        total: r.total,
        complete: mold.filled >= r.total,
      };
    }
  }
}

/** Notes that `by` collected the ember at `ember` as a `kind` hint (granted after the series). */
export function applyVsPickup(r: VsRound, by: string, ember: Pos, kind: HintKind): void {
  r.molds[by]?.pickups.push({ x: ember.x, y: ember.y, kind });
}

export interface VsProgress {
  readonly id: string;
  readonly filled: number;
  readonly total: number;
}

/** Every racer's progress (counts only, never words or cells). */
export function progressOf(r: VsRound): VsProgress[] {
  return r.playerIds.map((id) => ({ id, filled: r.molds[id]?.filled ?? 0, total: r.total }));
}

/** Who wins the round if it ends now, among `contenders` (the racers still in the series). */
export function resolveRound(r: VsRound, contenders: readonly string[]): VsRoundResult {
  return resolveVsRound(
    r.total,
    r.playerIds
      .filter((id) => contenders.includes(id))
      .map((id) => ({ playerId: id, lettersFilled: r.molds[id]?.filled ?? 0, reachedAt: r.molds[id]?.reachedAt ?? 0 })),
  );
}

// ---------------------------------------------------------------------------
// The series
// ---------------------------------------------------------------------------

/** One player in the series and what they've done so far. */
export interface VsRacer {
  readonly id: string;
  /** Rounds won, sudden death included. */
  wins: number;
  /** Rounds raced (not watched). */
  rounds: number;
  /** Grid words forged. */
  words: number;
  longest: string;
  /** Bonus words found (Scrap Bin). */
  bonus: number;
  /** Embers collected, by the hint they became. */
  pickups: HintCounts;
  /** Left, or ran out of rejoin time: keeps their wins but can't win any more rounds. */
  out: boolean;
}

export interface VsSeries {
  /** The `matches` row this series becomes. */
  readonly matchId: string;
  readonly length: SeriesLength;
  /** Set at the start from the median level; every round uses it. */
  readonly heat: HeatTier;
  /** When the first round's play began. */
  readonly startedAt: number;
  /** Everyone seated at the start, in join order. */
  readonly racers: VsRacer[];
  /** Rounds played so far, sudden death included. */
  played: number;
  /** While the standings show: when the next countdown starts. */
  standingsEndsAt: number | null;
  /**
   * Grid words each racer forged on their own molds, for their Work Orders
   * (shared/forge-board.md). Absent in series stored before them, and
   * until the first round is recorded.
   */
  forged?: Record<string, string[]>;
}

export interface NewVsSeriesInput {
  readonly matchId: string;
  readonly length: SeriesLength;
  readonly heat: HeatTier;
  readonly racerIds: readonly string[];
  readonly startedAt: number;
}

export function newVsSeries(input: NewVsSeriesInput): VsSeries {
  return {
    matchId: input.matchId,
    length: input.length,
    heat: input.heat,
    startedAt: input.startedAt,
    racers: input.racerIds.map((id) => ({ id, wins: 0, rounds: 0, words: 0, longest: "", bonus: 0, pickups: noHints(), out: false })),
    played: 0,
    standingsEndsAt: null,
  };
}

/** Wins so far for everyone in the series, out or not. */
export function tallyOf(s: VsSeries): Record<string, number> {
  return Object.fromEntries(s.racers.map((r) => [r.id, r.wins]));
}

/** Racers still in the series, in join order. */
export function activeRacers(s: VsSeries): string[] {
  return s.racers.filter((r) => !r.out).map((r) => r.id);
}

/** Whether `id` may race in this series: one of its racers, and not out. */
export function canRace(s: VsSeries, id: string): boolean {
  return s.racers.some((r) => r.id === id && !r.out);
}

/** Takes `id` out of the series. False if they weren't in it (or were already out). */
export function markOut(s: VsSeries, id: string): boolean {
  const racer = s.racers.find((r) => r.id === id);
  if (racer === undefined || racer.out) return false;
  racer.out = true;
  return true;
}

/** Adds a finished round to the series: the winner's win, and each racer's rounds, words (and which), bonus words and embers. */
export function recordRound(s: VsSeries, r: VsRound, result: VsRoundResult): void {
  s.played += 1;
  const forged = (s.forged ??= {});
  for (const id of r.playerIds) {
    const racer = s.racers.find((x) => x.id === id);
    const mold = r.molds[id];
    if (racer === undefined || mold === undefined) continue;
    racer.rounds += 1;
    racer.words += mold.claims.length;
    (forged[id] ??= []).push(...mold.claims.map((c) => c.word));
    for (const c of mold.claims) if (c.word.length > racer.longest.length) racer.longest = c.word;
    racer.bonus += mold.bonus.length;
    for (const p of mold.pickups) racer.pickups[p.kind] += 1;
  }
  const winner = s.racers.find((x) => x.id === result.winner);
  if (winner !== undefined) winner.wins += 1;
}

/** The round after the standings. */
export interface VsNextRound {
  readonly round: number;
  readonly suddenDeath: boolean;
  /** Racing in it: everyone still in the series, or just the tied leaders in sudden death. */
  readonly players: readonly string[];
}

export interface VsSeriesOutcome {
  readonly winner: string | null;
  /** Clinched before the last regular round. */
  readonly early: boolean;
  /** Won because every other contender left. */
  readonly forfeit: boolean;
}

export type VsSeriesDecision = { readonly over: false; readonly next: VsNextRound } | ({ readonly over: true } & VsSeriesOutcome);

/**
 * Where the series stands, judged among the racers still in it (out
 * racers' wins stay on the podium but don't hold anyone back):
 *
 * - one racer left (or none): over, by forfeit;
 * - clinched, or a clear leader after the last regular round: over;
 * - otherwise the next round: a regular one, or sudden death between the
 *   tied leaders (again with the same players if one had no winner).
 */
export function seriesDecision(s: VsSeries): VsSeriesDecision {
  const active = activeRacers(s);
  if (active.length <= 1) return { over: true, winner: active[0] ?? null, early: false, forfeit: true };
  const standings = s.racers.filter((r) => !r.out).map((r) => ({ playerId: r.id, wins: r.wins }));
  const status = seriesStatus(standings, s.length, s.played);
  if (status.state === "won") return { over: true, winner: status.winner, early: status.early, forfeit: false };
  const round = s.played + 1;
  if (status.state === "playing") return { over: false, next: { round, suddenDeath: false, players: active } };
  return { over: false, next: { round, suddenDeath: true, players: [...status.players] } };
}

/**
 * How a series ends when it has to stop now (the room is closing): as
 * decided if it is, otherwise with no winner.
 */
export function stopSeries(s: VsSeries): VsSeriesOutcome {
  const d = seriesDecision(s);
  return d.over ? { winner: d.winner, early: d.early, forfeit: d.forfeit } : { winner: null, early: false, forfeit: false };
}

// ---------------------------------------------------------------------------
// What clients see
// ---------------------------------------------------------------------------

/** `ROUND_START` in Versus: the co-op fields plus the series. */
export interface VsRoundStartFields extends RoundStartFields {
  readonly series: SeriesLength;
  readonly regular: number | null;
  readonly suddenDeath: boolean;
  readonly players: readonly string[];
  /** Wins before this round. */
  readonly tally: Readonly<Record<string, number>>;
}

export function vsRoundStartFields(r: VsRound, s: VsSeries, serverNow: number): VsRoundStartFields {
  return {
    ...roundStartFields(r, serverNow),
    series: s.length,
    regular: r.regular,
    suddenDeath: r.regular === null,
    players: [...r.playerIds],
    tally: tallyOf(s),
  };
}

/** The receiver's own mold, in a `SNAPSHOT`. */
export interface VsMine {
  readonly claims: readonly SlotWord[];
  readonly auto: readonly SlotWord[];
}

export function mineOf(r: VsRound, id: string): VsMine {
  const mold = r.molds[id];
  return {
    claims: mold?.claims.map(({ slot, word }) => ({ slot, word })) ?? [],
    auto: mold?.auto.map(({ slot, word }) => ({ slot, word })) ?? [],
  };
}

/** The `round` part of a Versus `SNAPSHOT`: `mine` is empty for someone watching. */
export interface VsRoundSnapshot extends VsRoundStartFields {
  readonly mine: VsMine;
  readonly progress: readonly VsProgress[];
}

export function vsRoundSnapshot(r: VsRound, s: VsSeries, receiver: string, serverNow: number): VsRoundSnapshot {
  return { ...vsRoundStartFields(r, s, serverNow), mine: mineOf(r, receiver), progress: progressOf(r) };
}

export type VsRoundEndReason = "finished" | "timeout";

/** `ROUND_END` in Versus. */
export interface VsRoundEndFields {
  /** Not in the contract: the round that ended. */
  readonly round: number;
  readonly reason: VsRoundEndReason;
  readonly winner: string | null;
  readonly how: VsRoundHow;
  readonly progress: readonly VsProgress[];
  /** Wins after this round, for everyone in the series. */
  readonly tally: Readonly<Record<string, number>>;
  readonly answers: readonly SlotWord[];
  readonly next: VsNextRound | null;
  readonly standingsEndsAt: number | null;
}

export interface VsRoundEnd {
  readonly fields: VsRoundEndFields;
  /** The series is over (decided, or stopped): `null` while it goes on to `fields.next`. */
  readonly outcome: VsSeriesOutcome | null;
}

/**
 * Ends the round now: resolves it among the racers still in the series,
 * adds it to the series, and decides what comes next. With `stop` the
 * series ends here whatever the tally (the room is closing). The standings
 * would run until `now + STANDINGS_MS`.
 */
export function endVsRound(s: VsSeries, r: VsRound, reason: VsRoundEndReason, now: number, stop = false): VsRoundEnd {
  const result = resolveRound(r, activeRacers(s));
  recordRound(s, r, result);
  const decision = seriesDecision(s);
  const outcome = decision.over ? { winner: decision.winner, early: decision.early, forfeit: decision.forfeit } : stop ? stopSeries(s) : null;
  return {
    fields: {
      round: r.round,
      reason,
      winner: result.winner,
      how: result.how,
      progress: progressOf(r),
      tally: tallyOf(s),
      answers: r.puzzle.slots.map(({ slot, word }) => ({ slot, word })),
      next: outcome === null && !decision.over ? decision.next : null,
      standingsEndsAt: outcome === null ? now + STANDINGS_MS : null,
    },
    outcome,
  };
}

// ---------------------------------------------------------------------------
// Results and XP (DESIGN.md §4.2, §3.2)
// ---------------------------------------------------------------------------

export interface VsPlayerResult {
  readonly id: string;
  readonly wins: number;
  /** Podium place: 1-based, equal wins share a place. */
  readonly place: number;
  readonly rounds: number;
  readonly words: number;
  readonly longest: string;
  readonly bonus: number;
  readonly pickups: HintCounts;
}

export interface VsSeriesResults extends VsSeriesOutcome {
  /** Rounds played, sudden death included. */
  readonly rounds: number;
  /** Everyone in the series, out or not, in podium order. */
  readonly players: readonly VsPlayerResult[];
}

/**
 * The finished series: the podium by round wins (equal wins share a place,
 * and the winner comes first among them), and each racer's totals.
 */
export function vsSeriesResults(s: VsSeries, outcome: VsSeriesOutcome): VsSeriesResults {
  const ordered = [...s.racers].sort((a, b) => Number(b.id === outcome.winner) - Number(a.id === outcome.winner));
  const places = podium(ordered.map((r) => ({ playerId: r.id, wins: r.wins })));
  return {
    ...outcome,
    rounds: s.played,
    players: places.map((p) => {
      const r = s.racers.find((x) => x.id === p.playerId)!;
      return { id: r.id, wins: r.wins, place: p.place, rounds: r.rounds, words: r.words, longest: r.longest, bonus: r.bonus, pickups: { ...r.pickups } };
    }),
  };
}

export interface VsAward {
  readonly amount: number;
  readonly xp: XpAward;
  readonly scrap: ScrapBinResult;
  /** Every hint to add: level-up rewards, Scrap Bin hammers and embers. */
  readonly gained: HintCounts;
}

/**
 * What one player gets for the series: VS XP (5 per round raced, 10 per
 * round won, 30 for the series) with any level-ups and their rewards, the
 * series' bonus words smelted in the Scrap Bin, and the embers collected.
 */
export function vsAward(player: VsPlayerResult, winner: string | null, profile: { readonly totalXp: number; readonly scrapBin: number }): VsAward {
  const amount = vsSeriesXp({ roundsPlayed: player.rounds, roundsWon: player.wins, wonSeries: winner === player.id });
  const xp = applyXp(profile.totalXp, amount);
  const scrap = addToScrapBin(profile.scrapBin, player.bonus);
  const gained = noHints();
  for (const kind of HINT_KINDS) gained[kind] = xp.rewards[kind] + player.pickups[kind];
  gained.hammer += scrap.hammers;
  return { amount, xp, scrap, gained };
}

