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
  /** Firebase project whose ID tokens we accept (`aud`, and part of `iss`). */
  FIREBASE_PROJECT_ID: string;
  /**
   * LiveKit project for in-room video chat (Worker secrets, set by the deploy
   * workflow). Video is off while any of them is missing.
   */
  LIVEKIT_URL?: string;
  LIVEKIT_API_KEY?: string;
  LIVEKIT_API_SECRET?: string;
}
