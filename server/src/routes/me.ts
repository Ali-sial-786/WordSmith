/**
 * `GET /v1/me`, `POST /v1/me/setup`, `POST /v1/me/age` (shared/age.md),
 * `POST /v1/me/username`, `DELETE /v1/me`, `GET /v1/users/:username`,
 * `POST`/`DELETE /v1/me/push-token` and `PUT /v1/me/reminder` (shared/push.md).
 */

import { checkUsername, isAvatar, looksLikeUsername, AVATARS } from "../account/username";
import {
  changeUsername,
  deleteAccount,
  ensureAccount,
  isSetUp,
  loadAccount,
  profileBody,
  publicProfileBody,
  setBirth,
  setupAccount,
  userIdByUsername,
} from "../db/accounts";
import { linkBetween } from "../db/friends";
import { isPushToken, registerPushToken, unregisterPushToken } from "../db/push";
import { setReminderHour } from "../db/reminders";
import { ApiError, json, readJsonObject } from "../http";
import { isReminderHour } from "../push/reminder";
import { ageAt, MIN_AGE, parseBirth, type Birth } from "../rules/age";
import { notifyHub, requireSetUp, type AuthedContext } from "./context";
import { roomStub } from "./rooms";

/** My profile. Creates the account on first call; `needsSetup` until a username is chosen. */
export async function getMe(c: AuthedContext): Promise<Response> {
  return json(profileBody(await ensureAccount(c.env.DB, c.uid, c.now)));
}

/**
 * `{username, avatar, birthYear, birthMonth}` → my profile. The birth date
 * may be left out (apps before 0.7 don't ask), and the profile then says
 * `needsAge`. Under 13: the account is deleted, and `403 under_13`.
 */
export async function postSetup(c: AuthedContext): Promise<Response> {
  const body = await readJsonObject(c.request);
  const name = checkUsername(body.username);
  if (!name.ok) throw new ApiError(400, name.error, name.message);
  if (!isAvatar(body.avatar)) {
    throw new ApiError(400, "invalid_avatar", `Avatar must be one of ${AVATARS[0]} … ${AVATARS[AVATARS.length - 1]}`);
  }
  const birth = body.birthYear === undefined && body.birthMonth === undefined ? null : birthOf(body, c.now);
  if (birth !== null) await refuseTooYoung(c, birth);

  const account = await ensureAccount(c.env.DB, c.uid, c.now);
  const result = await setupAccount(c.env.DB, account, name.username, body.avatar);
  if (result === "taken") throw new ApiError(409, "username_taken", "That username is taken");
  if (result === "already_set") throw new ApiError(409, "already_set", "Your username is already set");
  if (birth !== null) await setBirth(c.env.DB, c.uid, birth);
  return json(profileBody((await loadAccount(c.env.DB, c.uid))!, c.now));
}

/**
 * `{birthYear, birthMonth}` → my profile: when I was born, for an account
 * made before ages were asked. Given once: `409 age_already_set` after.
 * Under 13: the account is deleted, and `403 under_13`.
 */
export async function postAge(c: AuthedContext): Promise<Response> {
  const birth = birthOf(await readJsonObject(c.request), c.now);
  const account = await ensureAccount(c.env.DB, c.uid, c.now);
  if (account.birth !== null) throw new ApiError(409, "age_already_set", "Your age is already set; write to us if it's wrong");
  await refuseTooYoung(c, birth);
  await setBirth(c.env.DB, c.uid, birth);
  return json(profileBody((await loadAccount(c.env.DB, c.uid))!, c.now));
}

function birthOf(body: Record<string, unknown>, now: number): Birth {
  const birth = parseBirth(body.birthYear, body.birthMonth, now);
  if (birth === null) throw new ApiError(400, "invalid_birth", "Expected birthYear and birthMonth (1-12), not in the future");
  return birth;
}

/**
 * Online play is for 13 and over (shared/age.md). A younger player's account,
 * and everything it holds, is deleted on the spot, as `DELETE /v1/me` would.
 */
