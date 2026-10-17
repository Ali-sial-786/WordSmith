import { describe, expect, it } from "vitest";
import { MIN_WORD_LENGTH, canBeMadeFrom, checkGuess, normalizeWord } from "../../src/rules/words";

describe("normalizeWord", () => {
  it("uppercases plain letters", () => {
    expect(normalizeWord("thread")).toBe("THREAD");
    expect(normalizeWord("ThReAd")).toBe("THREAD");
    expect(normalizeWord("TEA")).toBe("TEA");
  });

  it("trims surrounding whitespace", () => {
    expect(normalizeWord("  tea\n")).toBe("TEA");
  });

  it.each(["", "   ", "t e a", "tea!", "t-e-a", "te4", "café", "ı", "ß", "ｔｅａ"])("rejects %j", (raw) => {
    expect(normalizeWord(raw)).toBeNull();
  });
});

describe("canBeMadeFrom", () => {
  it("accepts words using each tile at most as often as it appears", () => {
    expect(canBeMadeFrom("TEAR", "RTAE")).toBe(true);
    expect(canBeMadeFrom("EAT", "RTAE")).toBe(true);
    expect(canBeMadeFrom("TREAT", "RTAET")).toBe(true);
  });

  it("respects letter multiplicity", () => {
    expect(canBeMadeFrom("TREAT", "RTAE")).toBe(false);
    expect(canBeMadeFrom("TEE", "RTAE")).toBe(false);
  });

  it("rejects letters that aren't on the anvil", () => {
    expect(canBeMadeFrom("RATS", "RTAE")).toBe(false);
  });

  it("rejects words longer than the anvil", () => {
    expect(canBeMadeFrom("TEARS", "RTAE")).toBe(false);
  });
});

describe("checkGuess", () => {
  it("returns the normalised word when it passes every check", () => {
    expect(checkGuess("tea", "RTAE")).toBe("TEA");
    expect(checkGuess(" Rate ", "RTAE")).toBe("RATE");
  });

  it(`needs at least ${MIN_WORD_LENGTH} letters`, () => {
    expect(MIN_WORD_LENGTH).toBe(3);
    expect(checkGuess("at", "RTAE")).toBeNull();
    expect(checkGuess("ate", "RTAE")).toBe("ATE");
  });

  it("rejects words that can't be made from the letters", () => {
    expect(checkGuess("tee", "RTAE")).toBeNull();
    expect(checkGuess("rater", "RTAE")).toBeNull();
  });

  it("rejects malformed input", () => {
    expect(checkGuess("te@", "RTAE")).toBeNull();
  });
});
