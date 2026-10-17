/**
 * The multiplayer mold: a bank puzzle's slots and cells, and the board
 * helpers every mode needs (which slots a set of filled cells completes,
 * where hints land, where embers go). Pure, so it's unit-tested in Node.
 *
 * Bank puzzles are shared/puzzle-format.md objects with a `size`; rows come
 * from D1's `puzzles` table (scripts/build-bank-sql.mjs).
 */

import type { HeatTier } from "./heat";
import { CHISEL_THRESHOLD, DOUBLE_PICKUP_CHANCE, HAMMER_THRESHOLD, PICKUP_CHANCE } from "./pickups";
import { HINT_UNLOCK_LEVEL, type HintKind } from "./progression";

/** A random number in [0, 1). Rules take one so tests can fix the outcome. */
export type Rand = () => number;

export type Direction = "a" | "d";

/** One grid word's place. `slot` is the number clients see; `word` never leaves the server. */
export interface MpSlot {
  readonly slot: number;
  readonly x: number;
  readonly y: number;
  readonly d: Direction;
  readonly len: number;
  readonly word: string;
}

export interface MpPuzzle {
  readonly id: string;
  readonly letters: string;
  readonly heat: HeatTier;
  readonly size: number;
  readonly cols: number;
  readonly rows: number;
  /** Sorted by row, then column, then across before down; `slot` is the index. */
  readonly slots: readonly MpSlot[];
  readonly bonus: readonly string[];
}

const LETTERS = /^[A-Z]{4,8}$/;
const WORD = /^[A-Z]{3,8}$/;
const MAX_GRID = 10;

function isInt(v: unknown, min: number, max: number): v is number {
  return typeof v === "number" && Number.isInteger(v) && v >= min && v <= max;
}

/**
 * Reads a bank puzzle's JSON. Slots are numbered in reading order rather
 * than the file's order, so a slot number says nothing about the word.
 * Throws if the JSON isn't a usable puzzle.
 */
export function parseMpPuzzle(data: unknown): MpPuzzle {
  if (typeof data !== "object" || data === null) throw new TypeError("puzzle is not an object");
  const p = data as Record<string, unknown>;
  const id = typeof p.id === "string" && p.id !== "" ? p.id : null;
  const where = id ?? "puzzle";
  if (id === null) throw new TypeError("puzzle has no id");
  if (typeof p.letters !== "string" || !LETTERS.test(p.letters)) throw new TypeError(`${where}: bad letters`);
  if (!isInt(p.heat, 1, 6)) throw new TypeError(`${where}: bad heat`);
  const size = p.size === undefined ? 1 : p.size;
  if (!isInt(size, 1, 4)) throw new TypeError(`${where}: bad size`);
  if (!isInt(p.cols, 1, MAX_GRID) || !isInt(p.rows, 1, MAX_GRID)) throw new TypeError(`${where}: bad grid size`);
  const cols = p.cols;
  const rows = p.rows;
  if (!Array.isArray(p.words) || p.words.length === 0) throw new TypeError(`${where}: no words`);
  const raw = p.words.map((w: unknown) => {
    const r = w as Record<string, unknown> | null;
    if (r === null || typeof r !== "object" || typeof r.w !== "string" || !WORD.test(r.w)) {
      throw new TypeError(`${where}: bad word`);
    }
    if (!isInt(r.x, 0, MAX_GRID - 1) || !isInt(r.y, 0, MAX_GRID - 1) || (r.d !== "a" && r.d !== "d")) {
      throw new TypeError(`${where}: bad slot for ${r.w}`);
    }
    const len = r.w.length;
    if ((r.d === "a" ? r.x + len : r.x + 1) > cols || (r.d === "d" ? r.y + len : r.y + 1) > rows) {
      throw new TypeError(`${where}: ${r.w} runs off the grid`);
    }
    return { x: r.x, y: r.y, d: r.d as Direction, len, word: r.w };
  });
  raw.sort((a, b) => a.y - b.y || a.x - b.x || (a.d === b.d ? 0 : a.d === "a" ? -1 : 1));
  if (!Array.isArray(p.bonus) || !p.bonus.every((b) => typeof b === "string")) throw new TypeError(`${where}: bad bonus list`);
  return {
    id,
    letters: p.letters,
    heat: p.heat as HeatTier,
    size,
    cols,
    rows,
    slots: raw.map((s, slot) => ({ slot, ...s })),
    bonus: p.bonus as string[],
  };
}

// ---------------------------------------------------------------------------
// Cells
// ---------------------------------------------------------------------------

export interface Pos {
  readonly x: number;
  readonly y: number;
}

/** `"x,y"`: how cells are keyed in sets and maps. */
export type CellKey = string;

export const cellKey = (x: number, y: number): CellKey => `${x},${y}`;

export function slotCells(s: Pick<MpSlot, "x" | "y" | "d" | "len">): Pos[] {
  const cells: Pos[] = [];
  for (let i = 0; i < s.len; i++) cells.push(s.d === "a" ? { x: s.x + i, y: s.y } : { x: s.x, y: s.y + i });
  return cells;
}

export interface Cell extends Pos {
  readonly key: CellKey;
  readonly letter: string;
  /** The slots that cross this cell (one or two). */
  readonly slots: readonly number[];
}

/** Lookups for one puzzle. Cheap to build, so it's rebuilt rather than stored. */
export interface MoldIndex {
  readonly puzzle: MpPuzzle;
  /** Every letter cell, by row and then column. */
  readonly cells: ReadonlyMap<CellKey, Cell>;
  readonly slotByWord: ReadonlyMap<string, MpSlot>;
  readonly slotKeys: readonly (readonly CellKey[])[];
}

