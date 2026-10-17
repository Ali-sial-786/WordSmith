/**
 * D1 queries for the Forge Board (shared/forge-board.md,
 * migrations/0005_forge_board.sql): reading everything `GET /v1/me/board`
 * shows, writing a claim, and sending gifts.
 *
 * A claim is written like a solo sync (src/db/sync.ts): one batch whose
 * statements only apply while `profiles.updated_at` still has the value
 * read, the last of which moves it on. The claim's own mark (the Stoke's
 * day, the order or chest claimed, the prize, the gifts collected, the
 * swap) is in that batch, and every write those marks depend on moves the
 * version too, so two claims at once can't both grant: the second finds
 * the version moved, re-reads, and sees the first.
 */

import type { Account } from "./accounts";
import { ensureOrderRows } from "./orders";
import { GIFT_PENDING_SHOWN, GIFT_TTL_MS, isoWeek, previousWeek, type BoardData, type PendingGift, type TrialPlayer } from "../rules/board";
import { addDays, utcDate } from "../rules/daily";
import { CHEST_SLOT, dailyPeriod, SWAP_SLOT, weeklyPeriod, type DailySlot, type OrderRow, type OrderSpec } from "../rules/orders";
import { HINT_KINDS } from "../rules/progression";
import type { RewardGrant } from "../rules/rewards";

/** Only true while the profile is still at the version we read (`?1` uid, `?2` version). */
const UNCHANGED = "EXISTS (SELECT 1 FROM profiles WHERE user_id = ?1 AND updated_at = ?2)";

/** Gift rows are dropped this long after they were sent (they expire after 7 days). */
const GIFT_ROWS_KEPT_DAYS = 14;

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/** Everything the board shows for `account` at `now`. Read after the account, so a claim can trust it. */
export async function loadBoard(db: D1Database, account: Account, now: number): Promise<BoardData> {
  const uid = account.id;
  const date = utcDate(now);
  const week = isoWeek(date);
  const [orders, players, trial, pending, sent, claimed] = await db.batch<Record<string, unknown>>([
    db
      .prepare("SELECT period, slot, kind, target, progress, letter, claimed FROM work_orders WHERE user_id = ?1 AND period IN (?2, ?3)")
      .bind(uid, dailyPeriod(date), weeklyPeriod(week)),
    db
      .prepare(
        `SELECT u.id, u.username, u.avatar, p.xp,
                COALESCE((SELECT xp FROM weekly_xp w WHERE w.user_id = u.id AND w.week = ?2), 0) AS week_xp,
                COALESCE((SELECT xp FROM weekly_xp w WHERE w.user_id = u.id AND w.week = ?3), 0) AS last_xp
           FROM users u JOIN profiles p ON p.user_id = u.id
          WHERE u.username IS NOT NULL
            AND (u.id = ?1 OR u.id IN (SELECT friend_id FROM friends WHERE user_id = ?1 AND status = 'accepted'))`,
      )
      .bind(uid, week, previousWeek(date)),
    db.prepare("SELECT COUNT(*) AS n FROM trial_claims WHERE user_id = ?1 AND week = ?2").bind(uid, previousWeek(date)),
    db
      .prepare(
        `SELECT g.id, g.from_user, u.username, u.avatar, g.sent_at
           FROM gifts g JOIN users u ON u.id = g.from_user
          WHERE g.to_user = ?1 AND g.claimed_at IS NULL AND g.sent_at > ?2
          ORDER BY g.sent_at, g.id LIMIT ?3`,
      )
      .bind(uid, now - GIFT_TTL_MS, GIFT_PENDING_SHOWN),
    db.prepare("SELECT to_user FROM gifts WHERE from_user = ?1 AND sent_date = ?2 ORDER BY id").bind(uid, date),
    db.prepare("SELECT COUNT(*) AS n FROM gifts WHERE to_user = ?1 AND claimed_at >= ?2").bind(uid, Date.parse(`${date}T00:00:00Z`)),
  ]);

  const orderRows: OrderRow[] = orders!.results.map((r) => ({
    period: r.period as string,
    slot: r.slot as string,
    kind: r.kind as string,
    target: r.target as number,
    progress: r.progress as number,
    letter: (r.letter as string | null) ?? null,
    claimed: r.claimed !== 0,
  }));
  const trialPlayers: TrialPlayer[] = players!.results.map((r) => ({
    id: r.id as string,
    username: r.username as string,
    avatar: (r.avatar as string | null) ?? null,
    totalXp: r.xp as number,
    weekXp: r.week_xp as number,
    lastWeekXp: r.last_xp as number,
  }));
  const pendingGifts: PendingGift[] = pending!.results.map((r) => ({
    id: r.id as number,
    from: { id: r.from_user as string, username: r.username as string, avatar: (r.avatar as string | null) ?? null },
    sentAt: r.sent_at as number,
  }));
  return {
    uid,
    now,
    stoke: { claims: account.stokeClaims, last: account.stokeLast },
    orders: orderRows,
    players: trialPlayers,
    trialClaimed: (trial!.results[0]?.n as number) > 0,
    pendingGifts,
    sentToday: sent!.results.map((r) => r.to_user as string),
    claimedToday: (claimed!.results[0]?.n as number | undefined) ?? 0,
  };
}

