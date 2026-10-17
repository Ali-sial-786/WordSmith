/**
 * Invite notifications (shared/push.md): what one looks like, and sending it
 * to each of the invited friend's phones.
 */

import { forgetPushTokens } from "../db/push";
import type { RoomMode } from "../hub/protocol";
import type { FcmMessage, FcmSender } from "./fcm";

export interface InviteNotice {
  /** The inviter's user ID. */
  readonly from: string;
  readonly fromUsername: string;
  /** The room code. */
  readonly code: string;
  readonly mode: RoomMode;
}

/** How long FCM keeps trying to deliver an invite; after that the room has likely moved on. */
export const INVITE_TTL = "300s";

export function inviteMessage(token: string, invite: InviteNotice): FcmMessage {
  return {
    token,
    notification: {
      title: `${invite.fromUsername} invited you to ${invite.mode === "vs" ? "Versus" : "Co-op"}`,
      body: `Tap to join room ${invite.code}`,
    },
    data: { type: "invite", code: invite.code, mode: invite.mode, from: invite.from },
    android: { priority: "high", ttl: INVITE_TTL, collapse_key: `invite-${invite.code}` },
  };
}

/**
 * Sends the invite to each token, then deletes the tokens FCM reported as
 * dead. Never rejects: an invite never fails because a notification did.
 */
export async function pushInvite(sender: FcmSender, db: D1Database, tokens: readonly string[], invite: InviteNotice): Promise<void> {
  try {
    const outcomes = await Promise.all(tokens.map((token) => sender.send(inviteMessage(token, invite))));
    await forgetPushTokens(
      db,
      tokens.filter((_, i) => outcomes[i] === "drop_token"),
    );
  } catch (err) {
    console.error("invite notification failed", err);
  }
}
