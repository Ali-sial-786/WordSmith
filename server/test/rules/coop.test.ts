import { describe, expect, it } from "vitest";
import {
  type ClaimContext,
  bonusWordPoints,
  coopStars,
  decideClaim,
  gridWordPoints,
  pickMvp,
  standingsFromClaims,
} from "../../src/rules/coop";

// The example puzzle from shared/puzzle-format.md.
function context(found: Record<string, string | null> = {}): ClaimContext {
  return {
    letters: "RTAE",
    answers: new Set(["TEAR", "EAT", "RATE"]),
    bonus: new Set(["ARE", "ART", "ATE", "EAR", "ERA", "RAT", "TAR", "TEA"]),
    found: new Map(Object.entries(found)),
  };
}

describe("scoring (DESIGN.md §8)", () => {
  it("scores 10 per grid letter not revealed by a hint", () => {
    expect(gridWordPoints(6, 0)).toBe(60); // THREAD
    expect(gridWordPoints(6, 2)).toBe(40);
    expect(gridWordPoints(3, 3)).toBe(0);
    expect(gridWordPoints(3, 5)).toBe(0);
  });

  it("scores 3 per bonus letter", () => {
    expect(bonusWordPoints(3)).toBe(9);
    expect(bonusWordPoints(4)).toBe(12);
  });
});

describe("decideClaim", () => {
  it("gives an unfound grid word to the sender", () => {
    expect(decideClaim("tear", context())).toEqual({ result: "claimed", word: "TEAR" });
  });

  it("says who already found a grid word", () => {
    expect(decideClaim("TEAR", context({ TEAR: "ali" }))).toEqual({ result: "already", word: "TEAR", by: "ali" });
  });

  it("reports a grid word that hints completed as found by nobody", () => {
    expect(decideClaim("eat", context({ EAT: null }))).toEqual({ result: "already", word: "EAT", by: null });
  });

  it("gives an unfound bonus word to the sender", () => {
    expect(decideClaim("tea", context())).toEqual({ result: "bonus", word: "TEA" });
  });

  it("says who already found a bonus word", () => {
    expect(decideClaim("tea", context({ TEA: "sam" }))).toEqual({ result: "already", word: "TEA", by: "sam" });
  });

  it.each(["trae", "ta", "rater", "tee", "t3a", "", "tear!"])("rejects %j", (word) => {
    expect(decideClaim(word, context())).toEqual({ result: "invalid" });
  });

  it("gives a word to the first sender only", () => {
    const found = new Map<string, string | null>();
    const ctx = { ...context(), found };
    const results = ["ali", "sam", "kim"].map((player) => {
      const d = decideClaim("rate", ctx);
      if (d.result === "claimed") found.set(d.word, player);
      return d;
    });
    expect(results).toEqual([
      { result: "claimed", word: "RATE" },
      { result: "already", word: "RATE", by: "ali" },
      { result: "already", word: "RATE", by: "ali" },
    ]);
  });
});

describe("MVP", () => {
  it("goes to the top scorer", () => {
    const s = standingsFromClaims(
      ["ali", "sam"],
      [
        { playerId: "sam", points: 30 },
        { playerId: "ali", points: 60 },
      ],
    );
    expect(pickMvp(s)).toBe("ali");
  });

  it("goes to whoever reached a tied score first", () => {
    const claims = [
      { playerId: "ali", points: 30 },
      { playerId: "sam", points: 60 }, // sam reaches 60 here
      { playerId: "ali", points: 30 }, // ali reaches 60 later
    ];
    const s = standingsFromClaims(["ali", "sam"], claims);
    expect(s).toEqual([
      { playerId: "ali", points: 60, reachedAt: 2 },
      { playerId: "sam", points: 60, reachedAt: 1 },
    ]);
    expect(pickMvp(s)).toBe("sam");
  });

  it("uses the time the final score was reached, not the first claim", () => {
    const s = standingsFromClaims(
      ["ali", "sam"],
      [
        { playerId: "ali", points: 9 },
        { playerId: "sam", points: 40 },
        { playerId: "ali", points: 31 },
      ],
    );
    expect(pickMvp(s)).toBe("sam");
  });

  it("includes players who scored nothing", () => {
    expect(standingsFromClaims(["ali", "sam"], [{ playerId: "ali", points: 30 }])).toContainEqual({
      playerId: "sam",
      points: 0,
      reachedAt: -1,
    });
  });

  it("goes to nobody if nobody scored", () => {
    expect(pickMvp(standingsFromClaims(["ali", "sam"], []))).toBeNull();
    expect(pickMvp([])).toBeNull();
  });

  it("breaks an exact tie by order", () => {
    expect(
      pickMvp([
        { playerId: "a", points: 50, reachedAt: 3 },
        { playerId: "b", points: 50, reachedAt: 3 },
      ]),
    ).toBe("a");
  });
});

describe("stars", () => {
  const round = 180_000;

  it("gives ★★★ for finishing with at least half the time left", () => {
    expect(coopStars({ filledCells: 20, totalCells: 20, timeLeftMs: 90_000, roundMs: round })).toBe(3);
    expect(coopStars({ filledCells: 20, totalCells: 20, timeLeftMs: 170_000, roundMs: round })).toBe(3);
  });

  it("gives ★★ for finishing with less than half the time left", () => {
    expect(coopStars({ filledCells: 20, totalCells: 20, timeLeftMs: 89_999, roundMs: round })).toBe(2);
    expect(coopStars({ filledCells: 20, totalCells: 20, timeLeftMs: 0, roundMs: round })).toBe(2);
  });

  it("gives ★ for filling at least 75%", () => {
    expect(coopStars({ filledCells: 15, totalCells: 20, timeLeftMs: 0, roundMs: round })).toBe(1);
    expect(coopStars({ filledCells: 19, totalCells: 20, timeLeftMs: 0, roundMs: round })).toBe(1);
    expect(coopStars({ filledCells: 3, totalCells: 4, timeLeftMs: 0, roundMs: round })).toBe(1);
  });

  it("gives nothing below 75%", () => {
    expect(coopStars({ filledCells: 14, totalCells: 20, timeLeftMs: 0, roundMs: round })).toBe(0);
    expect(coopStars({ filledCells: 0, totalCells: 20, timeLeftMs: 0, roundMs: round })).toBe(0);
  });
});
