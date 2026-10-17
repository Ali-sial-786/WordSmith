/**
 * Sending one notification to each of a player's phones (shared/push.md),
 * whatever it's for: invites (invite.ts) and gifts (gift.ts).
 */

import { forgetPushTokens } from "../db/push";
import type { FcmMessage, FcmSender } from "./fcm";

/**
 * Sends `message(token)` to each token, then deletes the tokens FCM
 * reported as dead. Never rejects: what the notification is about never
 * fails because the notification did. `what` names it in the logs.
 */
export async function pushToTokens(
  sender: FcmSender,
  db: D1Database,
  tokens: readonly string[],
  message: (token: string) => FcmMessage,
  what: string,
): Promise<void> {
  try {
    const outcomes = await Promise.all(tokens.map((token) => sender.send(message(token))));
    await forgetPushTokens(
      db,
      tokens.filter((_, i) => outcomes[i] === "drop_token"),
    );
  } catch (err) {
    console.error(`${what} notification failed`, err);
  }
}
