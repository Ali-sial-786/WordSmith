/**
 * Friends routes (docs/TECH.md §4). All need a set-up account.
 *
 * - `GET /v1/friends` → {friends, incoming, outgoing}
 * - `POST /v1/friends/request {username}` → {status: "pending" | "accepted", user}
 *   (asking someone who already asked you accepts their request)
 * - `POST /v1/friends/respond {userId, accept}` → {status: "accepted" | "declined", user}
 * - `DELETE /v1/friends/:id` → {ok: true}: removes a friend, cancels my
 *   request, or declines theirs
 */

import { looksLikeUsername } from "../account/username";
import {
  acceptLimit,
  acceptRequest,
  deleteRequest,
  findUser,
  insertRequest,
  leaderboard,
  linkBetween,
  listFriends,
  requestLimit,
  unlink,
  type LimitHit,
} from "../db/friends";
import { ApiError, json, readJsonObject } from "../http";
import { notifyHub, requireSetUp, type AuthedContext } from "./context";

function limitError(hit: LimitHit): ApiError {
  const messages: Record<LimitHit, string> = {
    my_friends_full: "You have the most friends allowed",
    their_friends_full: "They have the most friends allowed",
    too_many_requests: "Too many requests are waiting; wait for some answers",
  };
  return new ApiError(409, hit, messages[hit]);
}

export async function getFriends(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  return json(await listFriends(c.env.DB, c.uid));
}

export async function postFriendRequest(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  const body = await readJsonObject(c.request);
  if (typeof body.username !== "string" || body.username.trim() === "") {
    throw new ApiError(400, "invalid_username", "Expected {username}");
  }
  const username = body.username.trim();
  const db = c.env.DB;
  const target = looksLikeUsername(username) ? await findUser(db, { username }) : null;
  if (target === null) throw new ApiError(404, "user_not_found");
  if (target.id === c.uid) throw new ApiError(400, "cannot_friend_self");

  switch (await linkBetween(db, c.uid, target.id)) {
    case "friends":
      throw new ApiError(409, "already_friends");
    case "request_sent":
      return json({ status: "pending", user: target });
    case "request_received": {
      const hit = await acceptLimit(db, c.uid, target.id);
      if (hit !== null) throw limitError(hit);
      await acceptRequest(db, target.id, c.uid, c.now);
      await notifyHub(c.env, (hub) => hub.friendshipChanged(c.uid, target.id, true));
      return json({ status: "accepted", user: target });
    }
    case "none": {
      const hit = await requestLimit(db, c.uid);
      if (hit !== null) throw limitError(hit);
      await insertRequest(db, c.uid, target.id, c.now);
      return json({ status: "pending", user: target });
    }
  }
}

export async function postFriendRespond(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  const body = await readJsonObject(c.request);
  if (typeof body.userId !== "string" || body.userId === "" || typeof body.accept !== "boolean") {
    throw new ApiError(400, "invalid_body", "Expected {userId, accept}");
  }
  const { userId, accept } = body;
  const db = c.env.DB;
  if ((await linkBetween(db, c.uid, userId)) !== "request_received") throw new ApiError(404, "request_not_found");
  const user = await findUser(db, { id: userId });
  if (user === null) throw new ApiError(404, "request_not_found");

  if (!accept) {
    await deleteRequest(db, userId, c.uid);
    return json({ status: "declined", user });
  }
  const hit = await acceptLimit(db, c.uid, userId);
  if (hit !== null) throw limitError(hit);
  if (!(await acceptRequest(db, userId, c.uid, c.now))) throw new ApiError(404, "request_not_found");
  await notifyHub(c.env, (hub) => hub.friendshipChanged(c.uid, userId, true));
  return json({ status: "accepted", user });
}

export async function deleteFriend(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  const other = c.params.id ?? "";
  const before = await unlink(c.env.DB, c.uid, other);
  if (before === "none") throw new ApiError(404, "not_found", "No friend or request with that user");
  if (before === "friends") await notifyHub(c.env, (hub) => hub.friendshipChanged(c.uid, other, false));
  return json({ ok: true });
}

/**
 * Me and my friends by lifetime XP, with VS wins and co-op rounds/MVPs.
 * TECH.md §4 also lists a co-op best score; there's no column for one yet.
 */
export async function getLeaderboard(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  return json({ entries: await leaderboard(c.env.DB, c.uid) });
}