// ---------------------------------------------------------------------------
// Claims
// ---------------------------------------------------------------------------

/**
 * Statements marking what a claim took. They bind `?1` to the uid and `?2`
 * to the version read, and apply only while it's unchanged.
 */
export type ClaimMarks = (db: D1Database, uid: string, version: number) => D1PreparedStatement[];

export interface ClaimWrite {
  readonly grant: RewardGrant;
  /** `xp_events.ref` for the reward's XP (`source: "board"`). */
  readonly ref: string;
  readonly marks: ClaimMarks;
}

/**
 * Writes a claim in one transaction, if the profile is still at
 * `account.version`: its marks, the reward's XP (`xp_events`, so it counts
 * towards the Weekly Trials), the hints it and any level-ups gave, and the
 * profile. Returns false, writing nothing, if the profile changed (or a
 * concurrent claim already made one of the marks).
 */
export async function writeClaim(db: D1Database, account: Account, w: ClaimWrite, now: number): Promise<boolean> {
  const uid = account.id;
  const version = account.version;
  const { award, gained } = w.grant;
  const statements = [
    ...w.marks(db, uid, version),
    db
      .prepare(`INSERT INTO xp_events (user_id, source, amount, ref, created_at) SELECT ?1, 'board', ?3, ?4, ?5 WHERE ?3 > 0 AND ${UNCHANGED}`)
      .bind(uid, version, w.grant.granted.xp, w.ref, now),
    db
      .prepare(
        `INSERT INTO inventory (user_id, item, count)
         SELECT ?1, j.key, j.value FROM json_each(?3) AS j WHERE j.value > 0 AND ${UNCHANGED}
         ON CONFLICT (user_id, item) DO UPDATE SET count = count + excluded.count`,
      )
      .bind(uid, version, JSON.stringify(Object.fromEntries(HINT_KINDS.map((k) => [k, gained[k]])))),
    // Last, because it moves the version the statements above check.
    db
      .prepare("UPDATE profiles SET xp = ?3, level = ?4, updated_at = ?5 WHERE user_id = ?1 AND updated_at = ?2")
      .bind(uid, version, award.totalXp, award.level, Math.max(now, version + 1)),
  ];
  try {
    const results = await db.batch(statements);
    return results.at(-1)?.meta.changes === 1;
  } catch (err) {
    // A concurrent claim made the same mark first.
    if (String(err).includes("UNIQUE")) return false;
    throw err;
  }
}

/** Today's Daily Stoke step taken. */
export function stokeMarks(today: string): ClaimMarks {
  return (db, uid, version) => [
    db
      .prepare("UPDATE profiles SET stoke_claims = stoke_claims + 1, stoke_last = ?3 WHERE user_id = ?1 AND updated_at = ?2")
      .bind(uid, version, today),
  ];
}

