/**
 * Campaign hint-pickup seeding: the shared contract in shared/pickups.md.
 *
 * The app's Dart engine implements the same algorithm, and both must
 * reproduce that file's test vectors exactly, so the server can check
 * claimed pickups without storing them.
 */

import { HINT_UNLOCK_LEVEL, type HintKind } from "./progression";

const FNV_OFFSET_BASIS = 0x811c9dc5;
const FNV_PRIME = 0x01000193;
const utf8 = new TextEncoder();

/** 32-bit FNV-1a over the UTF-8 bytes of `text`. Returns an unsigned 32-bit integer. */
export function fnv1a32(text: string): number {
  let hash = FNV_OFFSET_BASIS;
  for (const byte of utf8.encode(text)) {
    hash ^= byte;
    hash = Math.imul(hash, FNV_PRIME) >>> 0;
  }
  return hash >>> 0;
}

/** mulberry32 PRNG. Each call of the returned function gives a float in [0, 1). */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Chance that a puzzle has any pickup. */
export const PICKUP_CHANCE = 0.2;
/** Chance that a puzzle with pickups has two instead of one. */
export const DOUBLE_PICKUP_CHANCE = 0.15;
/** Cumulative thresholds for the pickup's type: 70% hammer, 25% chisel, 5% sparks. */
export const HAMMER_THRESHOLD = 0.7;
export const CHISEL_THRESHOLD = 0.95;

export interface Pickup {
  /** Index into the grid's letter cells, sorted by row and then column. */
  readonly index: number;
  readonly kind: HintKind;
}

/**
 * The campaign pickups for one player on one puzzle.
 *
 * @param userId    the player's user ID
 * @param puzzleId  e.g. `c-0010`
 * @param cellCount number of letter cells in the grid
 * @param level     the player's Smith Level when the puzzle starts; types it
 *                  hasn't unlocked become Hammer Strikes
 */
export function pickupsFor(userId: string, puzzleId: string, cellCount: number, level: number): Pickup[] {
  if (!Number.isInteger(cellCount) || cellCount < 1) {
    throw new RangeError(`cellCount must be a positive integer, got ${cellCount}`);
  }
  const rand = mulberry32(fnv1a32(`${userId}:${puzzleId}`));

  if (rand() >= PICKUP_CHANCE) return [];
  const wanted = rand() < DOUBLE_PICKUP_CHANCE ? 2 : 1;
  // Not in the shared algorithm, which would loop forever placing 2 pickups
  // in a 1-cell grid. Real puzzles always have 3+ cells, so this never
  // changes a result.
  const count = Math.min(wanted, cellCount);

  const used = new Set<number>();
  const pickups: Pickup[] = [];
  for (let i = 0; i < count; i++) {
    let index = Math.floor(rand() * cellCount);
    while (used.has(index)) index = (index + 1) % cellCount;
    used.add(index);

    const t = rand();
    let kind: HintKind = t < HAMMER_THRESHOLD ? "hammer" : t < CHISEL_THRESHOLD ? "chisel" : "sparks";
    if (kind === "chisel" && level < HINT_UNLOCK_LEVEL.chisel) kind = "hammer";
    if (kind === "sparks" && level < HINT_UNLOCK_LEVEL.sparks) kind = "hammer";

    pickups.push({ index, kind });
  }
  return pickups;
}
