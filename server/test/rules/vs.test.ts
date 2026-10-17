import { describe, expect, it } from "vitest";
import {
  SERIES_LENGTHS,
  type SeriesEntry,
  isClinched,
  isSeriesLength,
  isSeriesOver,
  leaders,
  podium,
  resolveVsRound,
  roundsLeft,
  seriesStatus,
} from "../../src/rules/vs";

const tally = (wins: Record<string, number>): SeriesEntry[] =>
  Object.entries(wins).map(([playerId, w]) => ({ playerId, wins: w }));

describe("resolveVsRound", () => {
  it("gives the round to the first player to fill their mold", () => {
    expect(
      resolveVsRound(20, [
        { playerId: "ali", lettersFilled: 12, reachedAt: 3 },
        { playerId: "sam", lettersFilled: 20, reachedAt: 9 },
      ]),
    ).toEqual({ winner: "sam", how: "finished" });
  });

  it("picks the earliest finisher if more than one finished", () => {
    expect(
      resolveVsRound(20, [
        { playerId: "ali", lettersFilled: 20, reachedAt: 10 },
        { playerId: "sam", lettersFilled: 20, reachedAt: 9 },
      ]),
    ).toEqual({ winner: "sam", how: "finished" });
  });

  it("on timeout, gives the round to the most letters filled", () => {
    expect(
      resolveVsRound(20, [
        { playerId: "ali", lettersFilled: 12, reachedAt: 2 },
        { playerId: "sam", lettersFilled: 15, reachedAt: 8 },
        { playerId: "kim", lettersFilled: 3, reachedAt: 1 },
      ]),
    ).toEqual({ winner: "sam", how: "timeout" });
  });

  it("on timeout, breaks a tie by who reached that count first", () => {
    expect(
      resolveVsRound(20, [
        { playerId: "ali", lettersFilled: 15, reachedAt: 8 },
        { playerId: "sam", lettersFilled: 15, reachedAt: 6 },
        { playerId: "kim", lettersFilled: 12, reachedAt: 1 },
      ]),
    ).toEqual({ winner: "sam", how: "timeout" });
  });

  it("has no winner if nobody filled anything", () => {
    expect(
      resolveVsRound(20, [
        { playerId: "ali", lettersFilled: 0, reachedAt: 0 },
        { playerId: "sam", lettersFilled: 0, reachedAt: 0 },
      ]),
    ).toEqual({ winner: null, how: "none" });
    expect(resolveVsRound(20, [])).toEqual({ winner: null, how: "none" });
  });
});

describe("series lengths", () => {
  it("are 3, 5, 7 or 10", () => {
    expect(SERIES_LENGTHS).toEqual([3, 5, 7, 10]);
    expect(isSeriesLength(7)).toBe(true);
    expect(isSeriesLength(4)).toBe(false);
    expect(isSeriesLength("5")).toBe(false);
  });

  it("count down the rounds left without going negative", () => {
    expect(roundsLeft(5, 2)).toBe(3);
    expect(roundsLeft(3, 4)).toBe(0);
  });
});

describe("isClinched", () => {
  it.each([
    [3, 2],
    [5, 3],
    [7, 4],
    [10, 6],
  ])("2 players, best of %i: first to %i (DESIGN.md §9.2)", (length, firstTo) => {
    // The leader wins every round; find when nobody can catch them.
    let clinchedAt = 0;
    for (let played = 1; played <= length; played++) {
      if (isClinched([played, 0], roundsLeft(length, played))) {
        clinchedAt = played;
        break;
      }
    }
    expect(clinchedAt).toBe(firstTo);
  });

  it("compares the leader with the runner-up", () => {
    expect(isClinched([3, 0, 0], 2)).toBe(true);
    expect(isClinched([2, 1, 0], 2)).toBe(false);
    expect(isClinched([0, 3, 1], 1)).toBe(true); // order doesn't matter
    expect(isClinched([2, 2], 0)).toBe(false); // tied leaders never clinch
  });

  it("treats a missing runner-up as 0 wins", () => {
    expect(isClinched([1], 0)).toBe(true);
    expect(isClinched([], 0)).toBe(false);
  });
});

