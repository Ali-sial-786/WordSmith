/**
 * Work Orders in D1 (shared/forge-board.md, migrations/0005_forge_board.sql):
 * making a player's rows for a day and a week, and adding an accepted play
 * to them.
 *
 * The statements here go into the batch that writes the play itself (solo
 * sync, the Daily Commission, a co-op round, a Versus series), guarded the
 * same way: they only apply while `profiles.updated_at` is still at the
 * version the caller read, so a play counts exactly once, with its XP. Every
 * write that changes orders (progress, a claim, the swap) also moves the
 * profile's version on, so claims see a consistent picture.
 */

import { isoWeek } from "../rules/board";
import { addDays, utcDate } from "../rules/daily";
import {
  dailyOrders,
  dailyPeriod,
  hasCounts,
  orderCounts,
  weeklyLetter,
  weeklyOrders,
  weeklyPeriod,
  type OrderSpec,
  type PlayFacts,
} from "../rules/orders";

/** A player's rows older than this (in days) are dropped when new ones are made. */
export const ORDER_ROWS_KEPT_DAYS = 14;

/** Only true while the profile is still at the version we read (`?1` uid, `?2` version). */
const UNCHANGED = "EXISTS (SELECT 1 FROM profiles WHERE user_id = ?1 AND updated_at = ?2)";

/**
 * Statements that make `uid`'s rows for `date`'s orders and its week's,
 * as configured, where they don't exist yet (a swapped order keeps its
 * kind), and drop rows older than {@link ORDER_ROWS_KEPT_DAYS}.
 */
export function ensureOrderRows(db: D1Database, uid: string, version: number, date: string): D1PreparedStatement[] {
  const week = isoWeek(date);
  const rows = (period: string, specs: readonly OrderSpec[]) => specs.map((o) => ({ period, slot: o.slot, kind: o.kind, target: o.target, letter: o.letter }));
  const defaults = [...rows(dailyPeriod(date), dailyOrders(date)), ...rows(weeklyPeriod(week), weeklyOrders(week))];
  const oldest = addDays(date, -ORDER_ROWS_KEPT_DAYS);
  return [
    db
      .prepare(
        `DELETE FROM work_orders WHERE user_id = ?1 AND ${UNCHANGED}
            AND ((period LIKE 'd:%' AND period < ?3) OR (period LIKE 'w:%' AND period < ?4))`,
      )
      .bind(uid, version, dailyPeriod(oldest), weeklyPeriod(isoWeek(oldest))),
    db
      .prepare(
        `INSERT INTO work_orders (user_id, period, slot, kind, target, progress, letter, claimed)
         SELECT ?1, json_extract(j.value, '$.period'), json_extract(j.value, '$.slot'), json_extract(j.value, '$.kind'),
                json_extract(j.value, '$.target'), 0, json_extract(j.value, '$.letter'), 0
           FROM json_each(?3) AS j WHERE ${UNCHANGED}
         ON CONFLICT (user_id, period, slot) DO NOTHING`,
      )
      .bind(uid, version, JSON.stringify(defaults)),
  ];
}

/**
 * Statements that add what `facts` count to `uid`'s unclaimed orders for
 * the day and week of `now` (progress stops at the target), making the
 * rows first. None if the facts count towards nothing.
 */
export function orderProgress(db: D1Database, uid: string, version: number, facts: PlayFacts, now: number): D1PreparedStatement[] {
  const date = utcDate(now);
  const week = isoWeek(date);
  const counts = orderCounts(facts, weeklyLetter(week));
  if (!hasCounts(counts)) return [];
  return [
    ...ensureOrderRows(db, uid, version, date),
    db
      .prepare(
        `UPDATE work_orders SET progress = MIN(target, progress + COALESCE(json_extract(?3, '$.' || kind), 0))
          WHERE user_id = ?1 AND period IN (?4, ?5) AND slot IN ('d0', 'd1', 'd2', 'w0', 'w1') AND claimed = 0 AND ${UNCHANGED}`,
      )
      .bind(uid, version, JSON.stringify(counts), dailyPeriod(date), weeklyPeriod(week)),
  ];
}
