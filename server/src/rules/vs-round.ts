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
 * - **Survival** (shared/survival.md): each racer has their own heated word
 *   on their own mold, all from the same order ({@link VsSurvival}). The
 *   first melt by anyone ends the round, and whoever melted can't win it.
 * - **Team Versus** (shared/room-protocol.md "Team Versus"): every racer
 *   is on a team ({@link VsTeams}), and a round is won by a team, under the
 *   room's rule (teams.ts). Wins are counted per team; each racer's own
 *   `wins` are the rounds their team won while they raced.
 *
 * Functions named `apply…`, `record…` and `mark…` change what they're given in place.
 */

import { decideClaim } from "./coop";
import { lenOf, roundStartFields, type RoundStartFields, type SlotWord } from "./coop-round";
import { vsRoundTimerMs, type HeatTier } from "./heat";
import { cellKey, indexMold, newlyComplete, placeEmbers, shuffleLetters, type CellKey, type MoldIndex, type MpPuzzle, type Pos, type Rand } from "./mold";
import {
  addToScrapBin,
  applyXp,
  heatXp,
  HINT_KINDS,
  levelFromTotalXp,
  noHints,
  vsSeriesXp,
  type HintCounts,
  type HintKind,
  type ScrapBinResult,
  type XpAward,
} from "./progression";
import {
  applyHeatProgress,
  firstClock,
  heatedFields,
  heatOrder,
  meltAt,
  SURVIVAL_CAP_MS,
  type HeatClock,
  type HeatedFields,
  type Variant,
} from "./survival";
import { resolveTeamRound, teamRoundDone, TEAMS, type TeamId, type TeamRacerProgress, type TeamRule } from "./teams";
import { podium, resolveVsRound, seriesStatus, type SeriesLength, type VsRoundHow, type VsRoundResult } from "./vs";

/** Series length until the host picks one (CONFIG). */
export const DEFAULT_SERIES: SeriesLength = 3;
/**
 * How long the standings show between rounds before the next countdown
 * starts by itself; sooner once every connected racer of the next round is
 * ready (NEXT).
 */
export const STANDINGS_MS = 30_000;
/**
 * Round summaries a series keeps for `SERIES_END.history`: the latest this
 * many. Each is about 13 KB at most (5 racers who all found every bonus word
 * of the bank's biggest puzzle, a 10×10 mold), so the series, the award and
 * the results stay below the 2 MB a storage value may hold, and `SERIES_END`
 * below 1 MiB. A series of 10 with a few sudden deaths never gets near it.
 */
export const MAX_HISTORY = 50;

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

/** Survival: every racer's heated word, from one order for the round. */
export interface VsSurvival {
  /** The order slots heat up in, the same for every racer (survival.ts `heatOrder`). */
  readonly order: readonly number[];
  /** Each racer's countdown on their own mold. */
  readonly clocks: Record<string, HeatClock>;
  /** Who melted first, and which slot, ending the round. */
  melted: { readonly id: string; readonly slot: number } | null;
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
  /** Survival only (absent in a classic round). */
  readonly survival?: VsSurvival;
}

export interface NewVsRoundInput {
  readonly round: number;
  readonly suddenDeath: boolean;
  readonly heat: HeatTier;
  readonly puzzle: MpPuzzle;
  readonly playerIds: readonly string[];
  readonly startsAt: number;
  readonly rand: Rand;
  /** Classic unless given. */
  readonly variant?: Variant;
}

function emptyMold(): VsMold {
  return { claims: [], auto: [], bonus: [], pickups: [], filled: 0, reachedAt: 0 };
}

/**
 * Sets up a round: one shuffled anvil and one set of embers for everyone,
 * and the VS clock from `startsAt`. In survival the clock is only a
 * 10-minute safety cap, and every racer's first countdown starts at
 * `startsAt` on the same slot.
 */
