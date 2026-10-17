/**
 * Co-op ("The Guild Forge") rules: claims, scoring, MVP and stars
 * (docs/DESIGN.md §3.3 and §8).
 */

import { checkGuess } from "./words";

// ---------------------------------------------------------------------------
// Scoring
// ---------------------------------------------------------------------------

export const GRID_POINTS_PER_LETTER = 10;
export const BONUS_POINTS_PER_LETTER = 3;

/**
 * Points for forging a grid word: 10 for each letter that a hint did not
 * reveal. Letters filled by other players' words still count; only hinted
 * letters score nothing.
 */
export function gridWordPoints(letterCount: number, hintedLetters: number): number {
  return GRID_POINTS_PER_LETTER * Math.max(0, letterCount - hintedLetters);
}

/** Points for finding a bonus word nobody had found: 3 per letter. */
export function bonusWordPoints(letterCount: number): number {
  return BONUS_POINTS_PER_LETTER * letterCount;
}

// ---------------------------------------------------------------------------
// Claim decision
// ---------------------------------------------------------------------------

export interface ClaimContext {
  /** The anvil letters, uppercase. */
  readonly letters: string;
  /** The puzzle's grid words, uppercase. */
  readonly answers: ReadonlySet<string>;
  /** The puzzle's bonus words, uppercase. */
  readonly bonus: ReadonlySet<string>;
  /**
   * Every grid or bonus word already found this round, mapped to the player
   * who found it. `null` means a grid word that hints revealed completely,
   * which completes itself and belongs to nobody.
   */
  readonly found: ReadonlyMap<string, string | null>;
}

/** Mirrors the `WORD_RESULT` outcomes in docs/TECH.md §5 (rate limiting happens before this). */
export type ClaimDecision =
  | { readonly result: "claimed"; readonly word: string }
  | { readonly result: "bonus"; readonly word: string }
  | { readonly result: "already"; readonly word: string; readonly by: string | null }
  | { readonly result: "invalid" };

/**
 * Referees one submitted word. Words must arrive in order: the first
 * submission of a word that nobody has found gets it.
 *
 * Versus can use this too, with `found` holding only that player's own
 * finds, since each player has their own mold.
 */
export function decideClaim(rawWord: string, ctx: ClaimContext): ClaimDecision {
  const word = checkGuess(rawWord, ctx.letters);
  if (word === null) return { result: "invalid" };
  if (ctx.found.has(word)) return { result: "already", word, by: ctx.found.get(word) ?? null };
  if (ctx.answers.has(word)) return { result: "claimed", word };
  if (ctx.bonus.has(word)) return { result: "bonus", word };
  return { result: "invalid" };
}

// ---------------------------------------------------------------------------
// MVP ("Master of the Forge")
// ---------------------------------------------------------------------------

export interface CoopStanding {
  readonly playerId: string;
  readonly points: number;
  /**
   * When the player reached their current points. Any increasing order key
   * works; the claim sequence number is best because it can never tie.
   */
  readonly reachedAt: number;
}

export interface ScoredClaim {
  readonly playerId: string;
  readonly points: number;
}

/**
 * Builds standings from the round's scoring claims in arrival order.
 * `reachedAt` is the index of the claim that brought the player to their
 * total. Players with no claims get 0 points.
 */
export function standingsFromClaims(playerIds: readonly string[], claims: readonly ScoredClaim[]): CoopStanding[] {
  const byPlayer = new Map<string, { points: number; reachedAt: number }>();
  for (const id of playerIds) byPlayer.set(id, { points: 0, reachedAt: -1 });
  claims.forEach((claim, index) => {
    const s = byPlayer.get(claim.playerId) ?? { points: 0, reachedAt: -1 };
    byPlayer.set(claim.playerId, claim.points > 0 ? { points: s.points + claim.points, reachedAt: index } : s);
  });
  return [...byPlayer].map(([playerId, s]) => ({ playerId, ...s }));
}

/**
 * The top scorer. If players tie on points, the one who reached that score
 * first wins (an exact tie on `reachedAt` goes to the earlier entry).
 * Returns `null` if nobody scored.
 */
export function pickMvp(standings: readonly CoopStanding[]): string | null {
  let best: CoopStanding | null = null;
  for (const s of standings) {
    if (s.points <= 0) continue;
    if (best === null || s.points > best.points || (s.points === best.points && s.reachedAt < best.reachedAt)) {
      best = s;
    }
  }
  return best?.playerId ?? null;
}

// ---------------------------------------------------------------------------
// Stars
// ---------------------------------------------------------------------------

export interface CoopRoundOutcome {
  /** Letter cells filled when the round ended, by words or hints. */
  readonly filledCells: number;
  readonly totalCells: number;
  /** Time left on the clock when the round ended (0 on timeout). */
  readonly timeLeftMs: number;
  /** The round's full length. */
  readonly roundMs: number;
}

export type Stars = 0 | 1 | 2 | 3;

/** ★★★ finished with ≥50% of the time left, ★★ finished, ★ ≥75% filled, otherwise none. */
export function coopStars(outcome: CoopRoundOutcome): Stars {
  const { filledCells, totalCells, timeLeftMs, roundMs } = outcome;
  const finished = filledCells >= totalCells;
  if (finished && timeLeftMs * 2 >= roundMs) return 3;
  if (finished) return 2;
  if (filledCells * 4 >= totalCells * 3) return 1;
  return 0;
}
