/**
 * Username and avatar rules for `POST /v1/me/setup` (docs/DESIGN.md §4.1).
 * Uniqueness (ignoring case) is enforced by the database.
 */

import { nameProblem } from "./profanity";

export const USERNAME_MIN = 3;
export const USERNAME_MAX = 16;
const USERNAME_SHAPE = /^[A-Za-z0-9_]+$/;

/** Emblem avatars shipped with the app (docs/ART_AND_AUDIO.md §9): avatar_01 … avatar_16. */
export const AVATAR_COUNT = 16;
export const AVATARS: readonly string[] = Array.from(
  { length: AVATAR_COUNT },
  (_, i) => `avatar_${String(i + 1).padStart(2, "0")}`,
);

/** Shown wherever a deleted account's name used to be (docs/TECH.md §3). */
export const DELETED_NAME = "Deleted smith";

export type UsernameCheck =
  | { readonly ok: true; readonly username: string }
  | { readonly ok: false; readonly error: "invalid_username" | "username_not_allowed"; readonly message: string };

/**
 * Checks a requested username: 3–16 characters of A–Z, a–z, 0–9 and `_`,
 * not offensive and not reserved. Case is kept as typed.
 */
export function checkUsername(raw: unknown): UsernameCheck {
  if (typeof raw !== "string") return { ok: false, error: "invalid_username", message: "Username must be a string" };
  const username = raw.trim();
  if (username.length < USERNAME_MIN || username.length > USERNAME_MAX) {
    return { ok: false, error: "invalid_username", message: `Username must be ${USERNAME_MIN}-${USERNAME_MAX} characters` };
  }
  if (!USERNAME_SHAPE.test(username)) {
    return { ok: false, error: "invalid_username", message: "Use only letters, digits and _" };
  }
  const problem = nameProblem(username);
  if (problem === "reserved") return { ok: false, error: "username_not_allowed", message: "That name is reserved" };
  if (problem === "profanity") return { ok: false, error: "username_not_allowed", message: "Please pick another name" };
  return { ok: true, username };
}

/** Whether a string could be a username at all (for lookups by name). */
export function looksLikeUsername(raw: string): boolean {
  return raw.length >= USERNAME_MIN && raw.length <= USERNAME_MAX && USERNAME_SHAPE.test(raw);
}

export function isAvatar(raw: unknown): raw is string {
  return typeof raw === "string" && AVATARS.includes(raw);
}
