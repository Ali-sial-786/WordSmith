/**
 * Wordsmith API Worker: the router for the REST routes in docs/TECH.md §4,
 * and the hourly Cron Trigger that sends daily reminders (shared/push.md).
 *
 * Every route except `/v1/version`, `/v1/health` and `/v1/define/:word`
 * needs a Firebase ID token (`Authorization: Bearer <token>`; the WebSocket
 * route reads it from `Sec-WebSocket-Protocol` instead). Errors are JSON
 * `{error, message?}`.
 */

import { authenticate } from "./auth/request";
import { allowedOrigin, preflight, withCors } from "./cors";
import type { Env } from "./env";
import { ApiError, errorResponse, json } from "./http";
import { Router } from "./router";
import { getBoard, postFriendGift, postGiftsClaim, postOrderClaim, postOrderSwap, postStokeClaim, postTrialsClaim } from "./routes/board";
import type { AuthedContext, RequestContext } from "./routes/context";
import { deleteFriend, getFriends, getLeaderboard, postFriendRequest, postFriendRespond, putNickname } from "./routes/friends";
import { sendDailyReminders } from "./push/reminder";
import { deleteMe, deletePushToken, getMe, getUser, postPushToken, postSetup, postUsername, putReminder } from "./routes/me";
import { getRoom, getRoomSocket, postRoom, postRoomVideo } from "./routes/rooms";
import { getDaily, getDailyCalendar, postDailyComplete } from "./routes/daily";
import { getDefine } from "./routes/define";
import { deleteBlock, getBlocks, postReport, putBlock } from "./routes/safety";
import { postSync } from "./routes/solo";
import { postSurvivalSolo } from "./routes/survival";
import { getHubSocket } from "./routes/ws";
import { versionInfo } from "./version";

export { HubDO } from "./hub/hub";
export { RoomDO } from "./room/room";

type Handler =
  | { readonly auth: false; readonly run: (c: RequestContext) => Response | Promise<Response> }
  | { readonly auth: true; readonly run: (c: AuthedContext) => Response | Promise<Response> };

const open = (run: (c: RequestContext) => Response | Promise<Response>): Handler => ({ auth: false, run });
const authed = (run: (c: AuthedContext) => Response | Promise<Response>): Handler => ({ auth: true, run });

const router = new Router<Handler>([
  { method: "GET", path: "/v1/version", handler: open((c) => json(versionInfo(c.env))) },
  { method: "GET", path: "/v1/health", handler: open(() => json({ ok: true })) },
  // Meanings work signed out (src/routes/define.ts).
  { method: "GET", path: "/v1/define/:word", handler: open(getDefine) },

  { method: "GET", path: "/v1/me", handler: authed(getMe) },
  { method: "DELETE", path: "/v1/me", handler: authed(deleteMe) },
  { method: "POST", path: "/v1/me/setup", handler: authed(postSetup) },
  { method: "POST", path: "/v1/me/username", handler: authed(postUsername) },
  { method: "POST", path: "/v1/me/push-token", handler: authed(postPushToken) },
  { method: "DELETE", path: "/v1/me/push-token", handler: authed(deletePushToken) },
  { method: "PUT", path: "/v1/me/reminder", handler: authed(putReminder) },
  { method: "GET", path: "/v1/users/:username", handler: authed(getUser) },

  { method: "GET", path: "/v1/me/board", handler: authed(getBoard) },
  { method: "POST", path: "/v1/me/stoke/claim", handler: authed(postStokeClaim) },
  { method: "POST", path: "/v1/me/orders/swap", handler: authed(postOrderSwap) },
  { method: "POST", path: "/v1/me/orders/claim", handler: authed(postOrderClaim) },
  { method: "POST", path: "/v1/me/trials/claim", handler: authed(postTrialsClaim) },
  { method: "POST", path: "/v1/me/gifts/claim", handler: authed(postGiftsClaim) },

  { method: "POST", path: "/v1/solo/sync", handler: authed(postSync) },
  { method: "POST", path: "/v1/survival/solo", handler: authed(postSurvivalSolo) },

  { method: "GET", path: "/v1/daily", handler: authed(getDaily) },
  { method: "POST", path: "/v1/daily/complete", handler: authed(postDailyComplete) },
  { method: "GET", path: "/v1/daily/calendar", handler: authed(getDailyCalendar) },

  { method: "GET", path: "/v1/friends", handler: authed(getFriends) },
  { method: "POST", path: "/v1/friends/request", handler: authed(postFriendRequest) },
  { method: "POST", path: "/v1/friends/respond", handler: authed(postFriendRespond) },
  { method: "DELETE", path: "/v1/friends/:id", handler: authed(deleteFriend) },
  { method: "POST", path: "/v1/friends/:id/gift", handler: authed(postFriendGift) },
  { method: "PUT", path: "/v1/friends/:id/nickname", handler: authed(putNickname) },
  { method: "GET", path: "/v1/leaderboard", handler: authed(getLeaderboard) },

  // Blocking and reporting (shared/safety.md).
  { method: "GET", path: "/v1/me/blocks", handler: authed(getBlocks) },
  { method: "PUT", path: "/v1/me/blocks/:id", handler: authed(putBlock) },
  { method: "DELETE", path: "/v1/me/blocks/:id", handler: authed(deleteBlock) },
  { method: "POST", path: "/v1/reports", handler: authed(postReport) },

  { method: "POST", path: "/v1/rooms", handler: authed(postRoom) },
  { method: "GET", path: "/v1/rooms/:code", handler: authed(getRoom) },
  { method: "POST", path: "/v1/rooms/:code/video", handler: authed(postRoomVideo) },

  // These authenticate themselves, from the WebSocket subprotocol header.
  { method: "GET", path: "/v1/ws/hub", handler: open(getHubSocket) },
  { method: "GET", path: "/v1/ws/room/:code", handler: open(getRoomSocket) },
]);

/** Routes a request, turning thrown {@link ApiError}s into JSON errors. */
async function handle(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const { pathname } = new URL(request.url);
  const match = router.match(request.method, pathname);
  if (match.kind === "not_found") return errorResponse(404, "not_found");
  if (match.kind === "method_not_allowed") {
    return errorResponse(405, "method_not_allowed", undefined, { Allow: match.allow.join(", ") });
  }

  try {
    const c: RequestContext = { request, env, ctx, params: match.params, now: Date.now() };
    const { handler } = match;
    if (!handler.auth) return await handler.run(c);
    const uid = await authenticate(request, env);
    return await handler.run({ ...c, uid });
  } catch (err) {
    if (err instanceof ApiError) return errorResponse(err.status, err.code, err.detail);
    console.error(`${request.method} ${pathname} failed`, err);
    return errorResponse(500, "internal");
  }
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    // The browser version calls from its own origin (src/cors.ts).
    const origin = allowedOrigin(request, env);
    if (request.method === "OPTIONS") return preflight(origin);
    return withCors(await handle(request, env, ctx), origin);
  },

  /** The hourly Cron Trigger (wrangler.jsonc): today's daily reminders for this UTC hour. */
  async scheduled(controller, env, ctx): Promise<void> {
    ctx.waitUntil(
      sendDailyReminders(env, controller.scheduledTime).catch((err: unknown) => {
        console.error("daily reminders failed", err);
      }),
    );
  },
} satisfies ExportedHandler<Env>;
