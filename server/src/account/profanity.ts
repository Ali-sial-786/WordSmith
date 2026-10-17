/**
 * A small username profanity filter (docs/DESIGN.md §4.1, §10).
 *
 * It's deliberately simple: friends pick names, and anyone caught by a false
 * positive just picks another. Names are lower-cased and common look-alike
 * digits are mapped to letters (0→o, 1→i, 3→e, 4→a, 5→s, 7→t, 8→b, 9→g)
 * before matching.
 *
 * - {@link BLOCKED_ANYWHERE} terms are refused anywhere in the name, with
 *   underscores removed first ("f_u_c_k" is caught).
 * - {@link BLOCKED_WORDS} are short words that also occur inside innocent
 *   words ("ass" in "class"), so they're only refused as the whole name or as
 *   one underscore- or digit-separated part of it ("big_ass", "ass99").
 * - {@link RESERVED_NAMES} could be mistaken for the game or a deleted account.
 */

export const BLOCKED_ANYWHERE: readonly string[] = [
  "fuck", "fuk", "fck", "shit", "cunt", "bitch", "whore", "nigger", "nigga", "faggot", "twat",
  "retard", "nazi", "hitler", "molest", "dildo", "porn", "pussy", "penis", "vagina", "bollock",
  "asshole", "arsehole", "jizz",
];

export const BLOCKED_WORDS: readonly string[] = [
  "ass", "arse", "anal", "anus", "dick", "cock", "piss", "tit", "tits", "boob", "boobs", "cum",
  "fag", "fags", "rape", "rapist", "slut", "spic", "kike", "chink", "coon", "sex", "sexy", "nude",
  "nudes", "wank", "pedo", "paedo", "kys", "kkk",
];

export const RESERVED_NAMES: readonly string[] = [
  "admin", "administrator", "moderator", "mod", "staff", "support", "system", "server", "official",
  "wordsmith", "deleted", "deleted_smith", "deletedsmith", "null", "undefined", "anonymous",
];

const LEET: Readonly<Record<string, string>> = { "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "9": "g" };

function deLeet(text: string): string {
  return text.replace(/[0-9]/g, (d) => LEET[d] ?? d);
}

export type NameProblem = "profanity" | "reserved";

/**
 * Why `username` isn't allowed, or `null` if it's fine. Expects a name that
 * already passed the shape check (A–Z, a–z, 0–9 and `_`).
 */
export function nameProblem(username: string): NameProblem | null {
  const lower = username.toLowerCase();
  if (RESERVED_NAMES.includes(lower) || RESERVED_NAMES.includes(lower.replace(/_/g, ""))) return "reserved";

  const squashed = deLeet(lower.replace(/_/g, ""));
  if (BLOCKED_ANYWHERE.some((term) => squashed.includes(term))) return "profanity";

  // Whole name, and each part between underscores or digit runs, both as
  // typed and with look-alike digits mapped.
  const parts = new Set<string>([squashed, deLeet(lower)]);
  for (const part of lower.split(/[_0-9]+/)) if (part !== "") parts.add(part);
  for (const part of deLeet(lower).split("_")) if (part !== "") parts.add(part);
  for (const part of parts) if (BLOCKED_WORDS.includes(part)) return "profanity";
  return null;
}
