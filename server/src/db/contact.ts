/**
 * Contact form messages (shared/contact.md, migrations/0009_contact.sql).
 *
 * Anyone can send one, signed in or not, so two limits keep the inbox
 * usable: {@link MAX_PER_IP} an hour from one IP address (kept only as a
 * hash, and only for a day) and {@link MAX_PER_DAY} a day from everyone.
 * Each message is stored first and then forwarded by email
 * (src/contact/mail.ts); one that couldn't be forwarded is retried by the
 * hourly cron (src/contact/upkeep.ts).
 */

/** What a message is about. */
export const CONTACT_TOPICS = ["account", "deletion", "bug", "player", "privacy", "feedback", "other"] as const;
export type ContactTopic = (typeof CONTACT_TOPICS)[number];

/** How each topic reads in the forwarded email. */
export const TOPIC_LABELS: Readonly<Record<ContactTopic, string>> = {
  account: "Help with an account",
  deletion: "Deleting an account",
  bug: "A bug or problem",
  player: "Another player",
  privacy: "Privacy and data",
  feedback: "Ideas and feedback",
  other: "Something else",
};

export function isContactTopic(value: unknown): value is ContactTopic {
  return typeof value === "string" && (CONTACT_TOPICS as readonly string[]).includes(value);
}

/** Characters (code points) in a message, after trimming. */
export const MAX_MESSAGE = 2000;
/** Characters in the reply address (RFC 5321's limit). */
export const MAX_EMAIL = 254;
/** Characters in the username field (usernames are shorter; this leaves room for a typo). */
export const MAX_USERNAME = 40;

/** Messages from one IP address in {@link IP_WINDOW_MS}. */
export const MAX_PER_IP = 5;
export const IP_WINDOW_MS = 60 * 60 * 1000;
/** Messages from everyone in {@link DAY_MS}, well inside the email service's free daily allowance. */
export const MAX_PER_DAY = 80;
export const DAY_MS = 24 * 60 * 60 * 1000;

/** An IP hash is forgotten this long after its message. */
export const IP_HASH_TTL_MS = DAY_MS;
/** Messages are deleted this long after they were sent. */
export const MESSAGE_TTL_MS = 365 * DAY_MS;
/**
 * The cron retries forwarding a message from {@link RETRY_AFTER_MS} after it
 * was sent (leaving the first try to finish) until {@link RETRY_WINDOW_MS},
 * at most {@link MAX_EMAIL_ATTEMPTS} times in all.
 */
export const RETRY_AFTER_MS = 10 * 60 * 1000;
export const RETRY_WINDOW_MS = 7 * DAY_MS;
export const MAX_EMAIL_ATTEMPTS = 5;

export interface NewContactMessage {
  readonly topic: ContactTopic;
  readonly message: string;
  readonly email: string | null;
  readonly username: string | null;
}

export interface ContactMessage extends NewContactMessage {
  readonly id: number;
  readonly createdAt: number;
}

/** Why a message was refused, or its new id. */
export type InsertResult = { readonly ok: true; readonly id: number } | { readonly ok: false; readonly reason: "ip" | "day" };

/**
 * Stores a message unless its IP has sent {@link MAX_PER_IP} in the last
 * hour or everyone together {@link MAX_PER_DAY} in the last day. The counts
 * and the insert are one statement, so racing messages can't get past them.
 */
export async function insertContactMessage(db: D1Database, input: NewContactMessage, ipHash: string, now: number): Promise<InsertResult> {
  const row = await db
    .prepare(
      `INSERT INTO contact_messages (topic, message, email, username, ip_hash, created_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6
        WHERE (SELECT COUNT(*) FROM contact_messages WHERE ip_hash = ?5 AND created_at > ?6 - ?7) < ?8
          AND (SELECT COUNT(*) FROM contact_messages WHERE created_at > ?6 - ?9) < ?10
       RETURNING id`,
    )
    .bind(input.topic, input.message, input.email, input.username, ipHash, now, IP_WINDOW_MS, MAX_PER_IP, DAY_MS, MAX_PER_DAY)
    .first<{ id: number }>();
  if (row !== null) return { ok: true, id: row.id };
  const fromIp = await db
    .prepare("SELECT COUNT(*) AS n FROM contact_messages WHERE ip_hash = ?1 AND created_at > ?2")
    .bind(ipHash, now - IP_WINDOW_MS)
    .first<number>("n");
  return { ok: false, reason: (fromIp ?? 0) >= MAX_PER_IP ? "ip" : "day" };
}

/** Records a forwarding try, and when it worked. */
export async function recordEmailAttempt(db: D1Database, id: number, sent: boolean, now: number): Promise<void> {
  await db
    .prepare("UPDATE contact_messages SET email_attempts = email_attempts + 1, emailed_at = CASE WHEN ?2 THEN ?3 ELSE emailed_at END WHERE id = ?1")
    .bind(id, sent ? 1 : 0, now)
    .run();
}

/** Messages not forwarded yet that are still worth retrying, oldest first. */
export async function unsentContactMessages(db: D1Database, now: number, limit: number): Promise<ContactMessage[]> {
  const { results } = await db
    .prepare(
      `SELECT id, topic, message, email, username, created_at AS createdAt
         FROM contact_messages
        WHERE emailed_at IS NULL AND email_attempts < ?1 AND created_at > ?2 AND created_at <= ?3
        ORDER BY created_at, id
        LIMIT ?4`,
    )
    .bind(MAX_EMAIL_ATTEMPTS, now - RETRY_WINDOW_MS, now - RETRY_AFTER_MS, limit)
    .all<ContactMessage>();
  return results;
}

/** Forgets IP hashes older than a day and deletes messages older than a year. */
export async function pruneContactMessages(db: D1Database, now: number): Promise<void> {
  await db.batch([
    db.prepare("UPDATE contact_messages SET ip_hash = NULL WHERE ip_hash IS NOT NULL AND created_at <= ?1").bind(now - IP_HASH_TTL_MS),
    db.prepare("DELETE FROM contact_messages WHERE created_at <= ?1").bind(now - MESSAGE_TTL_MS),
  ]);
}
