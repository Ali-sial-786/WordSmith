/**
 * Daily reminders (shared/push.md "Daily reminders"): once a day, at the
 * UTC hour a player asked for, a notification that today's Daily
 * Commission is still waiting. The hourly Cron Trigger (wrangler.jsonc,
 * `scheduled` in src/index.ts) calls {@link sendDailyReminders}.
 */

import { onTimeDates } from "../db/daily";
import { claimReminders, dueReminders, reminderTargets } from "../db/reminders";
import { addDays, streakEndingOn, utcDate } from "../rules/daily";
import { fcmSender, type FcmEnv, type FcmMessage } from "./fcm";
import { pushToTokens } from "./send";

/** Most accounts one hourly run reminds; the rest wait for another day. */
export const MAX_REMINDERS_PER_RUN = 500;

/** How long FCM keeps trying: after an hour the reminder is stale. */
export const REMINDER_TTL = "3600s";

/** A reminder hour as `PUT /v1/me/reminder` takes it: a UTC hour 0–23, or `null` for none. */
export function isReminderHour(value: unknown): value is number | null {
  return value === null || (typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= 23);
}

/** The body for a player whose streak (ending yesterday) is `streak` days. */
export function reminderBody(streak: number): string {
  return streak >= 1 ? `Keep your ${streak}-day streak going!` : "A new puzzle is on the anvil.";
}

export function reminderMessage(token: string, streak: number): FcmMessage {
  return {
    token,
    notification: { title: "Today's Daily Commission is waiting", body: reminderBody(streak) },
    data: { type: "daily" },
    android: { priority: "normal", ttl: REMINDER_TTL, collapse_key: "daily" },
  };
}

export interface ReminderEnv extends FcmEnv {
  DB: D1Database;
}

/**
 * The hourly run at `now`: reminds every account due at this UTC hour (at
 * most {@link MAX_REMINDERS_PER_RUN}), recording each before sending so a
 * day never gets two. Does nothing (and reads nothing) while push is off.
 * Returns how many accounts it reminded.
 */
export async function sendDailyReminders(env: ReminderEnv, now: number): Promise<number> {
  const sender = fcmSender(env);
  if (sender === null) return 0;
  const db = env.DB;
  const today = utcDate(now);
  const hour = new Date(now).getUTCHours();
  const due = await dueReminders(db, hour, today, MAX_REMINDERS_PER_RUN);
  const claimed = await claimReminders(db, due, today);
  if (claimed.length === 0) return 0;
  const targets = await reminderTargets(db, claimed);
  const yesterday = addDays(today, -1);
  await Promise.all(
    claimed.map((uid) => {
      const streak = streakEndingOn(new Set(onTimeDates(targets.days.get(uid) ?? [])), yesterday);
      return pushToTokens(sender, db, targets.tokens.get(uid) ?? [], (token) => reminderMessage(token, streak), "reminder");
    }),
  );
  return claimed.length;
}
