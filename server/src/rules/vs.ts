/**
 * Versus ("Anvil Clash") rules: rounds, series, sudden death and podium
 * (docs/DESIGN.md §9).
 *
 * Sudden-death rounds count as rounds: add their winner's win to the tally
 * and count them in `roundsPlayed`. A tie after the last round then becomes a
 * unique leader once a sudden-death round has a winner, and a sudden-death
 * round with no winner simply leads to another one between the same players.
 *
 * A **total score** series (`scoring: "total"`) plays every regular round
 * whatever the tally, each still ending when the first racer fills their
 * mold, and is won on the letters each racer filled over the whole series.
 * A tie goes to the most bonus words found (Scrap Bin); one still tied goes
 * to a tiebreaker round between the leaders (sudden death), whose winner
 * takes the series.
 */

export const SERIES_LENGTHS = [3, 5, 7, 10] as const;
export type SeriesLength = (typeof SERIES_LENGTHS)[number];

export function isSeriesLength(value: unknown): value is SeriesLength {
  return (SERIES_LENGTHS as readonly unknown[]).includes(value);
}

/** How a series is won: on round wins (the default), or on the letters filled over all its rounds. */
export const SCORINGS = ["rounds", "total"] as const;
export type Scoring = (typeof SCORINGS)[number];
/** What a new Versus room plays until the host picks (CONFIG `scoring`). */
export const DEFAULT_SCORING: Scoring = "rounds";

export function isScoring(value: unknown): value is Scoring {
  return (SCORINGS as readonly unknown[]).includes(value);
}

// ---------------------------------------------------------------------------
// Rounds
// ---------------------------------------------------------------------------

export interface VsRoundProgress {
  readonly playerId: string;
  /** Letter cells filled on this player's own mold. */
  readonly lettersFilled: number;
  /**
   * When the player reached `lettersFilled`. Any increasing order key works;
   * the submission sequence number is best because it can never tie.
   */
  readonly reachedAt: number;
}

/** How a round was won, as sent in `ROUND_END`. */
export type VsRoundHow = "finished" | "timeout" | "none";

export interface VsRoundResult {
  readonly winner: string | null;
  readonly how: VsRoundHow;
}

/**
 * Resolves a round that has just ended.
 *
 * - Someone filled their whole mold: the first to do so wins (`finished`).
 * - Otherwise (timer ran out) the most letters filled wins, and a tie goes to
 *   whoever reached that count first (`timeout`).
 * - Nobody filled anything: no winner (`none`).
 *
 * Pass only the players who can still win: the round's participants (just
 * the tied players in sudden death), without anyone who has left the series.
 */
export function resolveVsRound(totalLetters: number, players: readonly VsRoundProgress[]): VsRoundResult {
  const finishers = players.filter((p) => p.lettersFilled >= totalLetters);
  if (finishers.length > 0) return { winner: earliest(finishers).playerId, how: "finished" };

  const most = Math.max(0, ...players.map((p) => p.lettersFilled));
  if (most === 0) return { winner: null, how: "none" };
  const leaders = players.filter((p) => p.lettersFilled === most);
  return { winner: earliest(leaders).playerId, how: "timeout" };
}

/** The entry with the smallest `reachedAt`; an exact tie goes to the earlier entry. */
function earliest(players: readonly VsRoundProgress[]): VsRoundProgress {
  return players.reduce((best, p) => (p.reachedAt < best.reachedAt ? p : best));
}

// ---------------------------------------------------------------------------
// Series
// ---------------------------------------------------------------------------

export interface SeriesEntry {
  readonly playerId: string;
  /** Round wins so far, including any sudden-death round won. */
  readonly wins: number;
}

/** Regular rounds still to play; never negative. */
export function roundsLeft(seriesLength: number, roundsPlayed: number): number {
  return Math.max(0, seriesLength - roundsPlayed);
}

/**
 * Nobody can catch the leader: `leaderWins > secondWins + roundsLeft`.
 * With one entry, "second" has 0 wins.
 */