export function newVsRound(input: NewVsRoundInput): VsRound {
  const { puzzle, rand } = input;
  const index = indexMold(puzzle);
  const fullLength = new Set(puzzle.slots.filter((s) => s.len === puzzle.letters.length).map((s) => s.word));
  const survival = input.variant === "survival";
  return {
    round: input.round,
    regular: input.suddenDeath ? null : input.round,
    heat: input.heat,
    puzzle,
    letters: shuffleLetters(puzzle.letters, rand, fullLength),
    startsAt: input.startsAt,
    endsAt: input.startsAt + (survival ? SURVIVAL_CAP_MS : vsRoundTimerMs(input.heat)),
    total: index.cells.size,
    playerIds: [...input.playerIds],
    embers: placeEmbers(index, rand),
    molds: Object.fromEntries(input.playerIds.map((id) => [id, emptyMold()])),
    n: 0,
    // Last, so a classic round uses `rand` exactly as before.
    ...(survival ? { survival: newVsSurvival(puzzle, input.heat, input.playerIds, input.startsAt, rand) } : {}),
  };
}

function newVsSurvival(puzzle: MpPuzzle, heat: HeatTier, playerIds: readonly string[], startsAt: number, rand: Rand): VsSurvival {
  const order = heatOrder(puzzle.slots, rand);
  const clocks = Object.fromEntries(playerIds.map((id) => [id, firstClock(order, lenOf(puzzle), heat, startsAt)]));
  return { order, clocks, melted: null };
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

// ---------------------------------------------------------------------------
// Survival (shared/survival.md)
// ---------------------------------------------------------------------------

/**
 * After `id`'s claim at `now`: if their heated slot is now complete on
 * their mold (forged, or filled in by crossings), it counts as saved and
 * the next one heats up for them. True if their heated slot changed; the
 * caller then sends them HEATED, unless their mold is full.
 */
export function applyVsHeat(r: VsRound, id: string, now: number): boolean {
  const clock = r.survival?.clocks[id];
  const mold = r.molds[id];
  if (r.survival === undefined || r.survival.melted !== null || clock === undefined || mold === undefined) return false;
  const done = new Set([...mold.claims, ...mold.auto].map((s) => s.slot));
  return applyHeatProgress(clock, r.survival.order, done, lenOf(r.puzzle), r.heat, now);
}

/** The next melt among `contenders` (the racers still in the series): the earliest, a tie going to the earlier racer. */
export function vsNextMelt(r: VsRound, contenders: readonly string[]): { readonly id: string; readonly slot: number; readonly at: number } | null {
  if (r.survival === undefined || r.survival.melted !== null) return null;
  let next: { id: string; slot: number; at: number } | null = null;
  for (const id of r.playerIds) {
    const clock = r.survival.clocks[id];
    if (!contenders.includes(id) || clock === undefined || clock.slot === null) continue;
    const at = meltAt(clock);
    if (at !== null && (next === null || at < next.at)) next = { id, slot: clock.slot, at };
  }
  return next;
}

/** `id`'s heated slot melted: notes it (the round then ends, `melted`). False if nothing of theirs was heated. */
export function applyVsMelt(r: VsRound, id: string): boolean {
  const slot = r.survival?.clocks[id]?.slot;
  if (r.survival === undefined || slot === undefined || slot === null) return false;
  r.survival.melted = { id, slot };
  return true;
}

/** Notes that `by` collected the ember at `ember` as a `kind` hint (granted after the series). */
export function applyVsPickup(r: VsRound, by: string, ember: Pos, kind: HintKind): void {
  r.molds[by]?.pickups.push({ x: ember.x, y: ember.y, kind });
}

export interface VsProgress {
  readonly id: string;
  readonly filled: number;
  readonly total: number;
  /** Only for someone watching the round: the racer's complete slots, sorted (never letters). */
  readonly slots?: readonly number[];
}

/**
 * Every racer's progress: counts only, never words or cells. Someone
 * [watching] (sitting out a sudden death, or out of the series) also gets
 * which slots each racer has done, to watch their molds fill; racers never
 * see where their rivals are.
 */
export function progressOf(r: VsRound, watching = false): VsProgress[] {
  const molds = watching ? moldsOf(r) : null;
  return r.playerIds.map((id) => ({
    id,
    filled: r.molds[id]?.filled ?? 0,
    total: r.total,
    ...(molds === null ? {} : { slots: molds[id] ?? [] }),
  }));
}

/** Whether [id] is watching rather than racing this round. */
export function watchesRound(r: VsRound, s: VsSeries, id: string): boolean {
  return !r.playerIds.includes(id) || !canRace(s, id);
}

/**
 * Every racer's complete slots (forged, or filled in by themselves), sorted:
 * their molds, for `ROUND_END` only, once nothing more counts.
 */
export function moldsOf(r: VsRound): Record<string, number[]> {
  const slots = (m: VsMold | undefined) => (m === undefined ? [] : [...m.claims, ...m.auto].map((s) => s.slot).sort((a, b) => a - b));
  return Object.fromEntries(r.playerIds.map((id) => [id, slots(r.molds[id])]));
}

/** A round's result: in Team Versus, also the team that won it and each team's letters. */
export interface VsRoundOutcome extends VsRoundResult {
  readonly team?: TeamId | null;
  readonly teamScores?: [number, number];
}

/** Every racer of the round among `contenders`, with their team (Team Versus only). */
function teamProgress(s: VsSeries, r: VsRound, contenders: readonly string[]): TeamRacerProgress[] {
  return r.playerIds.flatMap((id) => {
    const team = s.racers.find((x) => x.id === id)?.team;
    if (team === undefined || !contenders.includes(id)) return [];
    return [{ playerId: id, team, lettersFilled: r.molds[id]?.filled ?? 0, reachedAt: r.molds[id]?.reachedAt ?? 0 }];
  });
}

/**
 * Whether a racer filling their whole mold ends the round now. Versus and
 * Team Versus's `first`: yes. `combined`: only once every racer still in
 * the series on one team has.
 */
export function vsRoundDone(s: VsSeries, r: VsRound): boolean {
  if (s.teams === undefined) return true;
  return teamRoundDone(s.teams.rule, r.total, teamProgress(s, r, activeRacers(s)));
}

/** Who wins the round if it ends now, among `contenders` (the racers still in the series). */
export function resolveSeriesRound(s: VsSeries, r: VsRound, contenders: readonly string[]): VsRoundOutcome {
  if (s.teams === undefined) return resolveRound(r, contenders);
  const { team, winner, how, scores } = resolveTeamRound(s.teams.rule, r.total, teamProgress(s, r, contenders));
  return { winner, how, team, teamScores: scores };
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
  /** Team Versus: their team for the whole series. */
  readonly team?: TeamId;
}

/** Team Versus: the rule rounds are won by, and each team's round wins as `[copper, cobalt]`. */
export interface VsTeams {
  readonly rule: TeamRule;
  readonly wins: [number, number];
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
  /**
   * Every round ended so far, in order ({@link MAX_HISTORY} at most), for
   * `SERIES_END`. Absent in series stored before it, and until the first
   * round ends.
   */
  history?: VsRoundSummary[];
  /** Survival: every round of the series is one (fixed at the start). Absent for classic. */
  readonly variant?: "survival";
  /** Team Versus only (fixed at the start, like the racers' teams). */
  readonly teams?: VsTeams;
}

export interface NewVsSeriesInput {
  readonly matchId: string;
  readonly length: SeriesLength;
  readonly heat: HeatTier;
  readonly racerIds: readonly string[];
  readonly startedAt: number;
  /** Classic unless given. */
  readonly variant?: Variant;
  /** Team Versus: the rule, and every racer's team. */
  readonly teams?: { readonly rule: TeamRule; readonly of: Readonly<Record<string, TeamId>> };
}

export function newVsSeries(input: NewVsSeriesInput): VsSeries {
  const teams = input.teams;
  return {
    matchId: input.matchId,
    length: input.length,
    heat: input.heat,
    startedAt: input.startedAt,
    racers: input.racerIds.map((id) => ({
      id,
      wins: 0,
      rounds: 0,
      words: 0,
      longest: "",
      bonus: 0,
      pickups: noHints(),
      out: false,
      ...(teams?.of[id] === undefined ? {} : { team: teams.of[id] }),
    })),
    played: 0,
    standingsEndsAt: null,
    ...(input.variant === "survival" ? { variant: "survival" as const } : {}),
    ...(teams === undefined ? {} : { teams: { rule: teams.rule, wins: [0, 0] as [number, number] } }),
  };
}

/** Team Versus: each racer's team, out or not. */
export function teamsOf(s: VsSeries): Record<string, TeamId> {
  return Object.fromEntries(s.racers.flatMap((r) => (r.team === undefined ? [] : [[r.id, r.team]])));
}

/** Team Versus: the teams with someone still in the series. */
function activeTeams(s: VsSeries): TeamId[] {
  return TEAMS.filter((team) => s.racers.some((r) => r.team === team && !r.out));
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

/**
 * Adds a finished round to the series: the winner's win (Team Versus: the
 * team's, and a win for each of its racers in the round), and each racer's
 * rounds, words (and which), bonus words and embers.
 */
export function recordRound(s: VsSeries, r: VsRound, result: VsRoundOutcome): void {
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
  if (s.teams !== undefined) {
    const team = result.team;
    if (team === undefined || team === null) return;
    s.teams.wins[team] += 1;
    // Like a Versus racer, one who has left can't win any more rounds.
    for (const racer of s.racers) if (racer.team === team && !racer.out && r.playerIds.includes(racer.id)) racer.wins += 1;
    return;
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
  /** Team Versus: always `null` (see `team`). */
  readonly winner: string | null;
  /** Clinched before the last regular round. */
  readonly early: boolean;
  /** Won because every other contender left. */
  readonly forfeit: boolean;
  /** Team Versus only: the team that won the series, or `null`. */
  readonly team?: TeamId | null;
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
  if (s.teams !== undefined) return teamSeriesDecision(s, s.teams);
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
 * Team Versus, judged on team wins: a team with nobody left in the series
 * loses by forfeit; otherwise as in Versus, with every racer still in the
 * series playing each round, sudden death included.
 */
function teamSeriesDecision(s: VsSeries, teams: VsTeams): VsSeriesDecision {
  const left = activeTeams(s);
  if (left.length <= 1) return { over: true, winner: null, team: left[0] ?? null, early: false, forfeit: true };
  const status = seriesStatus(
    TEAMS.map((team) => ({ playerId: String(team), wins: teams.wins[team] })),
    s.length,
    s.played,
  );
  if (status.state === "won") return { over: true, winner: null, team: Number(status.winner) as TeamId, early: status.early, forfeit: false };
  return { over: false, next: { round: s.played + 1, suddenDeath: status.state === "sudden_death", players: activeRacers(s) } };
}

/**
 * How a series ends when it has to stop now (the room is closing): as
 * decided if it is, otherwise with no winner.
 */
export function stopSeries(s: VsSeries): VsSeriesOutcome {
  const d = seriesDecision(s);
  const team = s.teams === undefined ? {} : { team: d.over ? (d.team ?? null) : null };
  return d.over ? { winner: d.winner, early: d.early, forfeit: d.forfeit, ...team } : { winner: null, early: false, forfeit: false, ...team };
}

// ---------------------------------------------------------------------------
// What clients see
// ---------------------------------------------------------------------------

/** `ROUND_START` in Versus: the co-op fields plus the series. */
export interface VsRoundStartFields extends RoundStartFields, VsTeamFields {
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
    ...teamFields(s),
  };
}

/** Team Versus: the rule, everyone's team, and the teams' round wins as `[copper, cobalt]`. */
export interface VsTeamFields {
  readonly rule?: TeamRule;
  readonly teams?: Readonly<Record<string, TeamId>>;
  readonly teamTally?: readonly [number, number];
}

function teamFields(s: VsSeries): VsTeamFields {
  if (s.teams === undefined) return {};
  return { rule: s.teams.rule, teams: teamsOf(s), teamTally: [s.teams.wins[0], s.teams.wins[1]] };
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

/**
 * The `round` part of a Versus `SNAPSHOT`: `mine` is empty for someone
 * watching. Survival: `heated` is the receiver's own (`null` for someone
 * watching, a racer out of the series included, or when nothing of theirs
 * glows) and `saved` theirs (0 for someone who didn't race).
 */
export interface VsRoundSnapshot extends VsRoundStartFields {
  readonly mine: VsMine;
  readonly progress: readonly VsProgress[];
  readonly saved?: number;
}

export function vsRoundSnapshot(r: VsRound, s: VsSeries, receiver: string, serverNow: number): VsRoundSnapshot {
  const clock = r.survival?.clocks[receiver];
  return {
    ...vsRoundStartFields(r, s, serverNow),
    mine: mineOf(r, receiver),
    progress: progressOf(r, watchesRound(r, s, receiver)),
    ...(r.survival === undefined
      ? {}
      : {
          heated: clock === undefined || r.survival.melted !== null || !canRace(s, receiver) ? null : heatedFields(clock, serverNow),
          saved: clock?.saved ?? 0,
        }),
  };
}

/** `HEATED` for `id`'s own mold, or `null` (not racing, or nothing of theirs glows). */
export function vsHeatedFor(r: VsRound, id: string, serverNow: number): HeatedFields | null {
  const clock = r.survival?.clocks[id];
  return clock === undefined ? null : heatedFields(clock, serverNow);
}

export type VsRoundEndReason = "finished" | "timeout" | "melted";

/** How a round was won, as sent in `ROUND_END`: survival adds `survived` (a melt, won by the most letters among the others). */
export type VsRoundEndHow = VsRoundHow | "survived";

/** `ROUND_END` in Versus. */
export interface VsRoundEndFields extends VsTeamFields {
  /** Not in the contract: the round that ended. */
  readonly round: number;
  readonly reason: VsRoundEndReason;
  readonly winner: string | null;
  readonly how: VsRoundEndHow;
  readonly progress: readonly VsProgress[];
  /** Each racer's complete slots, sorted ({@link moldsOf}). */
  readonly molds: Readonly<Record<string, readonly number[]>>;
  /** Wins after this round, for everyone in the series. */
  readonly tally: Readonly<Record<string, number>>;
  readonly answers: readonly SlotWord[];
  readonly next: VsNextRound | null;
  readonly standingsEndsAt: number | null;
  /** Survival only: `"survival"`, each racer's words saved, and who melted which slot (`null` if nobody did). */
  readonly variant?: Variant;
  readonly saved?: Readonly<Record<string, number>>;
  readonly melted?: { readonly id: string; readonly slot: number } | null;
  /** Team Versus only: the team that won the round (`null`: nobody), and each team's letters as `[copper, cobalt]`. */
  readonly team?: TeamId | null;
  readonly teamScores?: readonly [number, number];
}

export interface VsRoundEnd {
  readonly fields: VsRoundEndFields;
  /** The series is over (decided, or stopped): `null` while it goes on to `fields.next`. */
  readonly outcome: VsSeriesOutcome | null;
}

/**
 * One ended round as `SERIES_END.history` lists it: how it went, every
 * racer's mold with its shape (as in `ROUND_START`), the words, and every
 * racer's Scrap Bin, so the podium can go back over it, even with someone
 * who never saw the round start. Only sent once the series is over.
 */
export interface VsRoundSummary {
  readonly round: number;
  readonly suddenDeath: boolean;
  readonly reason: VsRoundEndReason;
  readonly winner: string | null;
  readonly how: VsRoundEndHow;
  readonly cols: number;
  readonly rows: number;
  readonly slots: RoundStartFields["slots"];
  readonly progress: readonly VsProgress[];
  readonly molds: Readonly<Record<string, readonly number[]>>;
  /**
   * The anvil (as in `ROUND_START`), every grid word (as in `ROUND_END`), and
   * each racer's bonus words in the order found (`[]` for none). Absent in
   * rounds stored before them.
   */
  readonly letters?: string;
  readonly answers?: readonly SlotWord[];
  readonly bins?: Readonly<Record<string, readonly string[]>>;
  /** Survival only: who melted which slot (`null` if nobody did), and each racer's words saved. */
  readonly melted?: { readonly id: string; readonly slot: number } | null;
  readonly saved?: Readonly<Record<string, number>>;
  /** Team Versus only: the team that won it, and each team's letters, as in its `ROUND_END`. */
  readonly team?: TeamId | null;
  readonly teamScores?: readonly [number, number];
}

/** Adds the round that `end` closed to the series' history, dropping the oldest past {@link MAX_HISTORY}. */
function recordHistory(s: VsSeries, r: VsRound, end: VsRoundEndFields): void {
  const history = (s.history ??= []);
  history.push({
    round: r.round,
    suddenDeath: r.regular === null,
    reason: end.reason,
    winner: end.winner,
    how: end.how,
    cols: r.puzzle.cols,
    rows: r.puzzle.rows,
    slots: r.puzzle.slots.map(({ slot, x, y, d, len }) => ({ slot, x, y, d, len })),
    progress: end.progress,
    molds: end.molds,
    letters: r.letters,
    answers: end.answers,
    bins: Object.fromEntries(r.playerIds.map((id) => [id, [...(r.molds[id]?.bonus ?? [])]])),
    ...(end.melted === undefined ? {} : { melted: end.melted }),
    ...(end.saved === undefined ? {} : { saved: end.saved }),
    ...(end.team === undefined ? {} : { team: end.team, teamScores: end.teamScores }),
  });
  if (history.length > MAX_HISTORY) history.splice(0, history.length - MAX_HISTORY);
}

/**
 * Ends the round now: resolves it among the racers still in the series,
 * adds it to the series (and to its history), and decides what comes next.
 * With `stop` the series ends here whatever the tally (the room is
 * closing). The standings would run until `now + STANDINGS_MS`.
 *
 * A melt (`melted`, after {@link applyVsMelt}) is resolved among the
 * others: the most letters wins, a tie going to whoever got there first
 * (`survived`); nobody with a letter is no winner (`none`).
 */
export function endVsRound(s: VsSeries, r: VsRound, reason: VsRoundEndReason, now: number, stop = false): VsRoundEnd {
  const melter = reason === "melted" ? r.survival?.melted?.id : undefined;
  const result = resolveSeriesRound(s, r, activeRacers(s).filter((id) => id !== melter));
  recordRound(s, r, result);
  // Nobody can have filled their mold, so a melt is won on letters, or not at all.
  const how: VsRoundEndHow = melter !== undefined && result.how === "timeout" ? "survived" : result.how;
  const decision = seriesDecision(s);
  const outcome = decision.over
    ? { winner: decision.winner, early: decision.early, forfeit: decision.forfeit, ...(decision.team === undefined ? {} : { team: decision.team }) }
    : stop
      ? stopSeries(s)
      : null;
  const end: VsRoundEnd = {
    fields: {
      round: r.round,
      reason,
      winner: result.winner,
      how,
      progress: progressOf(r),
      molds: moldsOf(r),
      tally: tallyOf(s),
      answers: r.puzzle.slots.map(({ slot, word }) => ({ slot, word })),
      next: outcome === null && !decision.over ? decision.next : null,
      standingsEndsAt: outcome === null ? now + STANDINGS_MS : null,
      ...(r.survival === undefined
        ? {}
        : {
            variant: "survival" as const,
            saved: Object.fromEntries(r.playerIds.map((id) => [id, r.survival!.clocks[id]?.saved ?? 0])),
            melted: r.survival.melted === null ? null : { ...r.survival.melted },
          }),
      ...(s.teams === undefined ? {} : { ...teamFields(s), team: result.team ?? null, teamScores: result.teamScores ?? [0, 0] }),
    },
    outcome,
  };
  recordHistory(s, r, end.fields);
  return end;
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
  /** Team Versus only. */
  readonly team?: TeamId;
}

export interface VsSeriesResults extends VsSeriesOutcome {
  /** Rounds played, sudden death included. */
  readonly rounds: number;
  /** Team Versus only: the teams' round wins, as `[copper, cobalt]`. */
  readonly teamTally?: readonly [number, number];
  /** Everyone in the series, out or not, in podium order. */
  readonly players: readonly VsPlayerResult[];
}

/**
 * The finished series: the podium by round wins (equal wins share a place,
 * and the winner comes first among them), and each racer's totals.
 */
export function vsSeriesResults(s: VsSeries, outcome: VsSeriesOutcome): VsSeriesResults {
  const result = (r: VsRacer, place: number): VsPlayerResult => ({
    id: r.id,
    wins: r.wins,
    place,
    rounds: r.rounds,
    words: r.words,
    longest: r.longest,
    bonus: r.bonus,
    pickups: { ...r.pickups },
    ...(r.team === undefined ? {} : { team: r.team }),
  });
  if (s.teams !== undefined) {
    // Places are the teams': the winners first (or the team with more round wins), then the rest.
    const wins = s.teams.wins;
    const winner = outcome.team ?? (wins[0] === wins[1] ? null : wins[0] > wins[1] ? 0 : 1);
    const placeOf = (team: TeamId | undefined) => (winner === null || team === winner ? 1 : 2);
    const ordered = [...s.racers].sort((a, b) => placeOf(a.team) - placeOf(b.team) || (a.team ?? 0) - (b.team ?? 0));
    return {
      ...outcome,
      team: outcome.team ?? null,
      rounds: s.played,
      teamTally: [wins[0], wins[1]],
      players: ordered.map((r) => result(r, placeOf(r.team))),
    };
  }
  const ordered = [...s.racers].sort((a, b) => Number(b.id === outcome.winner) - Number(a.id === outcome.winner));
  const places = podium(ordered.map((r) => ({ playerId: r.id, wins: r.wins })));
  return {
    ...outcome,
    rounds: s.played,
    players: places.map((p) => result(s.racers.find((x) => x.id === p.playerId)!, p.place)),
  };
}

/** Whether `player` won the series: their team did, in Team Versus. */
export function wonSeries(results: VsSeriesResults, player: VsPlayerResult): boolean {
  return results.team !== undefined ? results.team !== null && player.team === results.team : results.winner === player.id;
}

export interface VsAward {
  readonly amount: number;
  /** What the heat added to `amount`, and how many tiers it ran above the player's own (progression.ts `heatXp`). */
  readonly heatBonus: number;
  readonly tiersAbove: number;
  readonly xp: XpAward;
  readonly scrap: ScrapBinResult;
  /** Every hint to add: level-up rewards, Scrap Bin hammers and embers. */
  readonly gained: HintCounts;
}

/**
 * What one player gets for the series: VS XP (5 per round raced, 10 per
 * round won, 30 for the series; Team Versus: rounds and the series their
 * team won) at the series' `heat` (more so above the player's own tier,
 * `heatXp`) with any level-ups and their rewards, the series' bonus words
 * smelted in the Scrap Bin, and the embers collected.
 */
export function vsAward(
  player: VsPlayerResult,
  won: boolean,
  profile: { readonly totalXp: number; readonly scrapBin: number },
  heat: HeatTier,
): VsAward {
  const base = vsSeriesXp({ roundsPlayed: player.rounds, roundsWon: player.wins, wonSeries: won });
  const hot = heatXp(base, heat, levelFromTotalXp(profile.totalXp));
  const xp = applyXp(profile.totalXp, hot.xp);
  const scrap = addToScrapBin(profile.scrapBin, player.bonus);
  const gained = noHints();
  for (const kind of HINT_KINDS) gained[kind] = xp.rewards[kind] + player.pickups[kind];
  gained.hammer += scrap.hammers;
  return { amount: hot.xp, heatBonus: hot.heatBonus, tiersAbove: hot.tiersAbove, xp, scrap, gained };
}

