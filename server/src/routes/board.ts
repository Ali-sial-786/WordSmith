/**
 * The Forge Board (shared/forge-board.md; rules in src/rules/board.ts,
 * orders.ts and rewards.ts):
 *
 * - `GET /v1/me/board` → `{date, week, stoke, orders, trials, gifts}`
 * - `POST /v1/me/stoke/claim` → `{profile, board, reward}`; `409 already_claimed`
 * - `POST /v1/me/orders/swap {slot}` → `{profile, board, reward}`;
 *   `400 invalid_slot`, `409 swap_used`, `409 order_done`
 * - `POST /v1/me/orders/claim {slot}` (`d0`–`d2`, `w0`, `w1` or `chest`) →
 *   `{profile, board, reward}`; `400 invalid_slot`, `409 not_done`, `409 already_claimed`
 * - `POST /v1/me/trials/claim` → `{profile, board, reward}`; `409 no_prize`, `409 already_claimed`
 * - `POST /v1/me/gifts/claim` → `{profile, board, reward}`; `409 nothing_to_claim`
 * - `POST /v1/friends/:id/gift` → `{ok: true}`; `400 cannot_gift_self`,
 *   `404 not_friends`, `409 already_sent`. The friend gets a notification.
 *
 * All need a set-up account. A claim's `reward` is as granted (locked hint
 * types swapped to Hammer Strikes); `board` is a fresh `GET /v1/me/board`.
 * `409 sync_conflict` if the profile kept changing meanwhile (retry).
 */

import { loadAccount, profileBody, type Account } from "../db/accounts";
import {
  chestMarks,
  giftMarks,
  loadBoard,
  orderMarks,
  sendGift,
  stokeMarks,
  swapMarks,
  trialMarks,
  writeClaim,
  type ClaimMarks,
} from "../db/board";
import { linkBetween } from "../db/friends";
import { pushTargetOf } from "../db/push";
import { ApiError, json, readJsonObject } from "../http";
import { fcmSender } from "../push/fcm";
import { pushGift } from "../push/gift";
import { boardBody, giftsToClaim, GIFT_REWARD, isoWeek, lastWeekResult, previousWeek, STOKE_TRACK, stokeView, type BoardData } from "../rules/board";
import { utcDate } from "../rules/daily";
import {
  chestReady,
  CHEST_REWARD,
  CHEST_SLOT,
  dailyOrder,
  dailyPeriod,
  isDailySlot,
  isDone,
  isOrderSlot,
  orderReward,
  ordersState,
  swapKind,
  weeklyPeriod,
  DAILY_SLOTS,
} from "../rules/orders";
import { fnv1a32, mulberry32 } from "../rules/pickups";
import { grantReward, NO_REWARD, reward, type Reward } from "../rules/rewards";
import { requireSetUp, type AuthedContext } from "./context";

/** Attempts before giving up on a profile that keeps changing underneath us. */
const MAX_ATTEMPTS = 3;

export async function getBoard(c: AuthedContext): Promise<Response> {
  const account = await requireSetUp(c);
  return json(boardBody(await loadBoard(c.env.DB, account, c.now)));
}

/** What a claim takes, decided from the player's account and board as read. */
interface ClaimPlan {
  readonly reward: Reward;
  /** `xp_events.ref` for its XP. */
  readonly ref: string;
  readonly marks: ClaimMarks;
}

/**
 * Runs a claim: reads the account and then the board, lets `decide` pick
 * the reward (or throw the claim's error), and writes it optimistically,
 * re-reading and deciding again if the profile changed meanwhile.
 */
async function claim(c: AuthedContext, decide: (account: Account, board: BoardData) => ClaimPlan): Promise<Response> {
  const db = c.env.DB;
  for (let attempt = 1; ; attempt++) {
    const account = await requireSetUp(c);
    const plan = decide(account, await loadBoard(db, account, c.now));
    const grant = grantReward(account.totalXp, plan.reward);
    if (await writeClaim(db, account, { grant, ref: plan.ref, marks: plan.marks }, c.now)) {
      const fresh = (await loadAccount(db, account.id))!;
      return json({ profile: profileBody(fresh), board: boardBody(await loadBoard(db, fresh, c.now)), reward: grant.granted });
    }
    if (attempt === MAX_ATTEMPTS) throw new ApiError(409, "sync_conflict", "Your profile changed meanwhile; try again");
  }
}

/** The `{slot}` of a swap or claim body. */
async function slotOf(c: AuthedContext): Promise<unknown> {
  return (await readJsonObject(c.request)).slot;
}

export async function postStokeClaim(c: AuthedContext): Promise<Response> {
  return claim(c, (_, board) => {
    const today = utcDate(c.now);
    const stoke = stokeView(board.stoke, today);
    if (stoke.claimedToday) throw new ApiError(409, "already_claimed", "Today's Stoke is already claimed");
    return { reward: STOKE_TRACK[stoke.day - 1]!, ref: `stoke:${today}`, marks: stokeMarks(today) };
  });
}

