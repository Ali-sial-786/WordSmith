/**
 * Gift notifications (shared/push.md, shared/forge-board.md "Gifts"): a
 * friend sent a free Hammer Strike, waiting in the Forge Hall.
 */

import type { FcmMessage, FcmSender } from "./fcm";
import { pushToTokens } from "./send";

export interface GiftNotice {
  /** The sender's user ID. */
  readonly from: string;
  readonly fromUsername: string;
}

/** How long FCM keeps trying to deliver a gift notification. The gift itself waits 7 days. */
export const GIFT_TTL = "86400s";

export function giftMessage(token: string, gift: GiftNotice): FcmMessage {
  return {
    token,
    notification: { title: `${gift.fromUsername} sent you a gift`, body: "A free Hammer Strike is waiting in the Forge Hall" },
    data: { type: "gift", from: gift.from },
    android: { priority: "normal", ttl: GIFT_TTL, collapse_key: `gift-${gift.from}` },
  };
}

/** Sends the gift notification to each token and forgets dead ones. Never rejects. */
export function pushGift(sender: FcmSender, db: D1Database, tokens: readonly string[], gift: GiftNotice): Promise<void> {
  return pushToTokens(sender, db, tokens, (token) => giftMessage(token, gift), "gift");
}
