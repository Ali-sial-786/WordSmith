/**
 * Work Orders (shared/forge-board.md "Work Orders"): three daily orders,
 * the same for everyone each day, and two weekly ones. Pure: which orders a
 * day or a week has, the daily swap, the rewards, and what an accepted play
 * counts towards ({@link orderCounts}). src/db/orders.ts adds the counts to
 * the player's orders in the same batch that writes the play.
 */

import type { Rand } from "./mold";
import { fnv1a32, mulberry32 } from "./pickups";
import { reward, type Reward } from "./rewards";

export type OrderKind =
  | "solo_puzzles"
  | "bonus_words"
  | "words"
  | "long_words"
  | "daily"
  | "no_hints"
  | "coop_rounds"
  | "vs_series"
  | "letter_hunt";

/** The daily orders are drawn from these, in this order (the shuffle depends on it). */
export const DAILY_POOL: readonly OrderKind[] = [
  "solo_puzzles",
  "bonus_words",
  "words",
  "long_words",
  "daily",
  "no_hints",
  "coop_rounds",
  "vs_series",
];

/** Kinds that need other players. A day never has two of them. */
export const FRIENDS_KINDS: ReadonlySet<OrderKind> = new Set<OrderKind>(["coop_rounds", "vs_series"]);

/** Targets of the daily kinds. */
export const DAILY_TARGETS: Readonly<Record<Exclude<OrderKind, "letter_hunt">, number>> = {
  solo_puzzles: 3,
  bonus_words: 10,
  words: 40,
  long_words: 3,
  daily: 1,
  no_hints: 1,
  coop_rounds: 1,
  vs_series: 1,
};
export const LETTER_HUNT_TARGET = 40;
export const WEEKLY_SOLO_TARGET = 15;

/** `long_words` counts forged words of at least this many letters. */
export const LONG_WORD_LENGTH = 6;

/** The week's `letter_hunt` letter is one of these. */
export const HUNT_LETTERS = "RTNSLDGPMBHCKFWY";

export type DailySlot = "d0" | "d1" | "d2";
export type WeeklySlot = "w0" | "w1";
export type OrderSlot = DailySlot | WeeklySlot;
export const DAILY_SLOTS: readonly DailySlot[] = ["d0", "d1", "d2"];
export const WEEKLY_SLOTS: readonly WeeklySlot[] = ["w0", "w1"];

export function isDailySlot(value: unknown): value is DailySlot {
  return typeof value === "string" && (DAILY_SLOTS as readonly string[]).includes(value);
}

export function isOrderSlot(value: unknown): value is OrderSlot {
  return isDailySlot(value) || (typeof value === "string" && (WEEKLY_SLOTS as readonly string[]).includes(value));
}

/** One order as configured: what it asks for. Progress and claims are the player's. */
export interface OrderSpec {
  readonly slot: OrderSlot;
  readonly kind: OrderKind;
  readonly target: number;
  /** Only for `letter_hunt`: the letter, A–Z. */
  readonly letter: string | null;
}

// ---------------------------------------------------------------------------
// Choosing the orders
// ---------------------------------------------------------------------------

/** The first three of `kinds` in order, skipping a second `friends` kind. */
function firstThree(kinds: readonly OrderKind[]): OrderKind[] {
  const out: OrderKind[] = [];
  for (const kind of kinds) {
    if (out.length === 3) break;
    if (FRIENDS_KINDS.has(kind) && out.some((k) => FRIENDS_KINDS.has(k))) continue;
    out.push(kind);
  }
  return out;
}

/**
 * The day's three kinds, the same for everyone: the daily pool shuffled
 * (Fisher–Yates) with `mulberry32(fnv1a32("orders:" + date))`, then the
 * first three, skipping a second `friends` kind.
 */
export function dailyKinds(date: string): OrderKind[] {
  const rand = mulberry32(fnv1a32(`orders:${date}`));
  const pool = [...DAILY_POOL];
  for (let i = pool.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [pool[i], pool[j]] = [pool[j]!, pool[i]!];
  }
  return firstThree(pool);
}

/** A daily order of `kind` in `slot`. */
export function dailyOrder(slot: DailySlot, kind: OrderKind): OrderSpec {
  return { slot, kind, target: kind === "letter_hunt" ? LETTER_HUNT_TARGET : DAILY_TARGETS[kind], letter: null };
}

