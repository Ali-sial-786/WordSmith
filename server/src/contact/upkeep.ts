/**
 * The contact form's share of the hourly Cron Trigger (src/index.ts):
 * forgets old IP hashes, deletes year-old messages, and retries forwarding
 * the ones that didn't reach the inbox (src/contact/mail.ts).
 */

import { pruneContactMessages, recordEmailAttempt, unsentContactMessages, type ContactMessage } from "../db/contact";
import { mailConfig, sendContactEmail, type MailConfig, type MailEnv } from "./mail";

/** Most messages one hourly run tries to forward; the rest wait an hour. */
export const MAX_FORWARDS_PER_RUN = 20;

export interface ContactEnv extends MailEnv {
  DB: D1Database;
}

/** Forwards one stored message and records the try. */
export async function forwardContactMessage(db: D1Database, config: MailConfig, m: ContactMessage): Promise<void> {
  const sent = await sendContactEmail(config, m);
  await recordEmailAttempt(db, m.id, sent, Date.now());
}

export async function contactUpkeep(env: ContactEnv, now: number): Promise<void> {
  await pruneContactMessages(env.DB, now);
  const config = mailConfig(env);
  if (config === null) return;
  for (const m of await unsentContactMessages(env.DB, now, MAX_FORWARDS_PER_RUN)) {
    await forwardContactMessage(env.DB, config, m);
  }
}
