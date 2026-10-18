import type { HubDO } from "./hub/hub";
import type { RoomDO } from "./room/room";

/** Bindings and vars from wrangler.jsonc. Keep the two in step. */
export interface Env {
  DB: D1Database;
  /** The single global presence hub (docs/TECH.md §2). Always `idFromName("global")`. */
  HUB: DurableObjectNamespace<HubDO>;
  /** One room per code (docs/TECH.md §6). Always `idFromName(<room code>)`. */
  ROOM: DurableObjectNamespace<RoomDO>;
  LATEST_VERSION: string;
  MIN_SUPPORTED_VERSION: string;
  /**
   * Where a version's APK is published, with `{version}` standing for it (the
   * release that release.yml publishes). The server streams it to players
   * from `/v1/apk/:version` (src/routes/apk.ts); players never see this URL.
   */
  APK_SOURCE_URL?: string;
  /** Firebase project whose ID tokens we accept (`aud`, and part of `iss`). */
  FIREBASE_PROJECT_ID: string;
  /**
   * Origins of the browser version that may call the API from a page,
   * comma-separated (src/cors.ts). Local dev servers are always allowed.
   */
  WEB_ORIGINS?: string;
  /**
   * LiveKit project for in-room video chat (Worker secrets, set by the deploy
   * workflow). Video is off while any of them is missing.
   */
  LIVEKIT_URL?: string;
  LIVEKIT_API_KEY?: string;
  LIVEKIT_API_SECRET?: string;
  /**
   * JSON key of a service account allowed to send FCM messages, for invite
   * notifications (Worker secret, set by the deploy workflow; shared/push.md).
   * Notifications are off while it's missing or malformed (src/push/fcm.ts).
   */
  FCM_SERVICE_ACCOUNT?: string;
  /**
   * Resend API key and the inbox that contact form messages are forwarded to
   * (Worker secrets, set by the deploy workflow; shared/contact.md). While
   * either is missing, messages are only kept in D1 (src/contact/mail.ts).
   */
  RESEND_API_KEY?: string;
  CONTACT_EMAIL?: string;
  /** Sender for those emails, once there's a verified domain; Resend's shared address otherwise. */
  CONTACT_FROM?: string;
}