/** The day's three orders before any swap. */
export function dailyOrders(date: string): OrderSpec[] {
  return dailyKinds(date).map((kind, i) => dailyOrder(DAILY_SLOTS[i]!, kind));
}

/** The week's `letter_hunt` letter: `HUNT_LETTERS[fnv1a32("letter:" + week) mod 16]`. */
export function weeklyLetter(week: string): string {
  return HUNT_LETTERS[fnv1a32(`letter:${week}`) % HUNT_LETTERS.length]!;
}

/** The week's two orders: `w0` a `letter_hunt`, `w1` 15 campaign puzzles. */
export function weeklyOrders(week: string): OrderSpec[] {
  return [
    { slot: "w0", kind: "letter_hunt", target: LETTER_HUNT_TARGET, letter: weeklyLetter(week) },
    { slot: "w1", kind: "solo_puzzles", target: WEEKLY_SOLO_TARGET, letter: null },
  ];
}

/**
 * The kind a swap puts in place of `current[replaced]`: a random pool kind
 * that isn't one of today's three (the replaced one included), and isn't a
 * second `friends` kind beside the two that stay.
 */
export function swapKind(current: readonly OrderKind[], replaced: number, rand: Rand): OrderKind {
  const staying = current.filter((_, i) => i !== replaced);
  const friendsStaying = staying.some((k) => FRIENDS_KINDS.has(k));
  const candidates = DAILY_POOL.filter((k) => !current.includes(k) && !(friendsStaying && FRIENDS_KINDS.has(k)));
  return candidates[Math.floor(rand() * candidates.length)]!;
}

// ---------------------------------------------------------------------------
// Rewards
// ---------------------------------------------------------------------------

export const DAILY_ORDER_REWARD: Reward = reward(20, { hammer: 1 });
/** The daily chest, once all three daily orders are claimed. */
export const CHEST_REWARD: Reward = reward(30, { chisel: 1 });
export const LETTER_HUNT_REWARD: Reward = reward(100, { sparks: 1 });
export const WEEKLY_SOLO_REWARD: Reward = reward(60, { chisel: 1 });

/** An order's reward, as configured (before any swap to Hammer Strikes). */
export function orderReward(slot: OrderSlot): Reward {
  if (slot === "w0") return LETTER_HUNT_REWARD;
  if (slot === "w1") return WEEKLY_SOLO_REWARD;
  return DAILY_ORDER_REWARD;
}

// ---------------------------------------------------------------------------
// Counting
// ---------------------------------------------------------------------------

/** Facts about plays the server just accepted. Everything is optional (0 or none). */
export interface PlayFacts {
  /** Campaign puzzles accepted by solo sync. */
  readonly soloPuzzles?: number;
  /** …of which used no hints. */
  readonly noHintPuzzles?: number;
  /** Daily Commission completions that weren't repeats (catch-up days too). */
  readonly dailies?: number;
  /** Co-op rounds the player took part in. */
  readonly coopRounds?: number;
  /** Versus series the player finished. */
  readonly vsSeries?: number;
  /** Valid bonus words found. */
  readonly bonusWords?: number;
  /**
   * Grid words the player forged: typed in solo sync or the daily, claimed
   * in co-op, claimed on their own Versus mold. Upper-case A–Z.
   */
  readonly forged?: readonly string[];
}

/** How much a play adds to each kind of order. Kinds it doesn't count towards are left out. */
export type OrderCounts = Partial<Record<OrderKind, number>>;

/** Adds facts together (a sync's entries, say). */
export function addFacts(a: PlayFacts, b: PlayFacts): PlayFacts {
  const n = (x?: number, y?: number) => (x ?? 0) + (y ?? 0);
  return {
    soloPuzzles: n(a.soloPuzzles, b.soloPuzzles),
    noHintPuzzles: n(a.noHintPuzzles, b.noHintPuzzles),
    dailies: n(a.dailies, b.dailies),
    coopRounds: n(a.coopRounds, b.coopRounds),
    vsSeries: n(a.vsSeries, b.vsSeries),
    bonusWords: n(a.bonusWords, b.bonusWords),
    forged: [...(a.forged ?? []), ...(b.forged ?? [])],
  };
}

