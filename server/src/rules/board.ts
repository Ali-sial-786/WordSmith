/**
 * The Forge Board (shared/forge-board.md): the Daily Stoke, the Weekly
 * Trials, gifts, ISO weeks, and the `GET /v1/me/board` body. Work Orders
 * are in orders.ts and rewards in rewards.ts. Pure: src/db/board.ts reads
 * the rows and src/routes/board.ts writes what these decide.
 */

import { addDays, utcDate } from "./daily";
import {
  chestReady,
  CHEST_REWARD,
  FRIENDS_KINDS,
  orderReward,
  ordersState,
  swapAvailable,
  type OrderKind,
  type OrderRow,
  type OrderSlot,
  type OrderState,
} from "./orders";
import { levelFromTotalXp } from "./progression";
import { reward, type Reward } from "./rewards";

const DAY_MS = 86_400_000;

// ---------------------------------------------------------------------------
// Weeks: ISO weeks, Monday 00:00 UTC, written YYYY-Www
// ---------------------------------------------------------------------------

/** Days since Monday (0–6) of a `YYYY-MM-DD` date. */
function weekday(date: string): number {
  return (new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7;
}

/** The Monday that starts `date`'s ISO week. */
export function weekStart(date: string): string {
  return addDays(date, -weekday(date));
}

/**
 * `date`'s ISO week, `YYYY-Www`: the year is that of the week's Thursday,
 * and week 1 is the one with the year's first Thursday. migrations/0005
 * works out the same in SQL for `weekly_xp`.
 */
export function isoWeek(date: string): string {
  const thursday = addDays(weekStart(date), 3);
  const year = thursday.slice(0, 4);
  const dayOfYear = (Date.parse(`${thursday}T00:00:00Z`) - Date.parse(`${year}-01-01T00:00:00Z`)) / DAY_MS;
  return `${year}-W${String(Math.floor(dayOfYear / 7) + 1).padStart(2, "0")}`;
}

/** When `date` ends: the next midnight UTC, epoch ms. */
export function dayEndsAt(date: string): number {
  return Date.parse(`${addDays(date, 1)}T00:00:00Z`);
}

/** When `date`'s week ends: the next Monday 00:00 UTC, epoch ms. */
export function weekEndsAt(date: string): number {
  return Date.parse(`${addDays(weekStart(date), 7)}T00:00:00Z`);
}

/** The ISO week before `date`'s. */
export function previousWeek(date: string): string {
  return isoWeek(addDays(date, -7));
}

// ---------------------------------------------------------------------------
// The Daily Stoke
// ---------------------------------------------------------------------------

/** The 7-day track, as configured (before any swap to Hammer Strikes). */
export const STOKE_TRACK: readonly Reward[] = [
  reward(15),
  reward(0, { hammer: 1 }),
  reward(25),
  reward(0, { chisel: 1 }),
  reward(35),
  reward(0, { hammer: 2 }),
  reward(50, { sparks: 1 }),
];

/** `profiles.stoke_claims` and `profiles.stoke_last`. */
export interface StokeState {
  /** Claims ever made. */
  readonly claims: number;
  /** The UTC date of the last claim, or `null`. */
  readonly last: string | null;
}

export interface StokeView {
  /** 1–7: the step today's claim gives, or the one already claimed today. */
  readonly day: number;
  readonly claimedToday: boolean;
}

/** Missing days never resets the track: each claim takes the next step, and day 7 goes back to day 1. */
export function stokeView(s: StokeState, today: string): StokeView {
  const claimedToday = s.last === today && s.claims > 0;
  return { day: ((claimedToday ? s.claims - 1 : s.claims) % STOKE_TRACK.length) + 1, claimedToday };
}

// ---------------------------------------------------------------------------
// The Weekly Trials
// ---------------------------------------------------------------------------

/** Prizes for 1st, 2nd and 3rd last week (when at least two of us earned XP). */
export const TRIAL_PRIZES: readonly Reward[] = [reward(100, { sparks: 1 }), reward(50, { chisel: 1 }), reward(0, { hammer: 2 })];

/** Me or one of my accepted friends, with XP this week and last. */
export interface TrialPlayer {
  readonly id: string;
  readonly username: string;
  readonly avatar: string | null;
  /** Lifetime XP, for the level. */
  readonly totalXp: number;
  readonly weekXp: number;
  readonly lastWeekXp: number;
}

export interface Standing {
  readonly id: string;
  readonly username: string;
  readonly avatar: string | null;
  readonly level: number;
  /** XP this week. */
  readonly xp: number;
  readonly me: boolean;
}

/** Everyone by XP this week, high first; ties by username, ignoring case. Players with 0 XP are listed too. */
export function standings(players: readonly TrialPlayer[], me: string): Standing[] {
  return [...players]
    .sort((a, b) => b.weekXp - a.weekXp || a.username.toLowerCase().localeCompare(b.username.toLowerCase()) || (a.id < b.id ? -1 : 1))
    .map((p) => ({ id: p.id, username: p.username, avatar: p.avatar, level: levelFromTotalXp(p.totalXp), xp: p.weekXp, me: p.id === me }));
}

export interface LastWeekResult {
  /** 1-based among the players with XP last week; equal XP shares a place. */
  readonly place: number;
  /** Players (me and my current friends) with XP last week. */
  readonly of: number;
  /** The prize, or `null` when there's none. */
  readonly reward: Reward | null;
}

/**
 * My result last week, or `null` if I earned no XP then. There's a prize
 * only when at least two of us earned XP and I placed in the top 3.
 */
export function lastWeekResult(players: readonly TrialPlayer[], me: string): LastWeekResult | null {
  const mine = players.find((p) => p.id === me)?.lastWeekXp ?? 0;
  if (mine <= 0) return null;
  const earned = players.filter((p) => p.lastWeekXp > 0);
  const place = 1 + earned.filter((p) => p.lastWeekXp > mine).length;
  const prize = earned.length >= 2 ? TRIAL_PRIZES[place - 1] ?? null : null;
  return { place, of: earned.length, reward: prize };
}

// ---------------------------------------------------------------------------
// Gifts
// ---------------------------------------------------------------------------

/** Gifts a player may collect per UTC day. */
export const GIFT_CLAIM_LIMIT = 5;
/** A gift can be collected for this long after it was sent. */
export const GIFT_TTL_MS = 7 * DAY_MS;
/** The board lists at most this many pending gifts. */
export const GIFT_PENDING_SHOWN = 20;
/** Each gift is one Hammer Strike. */
export const GIFT_REWARD: Reward = reward(0, { hammer: 1 });

/** How many of `pending` gifts a claim collects, after `claimedToday` today. */
export function giftsToClaim(pending: number, claimedToday: number): number {
  return Math.max(0, Math.min(pending, GIFT_CLAIM_LIMIT - claimedToday));
}

/** A gift waiting for me. */
export interface PendingGift {
  readonly id: number;
  readonly from: { readonly id: string; readonly username: string; readonly avatar: string | null };
  readonly sentAt: number;
}

// ---------------------------------------------------------------------------
// GET /v1/me/board
// ---------------------------------------------------------------------------

/** Everything the board is made from, as read from D1. */
export interface BoardData {
  readonly uid: string;
  readonly now: number;
  readonly stoke: StokeState;
  /** My `work_orders` rows for today and this week. */
  readonly orders: readonly OrderRow[];
  /** Me and my accepted friends. */
  readonly players: readonly TrialPlayer[];
  /** Whether I've claimed last week's prize. */
  readonly trialClaimed: boolean;
  /** Oldest first, at most {@link GIFT_PENDING_SHOWN}. */
  readonly pendingGifts: readonly PendingGift[];
  /** Friends I've sent a gift to today. */
  readonly sentToday: readonly string[];
  /** Gifts I've collected today. */
  readonly claimedToday: number;
}

export interface OrderBody {
  readonly slot: OrderSlot;
  readonly kind: OrderKind;
  readonly target: number;
  readonly progress: number;
  readonly letter: string | null;
  readonly friends: boolean;
  readonly reward: Reward;
  readonly claimed: boolean;
}

export interface BoardBody {
  readonly date: string;
  readonly week: string;
  readonly stoke: StokeView & { readonly track: readonly Reward[] };
  readonly orders: {
    readonly daily: readonly OrderBody[];
    readonly weekly: readonly OrderBody[];
    readonly chest: { readonly reward: Reward; readonly ready: boolean; readonly claimed: boolean };
    readonly swapAvailable: boolean;
    readonly dailyEndsAt: number;
    readonly weeklyEndsAt: number;
  };
  readonly trials: {
    readonly week: string;
    readonly endsAt: number;
    readonly standings: readonly Standing[];
    readonly lastWeek: (LastWeekResult & { readonly week: string; readonly claimed: boolean }) | null;
  };
  readonly gifts: {
    readonly pending: readonly PendingGift[];
    readonly sentToday: readonly string[];
    readonly claimedToday: number;
    readonly claimLimit: number;
  };
}

function orderBody(o: OrderState): OrderBody {
  return {
    slot: o.slot,
    kind: o.kind,
    target: o.target,
    progress: o.progress,
    letter: o.letter,
    friends: FRIENDS_KINDS.has(o.kind),
    reward: orderReward(o.slot),
    claimed: o.claimed,
  };
}

/** The `GET /v1/me/board` body. Rewards are shown as configured; claims report them as granted. */
export function boardBody(d: BoardData): BoardBody {
  const date = utcDate(d.now);
  const week = isoWeek(date);
  const orders = ordersState(date, week, d.orders);
  const last = lastWeekResult(d.players, d.uid);
  return {
    date,
    week,
    stoke: { ...stokeView(d.stoke, date), track: STOKE_TRACK },
    orders: {
      daily: orders.daily.map(orderBody),
      weekly: orders.weekly.map(orderBody),
      chest: { reward: CHEST_REWARD, ready: chestReady(orders), claimed: orders.chestClaimed },
      swapAvailable: swapAvailable(orders),
      dailyEndsAt: dayEndsAt(date),
      weeklyEndsAt: weekEndsAt(date),
    },
    trials: {
      week,
      endsAt: weekEndsAt(date),
      standings: standings(d.players, d.uid),
      lastWeek: last === null ? null : { week: previousWeek(date), ...last, claimed: d.trialClaimed },
    },
    gifts: {
      pending: d.pendingGifts,
      sentToday: d.sentToday,
      claimedToday: d.claimedToday,
      claimLimit: GIFT_CLAIM_LIMIT,
    },
  };
}
