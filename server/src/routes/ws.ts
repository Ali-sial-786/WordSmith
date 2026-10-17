/** `GET /v1/ws/hub`: WebSocket upgrade to the HubDO (docs/TECH.md §3–§5). */

import { authenticateToken, webSocketAuth } from "../auth/request";
import { HUB_PROTOCOL_HEADER, HUB_USER_HEADER, HUB_USERNAME_HEADER } from "../hub/hub";
import { ApiError } from "../http";
import { hub, requireSetUp, type RequestContext } from "./context";

/**
 * Verifies the token from `Sec-WebSocket-Protocol: wordsmith.v1, <token>`
 * (or `Authorization: Bearer`), then hands the upgrade to the hub with the
 * verified user ID. The response accepts `wordsmith.v1` if it was offered.
 */
export async function getHubSocket(c: RequestContext): Promise<Response> {
  if (c.request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    throw new ApiError(426, "upgrade_required", "Expected a WebSocket upgrade");
  }
  const { token, protocol } = webSocketAuth(c.request);
  const uid = await authenticateToken(token, c.env);
  const account = await requireSetUp({ ...c, uid });

  const headers = new Headers({ Upgrade: "websocket", [HUB_USER_HEADER]: uid, [HUB_USERNAME_HEADER]: account.username });
  if (protocol !== null) headers.set(HUB_PROTOCOL_HEADER, protocol);
  return hub(c.env).fetch("https://hub.internal/connect", { headers });
}