describe("seriesStatus", () => {
  it("keeps playing while the leader can be caught", () => {
    expect(seriesStatus(tally({ ali: 1, sam: 0 }), 3, 1)).toEqual({ state: "playing" });
    expect(seriesStatus(tally({ ali: 2, sam: 1, kim: 1 }), 5, 4)).toEqual({ state: "playing" });
  });

  it("ends early once the leader is out of reach", () => {
    expect(seriesStatus(tally({ ali: 2, sam: 0 }), 3, 2)).toEqual({ state: "won", winner: "ali", early: true });
    // Rounds with no winner still use up the series.
    expect(seriesStatus(tally({ ali: 2, sam: 0 }), 5, 4)).toEqual({ state: "won", winner: "ali", early: true });
  });

  it("ends after the last round when there's a clear leader", () => {
    expect(seriesStatus(tally({ ali: 1, sam: 2 }), 3, 3)).toEqual({ state: "won", winner: "sam", early: false });
    expect(isSeriesOver(tally({ ali: 1, sam: 2 }), 3, 3)).toBe(true);
  });

  it("goes to sudden death between the tied leaders after the last round", () => {
    expect(seriesStatus(tally({ ali: 2, sam: 2, kim: 1 }), 5, 5)).toEqual({ state: "sudden_death", players: ["ali", "sam"] });
    expect(seriesStatus(tally({ ali: 1, sam: 1, kim: 1 }), 3, 3)).toEqual({
      state: "sudden_death",
      players: ["ali", "sam", "kim"],
    });
    expect(isSeriesOver(tally({ ali: 2, sam: 2, kim: 1 }), 5, 5)).toBe(false);
  });

  it("puts everyone into sudden death if no round had a winner", () => {
    expect(seriesStatus(tally({ ali: 0, sam: 0 }), 3, 3)).toEqual({ state: "sudden_death", players: ["ali", "sam"] });
  });

  it("is decided once a sudden-death round has a winner", () => {
    expect(seriesStatus(tally({ ali: 3, sam: 2, kim: 1 }), 5, 6)).toEqual({ state: "won", winner: "ali", early: false });
  });

  it("repeats sudden death if it had no winner", () => {
    expect(seriesStatus(tally({ ali: 2, sam: 2, kim: 1 }), 5, 6)).toEqual({ state: "sudden_death", players: ["ali", "sam"] });
  });
});

describe("leaders", () => {
  it("lists everyone on the most wins", () => {
    expect(leaders(tally({ ali: 2, sam: 3, kim: 3 }))).toEqual(["sam", "kim"]);
    expect(leaders(tally({ ali: 2, sam: 1 }))).toEqual(["ali"]);
  });
});

describe("podium", () => {
  it("ranks by round wins, with equal wins sharing a place", () => {
    expect(podium(tally({ ali: 2, sam: 3, kim: 2, jo: 0 }))).toEqual([
      { playerId: "sam", wins: 3, place: 1 },
      { playerId: "ali", wins: 2, place: 2 },
      { playerId: "kim", wins: 2, place: 2 },
      { playerId: "jo", wins: 0, place: 4 },
    ]);
  });
});

describe("a 5-player best of 3 with a timed-out round and sudden death", () => {
  it("plays out end to end", () => {
    const players = ["ali", "sam", "kim", "jo", "max"];
    const wins = new Map(players.map((p) => [p, 0]));
    const standings = () => players.map((playerId) => ({ playerId, wins: wins.get(playerId)! }));
    let played = 0;
    const play = (result: { winner: string | null }) => {
      played++;
      if (result.winner !== null) wins.set(result.winner, wins.get(result.winner)! + 1);
      return seriesStatus(standings(), 3, played);
    };

    // Round 1: ali fills the mold first.
    const r1 = resolveVsRound(18, [
      { playerId: "ali", lettersFilled: 18, reachedAt: 40 },
      { playerId: "sam", lettersFilled: 14, reachedAt: 38 },
      { playerId: "kim", lettersFilled: 9, reachedAt: 30 },
      { playerId: "jo", lettersFilled: 6, reachedAt: 22 },
      { playerId: "max", lettersFilled: 0, reachedAt: 0 },
    ]);
    expect(r1).toEqual({ winner: "ali", how: "finished" });
    expect(play(r1)).toEqual({ state: "playing" });

    // Round 2: time runs out; sam and kim tie on letters, sam got there first.
    const r2 = resolveVsRound(18, [
      { playerId: "ali", lettersFilled: 10, reachedAt: 50 },
      { playerId: "sam", lettersFilled: 15, reachedAt: 61 },
      { playerId: "kim", lettersFilled: 15, reachedAt: 70 },
      { playerId: "jo", lettersFilled: 3, reachedAt: 12 },
      { playerId: "max", lettersFilled: 4, reachedAt: 20 },
    ]);
    expect(r2).toEqual({ winner: "sam", how: "timeout" });
    expect(play(r2)).toEqual({ state: "playing" });

    // Round 3: max wins, leaving ali, sam and max tied on 1.
    const r3 = resolveVsRound(18, [
      { playerId: "max", lettersFilled: 18, reachedAt: 33 },
      { playerId: "ali", lettersFilled: 17, reachedAt: 31 },
    ]);
    const after3 = play(r3);
    expect(after3).toEqual({ state: "sudden_death", players: ["ali", "sam", "max"] });

    // Sudden death between the tied players only: sam wins on time.
    const sd = resolveVsRound(18, [
      { playerId: "ali", lettersFilled: 7, reachedAt: 90 },
      { playerId: "sam", lettersFilled: 11, reachedAt: 95 },
      { playerId: "max", lettersFilled: 11, reachedAt: 99 },
    ]);
    expect(sd).toEqual({ winner: "sam", how: "timeout" });
    expect(play(sd)).toEqual({ state: "won", winner: "sam", early: false });

    expect(podium(standings()).map((p) => [p.playerId, p.place])).toEqual([
      ["sam", 1],
      ["ali", 2],
      ["max", 2],
      ["kim", 4],
      ["jo", 4],
    ]);
  });
});
