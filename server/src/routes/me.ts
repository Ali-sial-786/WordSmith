/** `GET /v1/me`, `POST /v1/me/setup`, `DELETE /v1/me`, `GET /v1/users/:username`. */

import { checkUsername, isAvatar, looksLikeUsername, AVATARS } from "../account/username";
import { deleteAccount, ensureAccount, isSetUp, loadAccount, profileBody, publicProfileBody, setupAccount, userIdByUsername } from "../db/accounts";
import { linkBetween } from "../db/friends";
import { ApiError, json, readJsonObject } from "../http";
import { notifyHub, type AuthedContext } from "./context";

/** My profile. Creates the account on first call; `needsSetup` until a username is chosen. */
export async function getMe(c: AuthedContext): Promise<Response> {
  return json(profileBody(await ensureAccount(c.env.DB, c.uid, c.now)));
}

/** `{username, avatar}` → my profile. */
export async function postSetup(c: AuthedContext): Promise<Response> {
  const body = await readJsonObject(c.request);
  const name = checkUsername(body.username);
  if (!name.ok) throw new ApiError(400, name.error, name.message);
  if (!isAvatar(body.avatar)) {
    throw new ApiError(400, "invalid_avatar", `Avatar must be one of ${AVATARS[0]} … ${AVATARS[AVATARS.length - 1]}`);
  }

  const account = await ensureAccount(c.env.DB, c.uid, c.now);
  const result = await setupAccount(c.env.DB, account, name.username, body.avatar);
  if (result === "taken") throw new ApiError(409, "username_taken", "That username is taken");
  if (result === "already_set") throw new ApiError(409, "already_set", "Your username is already set");
  return json(profileBody((await loadAccount(c.env.DB, c.uid))!));
}

/**
 * Deletes all my data (docs/TECH.md §3). The app then deletes the Firebase
 * user; until it does, calling `GET /v1/me` again would start a new, empty account.
 */
export async function deleteMe(c: AuthedContext): Promise<Response> {
  const { formerFriends } = await deleteAccount(c.env.DB, c.uid);
  await notifyHub(c.env, (hub) => hub.userRemoved(c.uid, formerFriends));
  return json({ ok: true });
}

/** A player's public profile, plus how I stand with them. */
export async function getUser(c: AuthedContext): Promise<Response> {
  const username = c.params.username ?? "";
  const id = looksLikeUsername(username) ? await userIdByUsername(c.env.DB, username) : null;
  const account = id === null ? null : await loadAccount(c.env.DB, id);
  if (account === null || !isSetUp(account)) throw new ApiError(404, "user_not_found");
  const friendship = account.id === c.uid ? "self" : await linkBetween(c.env.DB, c.uid, account.id);
  return json({ ...publicProfileBody(account), friendship });
}
