/**
 * Getting a verified user ID out of a request (docs/TECH.md §3).
 *
 * - REST: `Authorization: Bearer <Firebase ID token>`.
 * - WebSockets: the token rides in `Sec-WebSocket-Protocol`, which keeps it
 *   out of URLs and logs. The client offers `wordsmith.v1, <token>` and the
 *   server accepts `wordsmith.v1`. `Authorization: Bearer` works there too,
 *   for clients that can set headers on the upgrade.
 */

import type { Env } from "../env";
import { ApiError } from "../http";
import { TokenError, verifyFirebaseToken } from "./firebase";

/** The WebSocket subprotocol the hub (and later rooms) speak. */
export const WS_PROTOCOL = "wordsmith.v1";

/** The token from `Authorization: Bearer <token>`, or `null`. */
export function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  if (header === null) return null;
  const match = /^Bearer[ ]+(\S+)\s*$/i.exec(header);
  return match?.[1] ?? null;
}

export interface WebSocketAuth {
  /** The ID token, from the subprotocol list or else the Authorization header. */
  readonly token: string | null;
  /** `wordsmith.v1` if the client offered it (then the server must echo it back), else `null`. */
  readonly protocol: string | null;
}

/** Reads the token and our subprotocol from a WebSocket upgrade request. */
export function webSocketAuth(request: Request): WebSocketAuth {
  const offered = (request.headers.get("sec-websocket-protocol") ?? "")
    .split(",")
    .map((p) => p.trim())
    .filter((p) => p !== "");
  const protocol = offered.includes(WS_PROTOCOL) ? WS_PROTOCOL : null;
  const fromProtocol = offered.find((p) => p !== WS_PROTOCOL && p.split(".").length === 3) ?? null;
  return { token: fromProtocol ?? bearerToken(request), protocol };
}

/**
 * Verifies `token` and returns the user ID (Firebase uid).
 * Throws 401 `unauthorized` (with the reason as `message`), or 503
 * `auth_unavailable` if Google's keys can't be fetched.
 */
export async function authenticateToken(token: string | null, env: Env): Promise<string> {
  if (token === null) throw new ApiError(401, "unauthorized", "missing_token");
  try {
    const identity = await verifyFirebaseToken(token, { projectId: env.FIREBASE_PROJECT_ID });
    return identity.uid;
  } catch (err) {
    if (err instanceof TokenError) {
      if (err.reason === "keys_unavailable") throw new ApiError(503, "auth_unavailable", "Can't check sign-in right now");
      throw new ApiError(401, "unauthorized", err.reason);
    }
    throw err;
  }
}

/** Verifies the request's bearer token. */
export function authenticate(request: Request, env: Env): Promise<string> {
  return authenticateToken(bearerToken(request), env);
}
