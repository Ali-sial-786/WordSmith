/**
 * CORS for the browser version of the game (docs/DISTRIBUTION.md), which is
 * served from its own origin. Only the origins in `WEB_ORIGINS` (wrangler
 * vars, comma-separated) and local development servers may call the API from
 * a page. The app on phones sends no Origin and is unaffected. WebSockets
 * aren't subject to CORS; they carry the ID token as a subprotocol anyway.
 */

import type { Env } from "./env";

/** `http://localhost:<port>` or `http://127.0.0.1:<port>`, for `flutter run -d chrome`. */
const LOCAL = /^http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?$/;

/** Preflight answers are cached by the browser for this long (seconds). */
const MAX_AGE = 86_400;

/** The request's Origin if it may call the API from a browser, else null. */
export function allowedOrigin(request: Request, env: Pick<Env, "WEB_ORIGINS">): string | null {
  const origin = request.headers.get("origin");
  if (origin === null) return null;
  if (LOCAL.test(origin)) return origin;
  const allowed = (env.WEB_ORIGINS ?? "").split(",").map((o) => o.trim()).filter((o) => o !== "");
  return allowed.includes(origin) ? origin : null;
}

/** The answer to a browser's preflight `OPTIONS` request. */
export function preflight(origin: string | null): Response {
  if (origin === null) return new Response(null, { status: 204, headers: { Vary: "Origin" } });
  return new Response(null, {
    status: 204,
    headers: {
      "Access-Control-Allow-Origin": origin,
      "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Authorization, Content-Type, Accept",
      "Access-Control-Max-Age": String(MAX_AGE),
      Vary: "Origin",
    },
  });
}

/** `response` with the CORS headers for `origin` (WebSocket upgrades are left alone). */
export function withCors(response: Response, origin: string | null): Response {
  if (response.status === 101) return response;
  const out = new Response(response.body, response);
  out.headers.append("Vary", "Origin");
  if (origin !== null) out.headers.set("Access-Control-Allow-Origin", origin);
  return out;
}