/** A finished order claimed. Its row exists, since it has progress. */
export function orderMarks(period: string, slot: string): ClaimMarks {
  return (db, uid, version) => [
    db
      .prepare(`UPDATE work_orders SET claimed = 1 WHERE user_id = ?1 AND period = ?3 AND slot = ?4 AND ${UNCHANGED}`)
      .bind(uid, version, period, slot),
  ];
}

/** The day's chest opened (a second one fails on the primary key). */
export function chestMarks(date: string): ClaimMarks {
  return (db, uid, version) => [
    db
      .prepare(
        `INSERT INTO work_orders (user_id, period, slot, kind, target, progress, letter, claimed)
         SELECT ?1, ?3, ?4, '', 0, 0, NULL, 1 WHERE ${UNCHANGED}`,
      )
      .bind(uid, version, dailyPeriod(date), CHEST_SLOT),
  ];
}

/**
 * The day's swap: `slot` now holds `order` with no progress, and the swap
 * is used (a second one fails on the primary key). Makes the day's rows
 * first, so the other orders are kept as they were.
 */
export function swapMarks(date: string, slot: DailySlot, order: OrderSpec): ClaimMarks {
  return (db, uid, version) => [
    ...ensureOrderRows(db, uid, version, date),
    db
      .prepare(
        `UPDATE work_orders SET kind = ?5, target = ?6, progress = 0, letter = ?7, claimed = 0
          WHERE user_id = ?1 AND period = ?3 AND slot = ?4 AND ${UNCHANGED}`,
      )
      .bind(uid, version, dailyPeriod(date), slot, order.kind, order.target, order.letter),
    db
      .prepare(
        `INSERT INTO work_orders (user_id, period, slot, kind, target, progress, letter, claimed)
         SELECT ?1, ?3, ?4, ?5, 0, 0, NULL, 0 WHERE ${UNCHANGED}`,
      )
      .bind(uid, version, dailyPeriod(date), SWAP_SLOT, slot),
  ];
}

/** Last week's Trials prize claimed (a second one fails on the primary key). */
export function trialMarks(week: string, now: number): ClaimMarks {
  return (db, uid, version) => [
    db.prepare(`INSERT INTO trial_claims (user_id, week, claimed_at) SELECT ?1, ?3, ?4 WHERE ${UNCHANGED}`).bind(uid, version, week, now),
  ];
}

/** Gifts collected, and gifts to me that are long gone dropped. */
export function giftMarks(ids: readonly number[], now: number): ClaimMarks {
  return (db, uid, version) => [
    db
      .prepare(
        `UPDATE gifts SET claimed_at = ?4
          WHERE to_user = ?1 AND id IN (SELECT value FROM json_each(?3)) AND claimed_at IS NULL AND ${UNCHANGED}`,
      )
      .bind(uid, version, JSON.stringify(ids), now),
    db
      .prepare(`DELETE FROM gifts WHERE to_user = ?1 AND sent_date < ?3 AND ${UNCHANGED}`)
      .bind(uid, version, addDays(utcDate(now), -GIFT_ROWS_KEPT_DAYS)),
  ];
}

// ---------------------------------------------------------------------------
// Sending a gift
// ---------------------------------------------------------------------------

/**
 * Records today's gift from `from` to `to`, if they're accepted friends and
 * `from` hasn't sent `to` one today. Returns whether it was recorded.
 * Gifts `from` sent long ago are dropped.
 */
export async function sendGift(db: D1Database, from: string, to: string, now: number): Promise<boolean> {
  const today = utcDate(now);
  const [inserted] = await db.batch([
    db
      .prepare(
        `INSERT INTO gifts (from_user, to_user, sent_date, sent_at)
         SELECT ?1, ?2, ?3, ?4
          WHERE EXISTS (SELECT 1 FROM friends WHERE user_id = ?1 AND friend_id = ?2 AND status = 'accepted')
         ON CONFLICT (from_user, to_user, sent_date) DO NOTHING`,
      )
      .bind(from, to, today, now),
    db.prepare("DELETE FROM gifts WHERE from_user = ?1 AND sent_date < ?2").bind(from, addDays(today, -GIFT_ROWS_KEPT_DAYS)),
  ]);
  return (inserted?.meta.changes ?? 0) === 1;
}