export async function postOrderSwap(c: AuthedContext): Promise<Response> {
  const slot = await slotOf(c);
  if (!isDailySlot(slot)) throw new ApiError(400, "invalid_slot", "Expected {slot: \"d0\" | \"d1\" | \"d2\"}");
  return claim(c, (account, board) => {
    const date = utcDate(c.now);
    const orders = ordersState(date, isoWeek(date), board.orders);
    if (orders.swapUsed) throw new ApiError(409, "swap_used", "Today's swap is used");
    const index = DAILY_SLOTS.indexOf(slot);
    const order = orders.daily[index]!;
    if (order.claimed || isDone(order)) throw new ApiError(409, "order_done", "That order is already finished");
    // Random, but the same on a retry: seeded by the player and the day.
    const rand = mulberry32(fnv1a32(`swap:${account.id}:${date}`));
    const kind = swapKind(
      orders.daily.map((o) => o.kind),
      index,
      rand,
    );
    return { reward: NO_REWARD, ref: `swap:${date}`, marks: swapMarks(date, slot, dailyOrder(slot, kind)) };
  });
}

export async function postOrderClaim(c: AuthedContext): Promise<Response> {
  const slot = await slotOf(c);
  if (slot !== CHEST_SLOT && !isOrderSlot(slot)) {
    throw new ApiError(400, "invalid_slot", "Expected {slot}: d0, d1, d2, w0, w1 or chest");
  }
  return claim(c, (_, board) => {
    const date = utcDate(c.now);
    const week = isoWeek(date);
    const orders = ordersState(date, week, board.orders);
    if (slot === CHEST_SLOT) {
      if (orders.chestClaimed) throw new ApiError(409, "already_claimed", "Today's chest is already open");
      if (!chestReady(orders)) throw new ApiError(409, "not_done", "Claim all three daily orders first");
      return { reward: CHEST_REWARD, ref: `chest:${date}`, marks: chestMarks(date) };
    }
    const order = [...orders.daily, ...orders.weekly].find((o) => o.slot === slot)!;
    if (order.claimed) throw new ApiError(409, "already_claimed", "That order is already claimed");
    if (!isDone(order)) throw new ApiError(409, "not_done", "That order isn't finished yet");
    const period = isDailySlot(slot) ? dailyPeriod(date) : weeklyPeriod(week);
    return { reward: orderReward(slot), ref: `order:${period}:${slot}`, marks: orderMarks(period, slot) };
  });
}

export async function postTrialsClaim(c: AuthedContext): Promise<Response> {
  return claim(c, (account, board) => {
    const week = previousWeek(utcDate(c.now));
    const last = lastWeekResult(board.players, account.id);
    if (last?.reward == null) throw new ApiError(409, "no_prize", "No prize from last week's Trials");
    if (board.trialClaimed) throw new ApiError(409, "already_claimed", "Last week's prize is already claimed");
    return { reward: last.reward, ref: `trial:${week}`, marks: trialMarks(week, c.now) };
  });
}

export async function postGiftsClaim(c: AuthedContext): Promise<Response> {
  return claim(c, (_, board) => {
    const n = giftsToClaim(board.pendingGifts.length, board.claimedToday);
    if (n === 0) throw new ApiError(409, "nothing_to_claim", "No gifts to collect today");
    const ids = board.pendingGifts.slice(0, n).map((g) => g.id);
    return { reward: reward(0, { hammer: GIFT_REWARD.hints.hammer * n }), ref: `gifts:${utcDate(c.now)}`, marks: giftMarks(ids, c.now) };
  });
}

/** Today's free Hammer Strike for a friend, with a notification to their phones (best effort, after the answer). */
export async function postFriendGift(c: AuthedContext): Promise<Response> {
  const account = await requireSetUp(c);
  const to = c.params.id ?? "";
  if (to === account.id) throw new ApiError(400, "cannot_gift_self", "You can't send yourself a gift");
  const db = c.env.DB;
  if (!(await sendGift(db, account.id, to, c.now))) {
    if ((await linkBetween(db, account.id, to)) !== "friends") throw new ApiError(404, "not_friends", "Gifts go to accepted friends");
    throw new ApiError(409, "already_sent", "You've already sent them a gift today");
  }
  const push = fcmSender(c.env);
  if (push !== null) {
    const notice = { from: account.id, fromUsername: account.username };
    c.ctx.waitUntil(
      pushTargetOf(db, to, account.id)
        .then(({ tokens, nickname }) => pushGift(push, db, tokens, { ...notice, nickname }))
        .catch((err: unknown) => console.error("gift notification failed", err)),
    );
  }
  return json({ ok: true });
}