export function isClinched(wins: readonly number[], roundsRemaining: number): boolean {
  const sorted = [...wins].sort((a, b) => b - a);
  const leader = sorted[0] ?? 0;
  const second = sorted[1] ?? 0;
  return leader > second + roundsRemaining;
}

/** Everyone on the most wins, in input order. More than one means a tie for the lead. */
export function leaders(standings: readonly SeriesEntry[]): string[] {
  const top = Math.max(0, ...standings.map((s) => s.wins));
  return standings.filter((s) => s.wins === top).map((s) => s.playerId);
}

export type SeriesStatus =
  /** More regular rounds to play. */
  | { readonly state: "playing" }
  /** Decided. `early` is true if it was clinched before the last regular round. */
  | { readonly state: "won"; readonly winner: string; readonly early: boolean }
  /** All regular rounds played and the lead is tied: these players play sudden death. */
  | { readonly state: "sudden_death"; readonly players: readonly string[] };

/**
 * Where the series stands after `roundsPlayed` rounds (regular and sudden
 * death together).
 */
export function seriesStatus(standings: readonly SeriesEntry[], seriesLength: number, roundsPlayed: number): SeriesStatus {
  const left = roundsLeft(seriesLength, roundsPlayed);
  if (isClinched(standings.map((s) => s.wins), left)) {
    return { state: "won", winner: leaders(standings)[0]!, early: left > 0 };
  }
  if (left > 0) return { state: "playing" };
  // Every regular round is played and the lead isn't clear, so it's tied.
  return { state: "sudden_death", players: leaders(standings) };
}

/** Whether the series is finished, either clinched early or after the last round with a clear leader. */
export function isSeriesOver(standings: readonly SeriesEntry[], seriesLength: number, roundsPlayed: number): boolean {
  return seriesStatus(standings, seriesLength, roundsPlayed).state === "won";
}

export interface PodiumPlace {
  readonly playerId: string;
  readonly wins: number;
  /** 1-based. Players with equal wins share a place (1, 2, 2, 4). */
  readonly place: number;
}

/** Final podium ranked by round wins. Equal wins keep their input order and share a place. */
export function podium(standings: readonly SeriesEntry[]): PodiumPlace[] {
  const sorted = standings
    .map((s, order) => ({ ...s, order }))
    .sort((a, b) => b.wins - a.wins || a.order - b.order);
  return sorted.map((s) => ({
    playerId: s.playerId,
    wins: s.wins,
    place: 1 + sorted.filter((o) => o.wins > s.wins).length,
  }));
}

// ---------------------------------------------------------------------------
// Total score
// ---------------------------------------------------------------------------

export interface TotalEntry {
  readonly playerId: string;
  /** Letters filled over the series, on every round raced. */
  readonly score: number;
  /** Bonus words found over the series (Scrap Bin): the tie-break. */
  readonly bonus: number;
}

/** Whether `a` ranks above `b`: the higher score, then more bonus words. */
function ahead(a: TotalEntry, b: TotalEntry): boolean {
  return a.score > b.score || (a.score === b.score && a.bonus > b.bonus);
}

/** Everyone on the best score and bonus words, in input order. More than one plays a tiebreaker. */
export function totalLeaders(entries: readonly TotalEntry[]): string[] {
  return entries.filter((e) => !entries.some((o) => ahead(o, e))).map((e) => e.playerId);
}

/** Final podium of a total-score series: by score, then bonus words; equal on both keep their input order and share a place. */
export function totalPodium(entries: readonly TotalEntry[]): (TotalEntry & { readonly place: number })[] {
  const sorted = entries
    .map((e, order) => ({ ...e, order }))
    .sort((a, b) => b.score - a.score || b.bonus - a.bonus || a.order - b.order);
  return sorted.map((e) => ({ playerId: e.playerId, score: e.score, bonus: e.bonus, place: 1 + sorted.filter((o) => ahead(o, e)).length }));
}