/**
 * What `facts` add to each kind of order, with `letter` the week's
 * `letter_hunt` letter. `solo_puzzles` counts for the daily and the weekly
 * order alike.
 */
export function orderCounts(facts: PlayFacts, letter: string): OrderCounts {
  const forged = facts.forged ?? [];
  const all: Record<OrderKind, number> = {
    solo_puzzles: facts.soloPuzzles ?? 0,
    bonus_words: facts.bonusWords ?? 0,
    words: forged.length,
    long_words: forged.filter((w) => w.length >= LONG_WORD_LENGTH).length,
    daily: facts.dailies ?? 0,
    no_hints: facts.noHintPuzzles ?? 0,
    coop_rounds: facts.coopRounds ?? 0,
    vs_series: facts.vsSeries ?? 0,
    letter_hunt: forged.filter((w) => w.includes(letter)).length,
  };
  const counts: OrderCounts = {};
  for (const [kind, n] of Object.entries(all) as [OrderKind, number][]) if (n > 0) counts[kind] = n;
  return counts;
}

export function hasCounts(counts: OrderCounts): boolean {
  return Object.values(counts).some((n) => n > 0);
}

/** Progress after adding `counts` to an order: it stops at the target. */
export function advance(order: Pick<OrderSpec, "kind" | "target">, progress: number, counts: OrderCounts): number {
  return Math.min(order.target, progress + (counts[order.kind] ?? 0));
}

// ---------------------------------------------------------------------------
// A player's orders
// ---------------------------------------------------------------------------

/** `work_orders.period` for a day's orders: `d:<date>`. */
export function dailyPeriod(date: string): string {
  return `d:${date}`;
}

/** `work_orders.period` for a week's orders: `w:<week>`. */
export function weeklyPeriod(week: string): string {
  return `w:${week}`;
}

/** Rows in a day's period that aren't orders: the swap used (`kind` = the slot swapped) and the chest claimed. */
export const SWAP_SLOT = "swap";
export const CHEST_SLOT = "chest";

/** One stored `work_orders` row. */
export interface OrderRow {
  readonly period: string;
  readonly slot: string;
  readonly kind: string;
  readonly target: number;
  readonly progress: number;
  readonly letter: string | null;
  readonly claimed: boolean;
}

export interface OrderState extends OrderSpec {
  readonly progress: number;
  readonly claimed: boolean;
}

export interface OrdersState {
  readonly daily: readonly OrderState[];
  readonly weekly: readonly OrderState[];
  readonly swapUsed: boolean;
  readonly chestClaimed: boolean;
}

/**
 * A player's orders for `date` and `week` from their stored rows. Rows are
 * only made once something needs them, so a missing one is the configured
 * order with no progress.
 */
export function ordersState(date: string, week: string, rows: readonly OrderRow[]): OrdersState {
  const day = dailyPeriod(date);
  const wk = weeklyPeriod(week);
  const find = (period: string, slot: string) => rows.find((r) => r.period === period && r.slot === slot);
  const fromRow = (spec: OrderSpec, period: string): OrderState => {
    const row = find(period, spec.slot);
    if (row === undefined) return { ...spec, progress: 0, claimed: false };
    return { slot: spec.slot, kind: row.kind as OrderKind, target: row.target, letter: row.letter, progress: row.progress, claimed: row.claimed };
  };
  return {
    daily: dailyOrders(date).map((spec) => fromRow(spec, day)),
    weekly: weeklyOrders(week).map((spec) => fromRow(spec, wk)),
    swapUsed: find(day, SWAP_SLOT) !== undefined,
    chestClaimed: find(day, CHEST_SLOT)?.claimed ?? false,
  };
}

export function isDone(order: OrderState): boolean {
  return order.progress >= order.target;
}

/** The chest opens once all three daily orders are claimed. */
export function chestReady(state: OrdersState): boolean {
  return state.daily.every((o) => o.claimed);
}

/** A swap is left today, and some daily order is still unfinished and unclaimed. */
export function swapAvailable(state: OrdersState): boolean {
  return !state.swapUsed && state.daily.some((o) => !o.claimed && !isDone(o));
}
