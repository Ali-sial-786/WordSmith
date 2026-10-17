/** Shared fixtures for the room rule tests. */

import type { Rand } from "../../src/rules/mold";

/**
 * The example from shared/puzzle-format.md, as a bank puzzle:
 *
 *     T E A R
 *     . A . A
 *     . T . T
 *     . . . E
 *
 * Slots in reading order: 0 TEAR (across), 1 EAT (down), 2 RATE (down).
 */
export const EXAMPLE = {
  id: "m-99999",
  letters: "RTAE",
  heat: 1,
  size: 1,
  cols: 4,
  rows: 4,
  words: [
    { w: "RATE", x: 3, y: 0, d: "d" },
    { w: "EAT", x: 1, y: 0, d: "d" },
    { w: "TEAR", x: 0, y: 0, d: "a" },
  ],
  bonus: ["ARE", "ART", "ATE", "EAR", "ERA", "RAT", "TAR", "TEA"],
};

/** A Rand that plays back `values`, then repeats the last one. */
export function playback(...values: number[]): Rand {
  let i = 0;
  return () => values[Math.min(i++, values.length - 1)]!;
}

/**
 * A Versus-style mold where one slot is crossed on every cell, so it fills
 * in by itself once its crossing words are forged (no hints needed):
 *
 *     A B C . .
 *     . . D E F
 *     B A F . .
 *
 * Slots in reading order: 0 ABC (across), 1 CDF (down), 2 DEF (across),
 * 3 BAF (across). 9 letter cells. The words needn't be English: the rules
 * only check them against the anvil and the puzzle.
 */
export const CROSSED = {
  id: "m-99998",
  letters: "ABCDEF",
  heat: 1,
  size: 1,
  cols: 5,
  rows: 3,
  words: [
    { w: "ABC", x: 0, y: 0, d: "a" },
    { w: "DEF", x: 2, y: 1, d: "a" },
    { w: "BAF", x: 0, y: 2, d: "a" },
    { w: "CDF", x: 2, y: 0, d: "d" },
  ],
  bonus: ["BAD", "CAB", "FADE"],
};
