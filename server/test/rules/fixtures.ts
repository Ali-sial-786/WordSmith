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
