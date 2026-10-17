/**
 * D1 queries for daily reminders (shared/push.md "Daily reminders",
 * migrations/0005_forge_board.sql): the hour a player asked for, and which
 * accounts the hourly Cron Trigger reminds.
 *
 * `reminder_last` isn't part of the profile's optimistic version (nothing
 * else writes it), so setting the hour or recording a reminder doesn't move
 * `profiles.updated_at`.
 */

import type { DailyDay } from "./daily";

/** Sets (or, with `null`, clears) a player's reminder hour. */
export async function setReminderHour(db: D1Database, uid: string, hour: number | null): Promise<void> {
  await db.prepare("UPDATE profiles SET reminder_hour = ?2 WHERE user_id = ?1").bind(uid, hour).run();
}

/**
 * Accounts due a reminder at `hour` on `date`: set up, asking for that
 * hour, with a phone registered, not reminded on `date` yet, and without
 * `date`'s Daily Commission done. At most `limit`, oldest reminder first
 * (never reminded before anyone).
 */
export async function dueReminders(db: D1Database, hour: number, date: string, limit: number): Promise<string[]> {
  const { results } = await db
    .prepare(
      `SELECT p.user_id FROM profiles p JOIN users u ON u.id = p.user_id
        WHERE p.reminder_hour = ?1 AND u.username IS NOT NULL
          AND (p.reminder_last IS NULL OR p.reminder_last <> ?2)
          AND EXISTS (SELECT 1 FROM push_tokens t WHERE t.user_id = p.user_id)
          AND NOT EXISTS (SELECT 1 FROM daily_completions d WHERE d.user_id = p.user_id AND d.date = ?2)
        ORDER BY p.reminder_last IS NOT NULL, p.reminder_last, p.user_id
        LIMIT ?3`,
    )
    .bind(hour, date, limit)
    .all<{ user_id: string }>();
  return results.map((r) => r.user_id);
}

/**
 * Records that these accounts are reminded on `date`, and returns the ones
 * that weren't already (a run that overlaps another can't remind anyone twice).
 */
export async function claimReminders(db: D1Database, uids: readonly string[], date: string): Promise<string[]> {
  if (uids.length === 0) return [];
  const { results } = await db
    .prepare(
      `UPDATE profiles SET reminder_last = ?2
        WHERE user_id IN (SELECT value FROM json_each(?1)) AND (reminder_last IS NULL OR reminder_last <> ?2)
        RETURNING user_id`,
    )
    .bind(JSON.stringify(uids), date)
    .all<{ user_id: string }>();
  return results.map((r) => r.user_id);
}

export interface ReminderTargets {
  /** Each account's tokens, newest first. */
  readonly tokens: ReadonlyMap<string, readonly string[]>;
  /** Each account's Daily Commission days, for the streak. */
  readonly days: ReadonlyMap<string, readonly DailyDay[]>;
}

/** The tokens and completed days of these accounts, in one round trip. */
export async function reminderTargets(db: D1Database, uids: readonly string[]): Promise<ReminderTargets> {
  const ids = JSON.stringify(uids);
  const [tokens, days] = await db.batch<Record<string, unknown>>([
    db.prepare("SELECT user_id, token FROM push_tokens WHERE user_id IN (SELECT value FROM json_each(?1)) ORDER BY id DESC").bind(ids),
    db.prepare("SELECT user_id, date, late FROM daily_completions WHERE user_id IN (SELECT value FROM json_each(?1))").bind(ids),
  ]);
  const byUser = new Map<string, string[]>();
  for (const r of tokens!.results) {
    const list = byUser.get(r.user_id as string) ?? [];
    list.push(r.token as string);
    byUser.set(r.user_id as string, list);
  }
  const daysByUser = new Map<string, DailyDay[]>();
  for (const r of days!.results) {
    const list = daysByUser.get(r.user_id as string) ?? [];
    list.push({ date: r.date as string, late: r.late !== 0 });
    daysByUser.set(r.user_id as string, list);
  }
  return { tokens: byUser, days: daysByUser };
}