async function refuseTooYoung(c: AuthedContext, birth: Birth): Promise<void> {
  if (ageAt(birth, c.now) >= MIN_AGE) return;
  await removeAccount(c);
  throw new ApiError(403, "under_13", "Online play is for players 13 and over");
}

async function removeAccount(c: AuthedContext): Promise<void> {
  const { formerFriends } = await deleteAccount(c.env.DB, c.uid);
  await notifyHub(c.env, (hub) => hub.userRemoved(c.uid, formerFriends));
}

/**
 * `{username}` → my profile, with the new username. Setup's rules (400
 * `invalid_username` / `username_not_allowed`, 409 `username_taken`, unique
 * ignoring case), as often as I like. Asking for exactly the name I have
 * changes nothing (a retry is fine). The hub and any room I'm in or host are told before the
 * answer, so friends see the new name at once.
 */
export async function postUsername(c: AuthedContext): Promise<Response> {
  const account = await requireSetUp(c);
  const body = await readJsonObject(c.request);
  const name = checkUsername(body.username);
  if (!name.ok) throw new ApiError(400, name.error, name.message);

  const result = await changeUsername(c.env.DB, account, name.username, c.now);
  switch (result.kind) {
    case "taken":
      throw new ApiError(409, "username_taken", "That username is taken");
    case "ok":
      await renamedEverywhere(c, name.username);
      break;
    case "unchanged":
      break;
  }
  return json(profileBody((await loadAccount(c.env.DB, c.uid))!));
}

/**
 * Tells the copies of my username outside D1: the hub's (invites, the
 * open-rooms listing) and each room's player list. Best effort, like
 * presence: a socket or room that missed it picks the name up when the
 * player next connects.
 */
async function renamedEverywhere(c: AuthedContext, username: string): Promise<void> {
  let codes: string[] = [];
  await notifyHub(c.env, async (hub) => {
    codes = await hub.usernameChanged(c.uid, username);
  });
  await Promise.all(
    codes.map((code) =>
      roomStub(c.env, code)
        .renamed(c.uid, username)
        .catch((err: unknown) => console.error(`telling room ${code} about a new username failed`, err)),
    ),
  );
}

/**
 * Deletes all my data (docs/TECH.md §3). The app then deletes the Firebase
 * user; until it does, calling `GET /v1/me` again would start a new, empty account.
 */
export async function deleteMe(c: AuthedContext): Promise<Response> {
  await removeAccount(c);
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

/** The `{token}` body of the push-token routes: an FCM registration token. */
async function pushTokenBody(c: AuthedContext): Promise<string> {
  const body = await readJsonObject(c.request);
  if (!isPushToken(body.token)) throw new ApiError(400, "invalid_push_token", "Expected {token}: an FCM registration token");
  return body.token;
}

/**
 * `{token}` → `{ok: true}`: this phone gets invite notifications. The token
 * moves here from any other account that had it; an account keeps its 5
 * newest. Stored even while push is off on the server.
 */
export async function postPushToken(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  const token = await pushTokenBody(c);
  await registerPushToken(c.env.DB, c.uid, token, c.now);
  return json({ ok: true });
}

/** `{token}` → `{ok: true}`: stops notifications to this phone (sign-out, or turned off). Unknown tokens are fine. */
export async function deletePushToken(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  const token = await pushTokenBody(c);
  await unregisterPushToken(c.env.DB, c.uid, token);
  return json({ ok: true });
}

/**
 * `{hour}` → `{ok: true, hour}`: a daily reminder at that UTC hour (0–23)
 * while the Daily Commission is still waiting, or none with `{hour: null}`.
 */
export async function putReminder(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  const body = await readJsonObject(c.request);
  if (!("hour" in body) || !isReminderHour(body.hour)) {
    throw new ApiError(400, "invalid_body", "Expected {hour}: a UTC hour 0–23, or null for no reminder");
  }
  await setReminderHour(c.env.DB, c.uid, body.hour);
  return json({ ok: true, hour: body.hour });
}
