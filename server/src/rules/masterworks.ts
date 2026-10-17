/**
 * Masterworks (shared/masterworks.md): gilded cells in campaign puzzles,
 * the blueprint pieces they give, and the twelve Masterworks the pieces
 * build.
 *
 * Gilded cells are seeded like hint pickups (pickups.ts, shared/pickups.md),
 * from the player and the puzzle, so the server can check a claimed piece
 * without storing anything. The app's Dart engine implements the same
 * algorithm, and both must reproduce the contract's test vectors.
 */

import { fnv1a32, mulberry32, pickupsFor } from "./pickups";
import { reward, type Reward } from "./rewards";

/** Chance that a puzzle has a gilded cell. */
export const GILDED_CHANCE = 0.25;

/**
 * The gilded cell of one puzzle for one player, or `null` if it has none.
 * At most one per puzzle; never on one of the puzzle's pickup cells (for
 * the same player and level): it steps forward, wrapping around, until
 * it's clear of them.
 *
 * @param userId    the pickup seed: the player's user ID, or the install id
 * @param puzzleId  e.g. `c-0010`
 * @param cellCount number of letter cells in the grid
 * @param level     the player's Smith Level when the puzzle starts (as for pickups)
 */
export function gildedCell(userId: string, puzzleId: string, cellCount: number, level: number): number | null {
  if (!Number.isInteger(cellCount) || cellCount < 1) {
    throw new RangeError(`cellCount must be a positive integer, got ${cellCount}`);
  }
  const rand = mulberry32(fnv1a32(`${userId}:${puzzleId}:gilded`));
  if (rand() >= GILDED_CHANCE) return null;
  let index = Math.floor(rand() * cellCount);
  const pickups = new Set(pickupsFor(userId, puzzleId, cellCount, level).map((p) => p.index));
  if (pickups.size >= cellCount) return null;
  while (pickups.has(index)) index = (index + 1) % cellCount;
  return index;
}

// ---------------------------------------------------------------------------
// The Masterworks
// ---------------------------------------------------------------------------

export interface Masterwork {
  readonly id: string;
  /** Pieces it takes. */
  readonly pieces: number;
}

/** The twelve, in the order they're made. The app owns their names, art and text. */
export const MASTERWORKS: readonly Masterwork[] = [
  { id: "horseshoe", pieces: 6 },
  { id: "bell", pieces: 6 },
  { id: "dagger", pieces: 8 },
  { id: "lantern", pieces: 8 },
  { id: "helm", pieces: 8 },
  { id: "shield", pieces: 10 },
  { id: "axe", pieces: 10 },
  { id: "crown", pieces: 10 },
  { id: "longsword", pieces: 12 },
  { id: "astrolabe", pieces: 12 },
  { id: "warhammer", pieces: 12 },
  { id: "anvil", pieces: 12 },
];

/** Pieces in all twelve: 114. More are still counted, but build nothing. */
export const TOTAL_PIECES = MASTERWORKS.reduce((n, m) => n + m.pieces, 0);

/** What finishing each Masterwork grants, during the sync that does it. */
export const MASTERWORK_REWARD: Reward = reward(100, { chisel: 1, sparks: 1 });

/** The Masterworks finished with `pieces` pieces, in order. */
export function finishedMasterworks(pieces: number): Masterwork[] {
  const done: Masterwork[] = [];
  let total = 0;
  for (const m of MASTERWORKS) {
    total += m.pieces;
    if (pieces < total) break;
    done.push(m);
  }
  return done;
}

/** The Masterworks that going from `before` to `after` pieces finishes. */
export function masterworksFinishedBetween(before: number, after: number): Masterwork[] {
  return finishedMasterworks(after).slice(finishedMasterworks(before).length);
}
