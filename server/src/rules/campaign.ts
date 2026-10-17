/**
 * Campaign puzzles as the server sees them, for checking solo syncs.
 * The JSON shape is shared/puzzle-format.md; rows come from the `campaign`
 * table, which `scripts/build-campaign-sql.mjs` fills from the app's
 * bundled `campaign.json`.
 */

export interface PuzzleWordJson {
  readonly w: string;
  readonly x: number;
  readonly y: number;
  readonly d: "a" | "d";
}

export interface PuzzleJson {
  readonly id: string;
  readonly letters: string;
  readonly words: readonly PuzzleWordJson[];
  readonly bonus: readonly string[];
}

export interface CampaignPuzzle {
  readonly stage: number;
  readonly id: string;
  readonly gridWords: ReadonlySet<string>;
  readonly bonus: ReadonlySet<string>;
  /** Letter cells in the grid (crossings counted once). Pickups index into these. */
  readonly cellCount: number;
  /** For each grid word, the indexes of the cells it covers, into the cells sorted by row, then column. */
  readonly wordCells: ReadonlyMap<string, readonly number[]>;
}

/** `c-` + the 1-based stage number padded to 4 digits (shared/puzzle-format.md). */
export function campaignPuzzleId(stage: number): string {
  return `c-${String(stage).padStart(4, "0")}`;
}

const UPPER_WORD = /^[A-Z]{3,}$/;

function isWord(value: unknown): value is PuzzleWordJson {
  if (typeof value !== "object" || value === null) return false;
  const w = value as Record<string, unknown>;
  return (
    typeof w.w === "string" &&
    UPPER_WORD.test(w.w) &&
    Number.isInteger(w.x) &&
    Number.isInteger(w.y) &&
    (w.x as number) >= 0 &&
    (w.y as number) >= 0 &&
    (w.d === "a" || w.d === "d")
  );
}

/**
 * Builds the checking model for one stage from its puzzle JSON.
 * Throws if the JSON isn't a usable puzzle.
 */
export function campaignPuzzle(stage: number, data: unknown): CampaignPuzzle {
  if (typeof data !== "object" || data === null) throw new TypeError(`stage ${stage}: puzzle is not an object`);
  const p = data as Record<string, unknown>;
  if (typeof p.id !== "string") throw new TypeError(`stage ${stage}: puzzle has no id`);
  if (!Array.isArray(p.words) || p.words.length === 0 || !p.words.every(isWord)) {
    throw new TypeError(`stage ${stage}: bad words`);
  }
  if (!Array.isArray(p.bonus) || !p.bonus.every((b) => typeof b === "string")) {
    throw new TypeError(`stage ${stage}: bad bonus list`);
  }
  const words = p.words as PuzzleWordJson[];

  // Every letter cell, keyed "x,y".
  const cellOf = (w: PuzzleWordJson, i: number): [number, number] => (w.d === "a" ? [w.x + i, w.y] : [w.x, w.y + i]);
  const cells = new Map<string, [number, number]>();
  for (const w of words) {
    for (let i = 0; i < w.w.length; i++) {
      const [x, y] = cellOf(w, i);
      cells.set(`${x},${y}`, [x, y]);
    }
  }
  const sorted = [...cells.entries()].sort(([, a], [, b]) => (a[1] !== b[1] ? a[1] - b[1] : a[0] - b[0]));
  const indexOf = new Map(sorted.map(([key], i) => [key, i]));

  const wordCells = new Map<string, number[]>();
  for (const w of words) {
    const indexes: number[] = [];
    for (let i = 0; i < w.w.length; i++) {
      const [x, y] = cellOf(w, i);
      indexes.push(indexOf.get(`${x},${y}`)!);
    }
    wordCells.set(w.w, indexes);
  }

  return {
    stage,
    id: p.id,
    gridWords: new Set(words.map((w) => w.w)),
    bonus: new Set(p.bonus as string[]),
    cellCount: sorted.length,
    wordCells,
  };
}
