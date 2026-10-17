/**
 * Hub messages (docs/TECH.md §5): JSON `{op, ...payload}` over the
 * `wordsmith.v1` WebSocket. Pure, so it's unit-tested in Node.
 *
 * TECH.md plans to generate these types from JSON Schema in
 * shared/protocol/; until that exists, this file is the definition.
 *
 * Client → server
 * - `{"op":"SET_STATUS","status":"online"|"solo"|"in_room:<CODE>"}`
 * - `{"op":"INVITE","to":"<friend user id>","code":"<CODE>","mode":"coop"|"vs"}`
 * - the exact text `{"op":"PING"}`, answered with `{"op":"PONG"}` without
 *   waking the hub (a hibernation auto-response)
 *
 * Server → client
 * - `{"op":"PRESENCE","userId","status"}`, status also `"offline"`
 * - `{"op":"INVITE","from","fromUsername","code","mode"}`
 * - `{"op":"OPEN_ROOMS","rooms":[{code, mode, hostId, players, max}]}`
 *   (always empty until rooms arrive in M3)
 * - `{"op":"ERROR","code","message"?}`
 *
 * On connect the server sends one PRESENCE per online friend, then
 * OPEN_ROOMS, so OPEN_ROOMS also marks the end of the initial snapshot.
 */

export type RoomMode = "coop" | "vs";

/** A status a client may set. */
export type SettableStatus = "online" | "solo" | `in_room:${string}`;
export type PresenceStatus = SettableStatus | "offline";

/** Room codes are 6 characters, upper-case letters and digits (DESIGN.md §7). */
export const ROOM_CODE_PATTERN = /^[A-Z0-9]{6}$/;

export const PING = '{"op":"PING"}';
export const PONG = '{"op":"PONG"}';

/** Client messages longer than this are refused. */
export const MAX_CLIENT_MESSAGE_LENGTH = 1024;

export type ClientMessage =
  | { readonly op: "SET_STATUS"; readonly status: SettableStatus }
  | { readonly op: "INVITE"; readonly to: string; readonly code: string; readonly mode: RoomMode };

export interface OpenRoom {
  readonly code: string;
  readonly mode: RoomMode;
  readonly hostId: string;
  readonly players: number;
  readonly max: number;
}

export type ServerMessage =
  | { readonly op: "PRESENCE"; readonly userId: string; readonly status: PresenceStatus }
  | {
      readonly op: "INVITE";
      readonly from: string;
      readonly fromUsername: string;
      readonly code: string;
      readonly mode: RoomMode;
    }
  | { readonly op: "OPEN_ROOMS"; readonly rooms: readonly OpenRoom[] }
  | { readonly op: "ERROR"; readonly code: HubErrorCode; readonly message?: string };

export type HubErrorCode =
  | "bad_message"
  | "unknown_op"
  | "bad_status"
  | "bad_invite"
  | "not_friends"
  | "friend_offline"
  | "rate_limited";

export function parseStatus(value: unknown): SettableStatus | null {
  if (value === "online" || value === "solo") return value;
  if (typeof value === "string" && value.startsWith("in_room:") && ROOM_CODE_PATTERN.test(value.slice(8))) {
    return value as SettableStatus;
  }
  return null;
}

export type ParseResult = { readonly ok: true; readonly message: ClientMessage } | { readonly ok: false; readonly code: HubErrorCode };

export function parseClientMessage(raw: string | ArrayBuffer): ParseResult {
  if (typeof raw !== "string" || raw.length > MAX_CLIENT_MESSAGE_LENGTH) return { ok: false, code: "bad_message" };
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return { ok: false, code: "bad_message" };
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) return { ok: false, code: "bad_message" };
  const msg = value as Record<string, unknown>;
  switch (msg.op) {
    case "SET_STATUS": {
      const status = parseStatus(msg.status);
      return status === null ? { ok: false, code: "bad_status" } : { ok: true, message: { op: "SET_STATUS", status } };
    }
    case "INVITE": {
      const { to, code, mode } = msg;
      if (
        typeof to !== "string" ||
        to === "" ||
        to.length > 128 ||
        typeof code !== "string" ||
        !ROOM_CODE_PATTERN.test(code) ||
        (mode !== "coop" && mode !== "vs")
      ) {
        return { ok: false, code: "bad_invite" };
      }
      return { ok: true, message: { op: "INVITE", to, code, mode } };
    }
    default:
      return { ok: false, code: "unknown_op" };
  }
}

/** A per-socket token bucket. Lives in memory, so it resets if the hub hibernates. */
export class RateLimiter {
  private tokens: number;
  private last: number;

  constructor(
    private readonly capacity: number,
    private readonly refillPerSecond: number,
    now: number,
  ) {
    this.tokens = capacity;
    this.last = now;
  }

  /** Takes a token if there is one. */
  take(now: number): boolean {
    this.tokens = Math.min(this.capacity, this.tokens + ((now - this.last) / 1000) * this.refillPerSecond);
    this.last = now;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }
}
