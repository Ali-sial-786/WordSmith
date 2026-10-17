/**
 * Rooms (shared/room-protocol.md):
 *
 * - `POST /v1/rooms {mode: "coop"}` → `{code}`; the caller is the host
 * - `GET /v1/rooms/:code` → `{code, mode, phase, host: {id, username}, players, maxPlayers}`, or 404 `room_not_found`
 * - `GET /v1/ws/room/:code` → WebSocket upgrade to that room's RoomDO
 *
 * All need a set-up account (`403 setup_required`).
 */

import { authenticateToken, webSocketAuth } from "../auth/request";
import type { Env } from "../env";
import { ApiError, json, readJsonObject } from "../http";
import type { RoomIdentity } from "../room/protocol";
import { ROOM_IDENTITY_HEADER, ROOM_PROTOCOL_HEADER, type RoomDO } from "../room/room";
import { levelFromTotalXp } from "../rules/progression";
import { normalizeRoomCode, roomCodeFromBytes, ROOM_CODE_LENGTH, type RoomMode } from "../rules/room";
import type { SetUpAccount } from "../db/accounts";
import { requireSetUp, type AuthedContext, type RequestContext } from "./context";

/** Fresh codes to try before giving up (a clash is a one-in-a-billion event). */
const CODE_ATTEMPTS = 5;

/** The room for a code: always `idFromName(code)`. */
export function roomStub(env: Env, code: string): DurableObjectStub<RoomDO> {
  return env.ROOM.get(env.ROOM.idFromName(code));
}

function identityOf(account: SetUpAccount): RoomIdentity {
  return { id: account.id, username: account.username, avatar: account.avatar, level: levelFromTotalXp(account.totalXp) };
}

function codeParam(c: RequestContext): string {
  const code = normalizeRoomCode(c.params.code ?? "");
  if (code === null) throw new ApiError(404, "room_not_found");
  return code;
}

export async function postRoom(c: AuthedContext): Promise<Response> {
  const account = await requireSetUp(c);
  const body = await readJsonObject(c.request);
  if (body.mode === "vs") throw new ApiError(400, "unsupported_mode", "Versus rooms arrive in M4");
  if (body.mode !== "coop") throw new ApiError(400, "invalid_mode", 'Expected {mode: "coop"}');
  const mode: RoomMode = body.mode;

  const me = identityOf(account);
  for (let attempt = 0; attempt < CODE_ATTEMPTS; attempt++) {
    const code = roomCodeFromBytes(crypto.getRandomValues(new Uint8Array(ROOM_CODE_LENGTH)));
    if (await roomStub(c.env, code).create(code, mode, me)) return json({ code });
  }
  throw new ApiError(503, "no_room_code", "Couldn't find a free room code; try again");
}

export async function getRoom(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  const code = codeParam(c);
  const summary = await roomStub(c.env, code).summary();
  if (summary === null) throw new ApiError(404, "room_not_found");
  return json(summary);
}

/**
 * Verifies the token from `Sec-WebSocket-Protocol: wordsmith.v1, <token>`
 * (or `Authorization: Bearer`), looks up the player, and hands the upgrade
 * to the room. The room refuses with 404 `room_not_found`, 409 `room_full`
 * or 409 `round_in_progress` before upgrading.
 */
export async function getRoomSocket(c: RequestContext): Promise<Response> {
  if (c.request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    throw new ApiError(426, "upgrade_required", "Expected a WebSocket upgrade");
  }
  const { token, protocol } = webSocketAuth(c.request);
  const uid = await authenticateToken(token, c.env);
  const account = await requireSetUp({ ...c, uid });
  const code = codeParam(c);

  const headers = new Headers({ Upgrade: "websocket", [ROOM_IDENTITY_HEADER]: JSON.stringify(identityOf(account)) });
  if (protocol !== null) headers.set(ROOM_PROTOCOL_HEADER, protocol);
  return roomStub(c.env, code).fetch("https://room.internal/connect", { headers });
}
