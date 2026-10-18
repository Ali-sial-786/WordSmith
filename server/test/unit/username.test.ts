import { describe, expect, it } from "vitest";
import { nameProblem } from "../../src/account/profanity";
import {
  AVATARS,
  checkNickname,
  checkUsername,
  isAvatar,
  looksLikeUsername,
  nextUsernameChangeAt,
  USERNAME_CHANGE_COOLDOWN_MS,
} from "../../src/account/username";

describe("checkUsername", () => {
  it.each(["Ali", "sam_the_smith", "X9_", "a".repeat(16), "Scrap_Bin", "Classic", "Bass_Player", "Grape", "Peacock", "therapist", "Torpedo"])(
    "allows %s",
    (name) => {
      expect(checkUsername(name)).toEqual({ ok: true, username: name });
    },
  );

  it("trims surrounding spaces and keeps the case", () => {
    expect(checkUsername("  MixedCase ")).toEqual({ ok: true, username: "MixedCase" });
  });

  it.each(["ab", "a".repeat(17), "with space", "dash-name", "émile", "ali!", "", 5, null, undefined])("refuses the shape of %j", (name) => {
    expect(checkUsername(name)).toMatchObject({ ok: false, error: "invalid_username" });
  });

  it.each(["fuckface", "FUCK", "f_u_c_k", "sh1t", "5hit_head", "big_ass", "ass", "ass99", "d1ck", "Nazi_Smith", "admin", "Deleted_Smith", "WORDSMITH"])(
    "refuses %s",
    (name) => {
      expect(checkUsername(name)).toMatchObject({ ok: false, error: "username_not_allowed" });
    },
  );

  it("tells profanity from reserved names", () => {
    expect(nameProblem("shithead")).toBe("profanity");
    expect(nameProblem("system")).toBe("reserved");
    expect(nameProblem("anvil_ace")).toBeNull();
  });
});

describe("looksLikeUsername", () => {
  it("matches the shape rules only", () => {
    expect(looksLikeUsername("abc")).toBe(true);
    expect(looksLikeUsername("ab")).toBe(false);
    expect(looksLikeUsername("a/b")).toBe(false);
  });
});

describe("nextUsernameChangeAt", () => {
  it("is now before the first change, then a week after the last", () => {
    expect(USERNAME_CHANGE_COOLDOWN_MS).toBe(7 * 24 * 3600_000);
    expect(nextUsernameChangeAt(null)).toBeNull();
    expect(nextUsernameChangeAt(1_000)).toBe(1_000 + USERNAME_CHANGE_COOLDOWN_MS);
  });
});

describe("checkNickname", () => {
  it.each([
    ["Al", "Al"],
    ["  Big Al ", "Big Al"],
    ["Ma 🔨", "Ma 🔨"],
    ["a".repeat(20), "a".repeat(20)],
    ["👨‍👩‍👧‍👦".repeat(20), "👨‍👩‍👧‍👦".repeat(20)],
    ["Zoë", "Zoë"],
    // Composed the same way whatever the keyboard sent.
    ["Zoë", "Zoë"],
    ["李小龍", "李小龍"],
    ["!", "!"],
  ])("allows %j", (raw, nickname) => {
    expect(checkNickname(raw)).toEqual({ ok: true, nickname });
  });

  it("clears with null", () => {
    expect(checkNickname(null)).toEqual({ ok: true, nickname: null });
  });

  it.each([
    "",
    "   ",
    "​​",
    "a".repeat(21),
    "🔥".repeat(21),
    "a" + "́".repeat(200),
    "tab\there",
    "new\nline",
    "nul\u0000",
    "para graph",
    "‮evil",
    "⁦isolate",
    "\ud800lone",
    42,
    undefined,
    ["Al"],
  ])("refuses %j", (raw) => {
    expect(checkNickname(raw)).toMatchObject({ ok: false, error: "invalid_nickname" });
  });
});

describe("avatars", () => {
  it("are avatar_01 to avatar_16", () => {
    expect(AVATARS).toHaveLength(16);
    expect(AVATARS[0]).toBe("avatar_01");
    expect(AVATARS[15]).toBe("avatar_16");
    expect(isAvatar("avatar_09")).toBe(true);
    for (const bad of ["avatar_00", "avatar_17", "avatar_1", "AVATAR_01", 1, null]) expect(isAvatar(bad)).toBe(false);
  });
});
