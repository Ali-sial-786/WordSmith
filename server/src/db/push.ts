/**
 * D1 queries for the phones that get invite notifications
 * (shared/push.md, migrations/0004_push_tokens.sql).
 */

/** An account keeps at most this many tokens; registering another drops the oldest. */
export const MAX_PUSH_TOKENS = 5;

/** FCM registration tokens are about 160 characters; anything this long isn't one. */
export const MAX_PUSH_TOKEN_LENGTH = 4096;

/** A plausible FCM registration token: printable ASCII without spaces, of a sane length. */
export function isPushToken(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= MAX_PUSH_TOKEN_LENGTH && /^[\x21-\x7e]+$/.test(value);
}

/**
 * Stores a token for `uid`, moving it from any other account that had it,
 * and drops `uid`'s oldest tokens beyond {@link MAX_PUSH_TOKENS}.
 */
export async function registerPushToken(db: D1Database, uid: string, token: string, now: number): Promise<void> {
  await db.batch([
    db.prepare("INSERT OR REPLACE INTO push_tokens (token, user_id, registered_at) VALUES (?1, ?2, ?3)").bind(token, uid, now),
    db
      .prepare(
        `DELETE FROM push_tokens WHERE user_id = ?1 AND id NOT IN
           (SELECT id FROM push_tokens WHERE user_id = ?1 ORDER BY id DESC LIMIT ?2)`,
      )
      .bind(uid, MAX_PUSH_TOKENS),
  ]);
}

/** Removes one of `uid`'s tokens. A token `uid` doesn't have is left alone. */
export async function unregisterPushToken(db: D1Database, uid: string, token: string): Promise<void> {
  await db.prepare("DELETE FROM push_tokens WHERE token = ?1 AND user_id = ?2").bind(token, uid).run();
}

/** `uid`'s tokens, newest first. */
export async function pushTokensOf(db: D1Database, uid: string): Promise<string[]> {
  const { results } = await db
    .prepare("SELECT token FROM push_tokens WHERE user_id = ?1 ORDER BY id DESC LIMIT ?2")
    .bind(uid, MAX_PUSH_TOKENS)
    .all<{ token: string }>();
  return results.map((r) => r.token);
}

/**
 * What a notification from `from` to `uid` needs, in one D1 round trip:
 * `uid`'s tokens (as {@link pushTokensOf}), and the nickname `uid` gave
 * `from` (shown instead of their username), or `null`.
 */
export async function pushTargetOf(db: D1Database, uid: string, from: string): Promise<{ tokens: string[]; nickname: string | null }> {
  const [tokens, names] = await db.batch<{ token?: string; nickname?: string | null }>([
    db.prepare("SELECT token FROM push_tokens WHERE user_id = ?1 ORDER BY id DESC LIMIT ?2").bind(uid, MAX_PUSH_TOKENS),
    db.prepare("SELECT nickname FROM friends WHERE user_id = ?1 AND friend_id = ?2 AND status = 'accepted'").bind(uid, from),
  ]);
  return {
    tokens: tokens!.results.map((r) => r.token!),
    nickname: names!.results[0]?.nickname ?? null,
  };
}

/** Deletes tokens FCM says are dead, whoever has them now. */
export async function forgetPushTokens(db: D1Database, tokens: readonly string[]): Promise<void> {
  if (tokens.length === 0) return;
  const placeholders = tokens.map((_, i) => `?${i + 1}`).join(", ");
  await db
    .prepare(`DELETE FROM push_tokens WHERE token IN (${placeholders})`)
    .bind(...tokens)
    .run();
}