export function indexMold(puzzle: MpPuzzle): MoldIndex {
  const found = new Map<CellKey, { x: number; y: number; letter: string; slots: number[] }>();
  const slotKeys: CellKey[][] = [];
  for (const s of puzzle.slots) {
    const keys: CellKey[] = [];
    slotCells(s).forEach((c, i) => {
      const key = cellKey(c.x, c.y);
      keys.push(key);
      const cell = found.get(key);
      if (cell === undefined) found.set(key, { ...c, letter: s.word[i]!, slots: [s.slot] });
      else cell.slots.push(s.slot);
    });
    slotKeys.push(keys);
  }
  const sorted = [...found.entries()].sort(([, a], [, b]) => a.y - b.y || a.x - b.x);
  return {
    puzzle,
    cells: new Map(sorted.map(([key, c]) => [key, { key, ...c }])),
    slotByWord: new Map(puzzle.slots.map((s) => [s.word, s])),
    slotKeys,
  };
}

/** Slots outside `done` whose every cell is in `filled`, in slot order. */
export function newlyComplete(index: MoldIndex, filled: ReadonlySet<CellKey>, done: ReadonlySet<number>): MpSlot[] {
  return index.puzzle.slots.filter((s) => !done.has(s.slot) && index.slotKeys[s.slot]!.every((k) => filled.has(k)));
}

/** Letter cells not in `filled`, by row and then column. */
export function emptyCells(index: MoldIndex, filled: ReadonlySet<CellKey>): Cell[] {
  return [...index.cells.values()].filter((c) => !filled.has(c.key));
}

// ---------------------------------------------------------------------------
// Hints (DESIGN.md §3.1)
// ---------------------------------------------------------------------------

/** Letters one Spark Shower reveals, at most. */
export const SPARK_SHOWER_CELLS = 5;

function pick<T>(items: readonly T[], rand: Rand): T {
  return items[Math.min(items.length - 1, Math.floor(rand() * items.length))]!;
}

/** Hammer Strike: one random empty cell, or `null` if none is left. */
export function hammerCell(index: MoldIndex, filled: ReadonlySet<CellKey>, rand: Rand): Cell | null {
  const empty = emptyCells(index, filled);
  return empty.length === 0 ? null : pick(empty, rand);
}

/**
 * Spark Shower: up to {@link SPARK_SHOWER_CELLS} empty cells, spread across
 * slots. Each pick goes to a slot that no earlier pick touched, while there
 * is one with an empty cell left; then any slot may get a second.
 */
export function sparkCells(index: MoldIndex, filled: ReadonlySet<CellKey>, rand: Rand, count = SPARK_SHOWER_CELLS): Cell[] {
  const taken = new Set(filled);
  const touched = new Set<number>();
  const chosen: Cell[] = [];
  while (chosen.length < count) {
    const open = index.puzzle.slots.filter((s) => index.slotKeys[s.slot]!.some((k) => !taken.has(k)));
    if (open.length === 0) break;
    const fresh = open.filter((s) => !touched.has(s.slot));
    if (fresh.length === 0) touched.clear();
    const slot = pick(fresh.length > 0 ? fresh : open, rand);
    const key = pick(
      index.slotKeys[slot.slot]!.filter((k) => !taken.has(k)),
      rand,
    );
    const cell = index.cells.get(key)!;
    taken.add(key);
    chosen.push(cell);
    for (const s of cell.slots) touched.add(s);
  }
  return chosen;
}

// ---------------------------------------------------------------------------
// Embers (DESIGN.md §3.2 item 2)
// ---------------------------------------------------------------------------

/**
 * Ember cells for a new round: none about 4 rounds in 5, otherwise one, or
 * occasionally two. Two embers never share a slot, so forging one word
 * collects at most one (`CLAIMED.pickup` names a single hint).
 */
export function placeEmbers(index: MoldIndex, rand: Rand): Pos[] {
  if (rand() >= PICKUP_CHANCE) return [];
  const wanted = rand() < DOUBLE_PICKUP_CHANCE ? 2 : 1;
  const cells = [...index.cells.values()];
  const first = pick(cells, rand);
  const chosen: Cell[] = [first];
  if (wanted === 2) {
    const apart = cells.filter((c) => !c.slots.some((s) => first.slots.includes(s)));
    if (apart.length > 0) chosen.push(pick(apart, rand));
  }
  return chosen.map(({ x, y }) => ({ x, y }));
}

/**
 * The hint an ember turns into for a player of `level`: about 70% Hammer
 * Strike, 25% Chisel, 5% Spark Shower; a type they haven't unlocked becomes
 * a Hammer Strike (the same weights as the campaign, src/rules/pickups.ts).
 */
export function emberKind(rand: Rand, level: number): HintKind {
  const t = rand();
  let kind: HintKind = t < HAMMER_THRESHOLD ? "hammer" : t < CHISEL_THRESHOLD ? "chisel" : "sparks";
  if (level < HINT_UNLOCK_LEVEL[kind]) kind = "hammer";
  return kind;
}

// ---------------------------------------------------------------------------
// Anvil
// ---------------------------------------------------------------------------

/**
 * The puzzle's letters in a random order that doesn't spell any of
 * `avoid` (the grid words that use every letter). Falls back to the
 * puzzle's own order, which never spells its longest word.
 */
export function shuffleLetters(letters: string, rand: Rand, avoid: ReadonlySet<string>): string {
  for (let attempt = 0; attempt < 8; attempt++) {
    const tiles = [...letters];
    for (let i = tiles.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [tiles[i], tiles[j]] = [tiles[j]!, tiles[i]!];
    }
    const out = tiles.join("");
    if (!avoid.has(out)) return out;
  }
  return letters;
}
