/**
 * Username and avatar rules for `POST /v1/me/setup` and
 * `POST /v1/me/username` (docs/DESIGN.md §4.1), and the rules for the
 * nicknames players give friends (`PUT /v1/friends/:id/nickname`).
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

/**
 * A nickname is 1–20 characters as they show on screen (graphemes, so an
 * emoji made of several code points counts once), and at most this many
 * code points, which stops a pile of combining marks on each.
 */
export const NICKNAME_MAX = 20;
const NICKNAME_MAX_CODE_POINTS = 160;

/** Control characters, lone surrogates, line breaks and bidi overrides (which could turn the rest of a line around). */
const NICKNAME_FORBIDDEN = /[\p{Cc}\p{Cs}\p{Zl}\p{Zp}\u202A-\u202E\u2066-\u2069]/u;
/** At least one letter, digit, punctuation mark or symbol (emoji included), so it can be seen. */
const NICKNAME_VISIBLE = /[\p{L}\p{N}\p{P}\p{S}]/u;

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

export type NicknameCheck =
  | { readonly ok: true; readonly nickname: string | null }
  | { readonly ok: false; readonly error: "invalid_nickname"; readonly message: string };

/**
 * Checks a nickname for a friend: `null` clears it; otherwise it's trimmed
 * and must be 1–20 visible characters with no control characters. Anything
 * else goes (it's only ever shown to the player who chose it).
 */
export function checkNickname(raw: unknown): NicknameCheck {
  if (raw === null) return { ok: true, nickname: null };
  const bad = (message: string): NicknameCheck => ({ ok: false, error: "invalid_nickname", message });
  if (typeof raw !== "string") return bad("Nickname must be a string, or null to clear it");
  const nickname = raw.normalize("NFC").trim();
  if (NICKNAME_FORBIDDEN.test(nickname)) return bad("Nicknames can't have control characters or line breaks");
  if (!NICKNAME_VISIBLE.test(nickname)) return bad(`Nickname must be 1-${NICKNAME_MAX} characters`);
  const length = [...graphemes.segment(nickname)].length;
  if (length > NICKNAME_MAX || [...nickname].length > NICKNAME_MAX_CODE_POINTS) {
    return bad(`Nickname must be 1-${NICKNAME_MAX} characters`);
  }
  return { ok: true, nickname };
}
