import { describe, expect, it } from "vitest";
import { parseMpPuzzle } from "../../src/rules/mold";
import { totalLeaders, totalPodium } from "../../src/rules/vs";
import {
  activeRacers,
  applyVsSubmit,
  endVsRound,
  markOut,
  newVsRound,
  newVsSeries,
  seriesDecision,
  vsRoundStartFields,
  vsSeriesResults,
  type VsRound,
  type VsSeries,
} from "../../src/rules/vs-round";
import { EXAMPLE, playback } from "./fixtures";

const T0 = 1_800_000_000_000;
const example = parseMpPuzzle(EXAMPLE);

function totalSeries(players: string[], length: 3 | 5 = 3): VsSeries {
  return newVsSeries({
    matchId: "series-1",
    length,
    heat: 1,
    racerIds: players,
    startedAt: T0,
    scoring: "total",
  });
}

/** Plays the next round the series calls for: each racer forges `words[id]`, in order, then it ends (finished if someone filled their mold). */
function play(s: VsSeries, words: Record<string, string[]>): { r: VsRound; end: ReturnType<typeof endVsRound> } {
  const d = seriesDecision(s);
  const next = d.over ? { suddenDeath: false, players: activeRacers(s) } : d.next;
  const r = newVsRound({
    round: s.played + 1,
    suddenDeath: next.suddenDeath,
    heat: 1,
    puzzle: example,
    playerIds: [...next.players],
    startsAt: T0,
    rand: playback(0.5),
  });
  for (const [id, list] of Object.entries(words)) for (const w of list) applyVsSubmit(r, id, w);
  const finished = Object.values(r.molds).some((m) => m.filled >= r.total);
  return {
    r,
    end: endVsRound(s, r, finished ? "finished" : "timeout", T0 + 60_000),
  };
}

describe("total score: the rules", () => {
  it("ranks on score, then bonus words, sharing a place only when both are equal", () => {
    const entries = [
      { playerId: "a", score: 20, bonus: 1 },
      { playerId: "b", score: 25, bonus: 0 },
      { playerId: "c", score: 20, bonus: 3 },
      { playerId: "d", score: 20, bonus: 1 },
    ];
    expect(totalLeaders(entries)).toEqual(["b"]);
    expect(totalPodium(entries).map((p) => [p.playerId, p.place])).toEqual([
      ["b", 1],
      ["c", 2],
      ["a", 3],
      ["d", 3],
    ]);
    expect(totalLeaders([entries[0]!, entries[3]!])).toEqual(["a", "d"]);
  });
});

describe("a total score series", () => {
  it("plays every round, even once the round wins are out of reach, and goes to the most letters", () => {
    const s = totalSeries(["a", "b"]);
    expect(s.scoring).toBe("total");
    play(s, { a: ["TEAR"] });
    play(s, { a: ["TEAR"], b: ["EAT"] });
    // On round wins a has clinched it; on total score it goes on.
    expect(s.racers.map((r) => r.wins)).toEqual([2, 0]);
    expect(seriesDecision(s)).toEqual({
      over: false,
      next: { round: 3, suddenDeath: false, players: ["a", "b"] },
    });

    // b fills the whole mold: the round ends there, and b's 3 + 9 beat a's 4 + 4 + 0.
    const { end } = play(s, { b: ["TEAR", "EAT", "RATE"] });
    expect(end.fields).toMatchObject({
      reason: "finished",
      winner: "b",
      scoring: "total",
      scores: { a: 8, b: 12 },
      next: null,
      standingsEndsAt: null,
    });
    expect(end.outcome).toEqual({ winner: "b", early: false, forfeit: false });

    const results = vsSeriesResults(s, end.outcome!);
    expect(results.scoring).toBe("total");
    expect(results.players.map((p) => [p.id, p.place, p.score, p.wins])).toEqual([
      ["b", 1, 12, 1],
      ["a", 2, 8, 2],
    ]);
  });

  it("breaks a tie on the most bonus words over the series", () => {
    const s = totalSeries(["a", "b"]);
    play(s, { a: ["TEAR"], b: ["TEAR", "TEA"] });
    play(s, { a: ["TEAR", "ART"], b: ["TEAR"] });
    const { end } = play(s, { a: ["TEAR"], b: ["TEAR", "ERA"] });
    expect(end.fields).toMatchObject({
      scores: { a: 12, b: 12 },
      bonusTally: { a: 1, b: 2 },
    });
    expect(end.outcome).toMatchObject({ winner: "b" });
    expect(vsSeriesResults(s, end.outcome!).players.map((p) => [p.id, p.place])).toEqual([
      ["b", 1],
      ["a", 2],
    ]);
  });

  it("goes to a tiebreaker round between the leaders when the score and the bonus words are both tied", () => {
    const s = totalSeries(["a", "b", "c"]);
    play(s, { a: ["TEAR"], b: ["TEAR"] });
    play(s, {});
    const { end } = play(s, { a: ["EAT"], b: ["EAT"] });
    // a and b are level on 7 letters and no bonus words; c, behind, watches.
    expect(end.outcome).toBeNull();
    expect(end.fields).toMatchObject({ next: { round: 4, suddenDeath: true, players: ["a", "b"] } });

    // A tiebreaker with no winner is played again by the same two, even though b found a bonus word in it.
    const again = play(s, { b: ["TEA"] });
    expect(again.r.playerIds).toEqual(["a", "b"]);
    expect(again.end.outcome).toBeNull();
    expect(again.end.fields).toMatchObject({ next: { round: 5, suddenDeath: true, players: ["a", "b"] } });

    // a wins the next one at the timer, and with it the series, ahead of b's extra bonus word.
    const last = play(s, { a: ["TEAR"] });
    expect(last.end.outcome).toEqual({ winner: "a", early: false, forfeit: false });
    const results = vsSeriesResults(s, last.end.outcome!);
    expect(results.tiebreak).toBe(true);
    expect(results.players.map((p) => [p.id, p.place, p.score])).toEqual([
      ["a", 1, 11],
      ["b", 2, 7],
      ["c", 3, 0],
    ]);
  });

  it("goes to the one tied leader left if the other leaves before the tiebreaker", () => {
    const s = totalSeries(["a", "b", "c"]);
    play(s, { a: ["TEAR"], b: ["TEAR"] });
    play(s, {});
    play(s, {});
    markOut(s, "b");
    expect(seriesDecision(s)).toEqual({ over: true, winner: "a", early: false, forfeit: false });
    expect(vsSeriesResults(s, { winner: "a", early: false, forfeit: false }).tiebreak).toBeUndefined();
  });

  it("is decided among the racers still in it, and by forfeit once only one is left", () => {
    const s = totalSeries(["a", "b", "c"]);
    play(s, { a: ["TEAR", "EAT", "RATE"] });
    markOut(s, "a");
    play(s, { b: ["TEAR"] });
    const { end } = play(s, { c: ["EAT"] });
    // a's 9 letters stay on the podium, but b leads those still racing.
    expect(end.outcome).toMatchObject({ winner: "b" });

    const t = totalSeries(["a", "b"]);
    play(t, { a: ["TEAR"] });
    markOut(t, "a");
    expect(seriesDecision(t)).toEqual({
      over: true,
      winner: "b",
      early: false,
      forfeit: true,
    });
  });

  it("tells clients the scores and bonus words so far when a round starts", () => {
    const s = totalSeries(["a", "b"]);
    play(s, { a: ["TEAR", "TEA"] });
    const r = newVsRound({
      round: 2,
      suddenDeath: false,
      heat: 1,
      puzzle: example,
      playerIds: ["a", "b"],
      startsAt: T0,
      rand: playback(0.5),
    });
    expect(vsRoundStartFields(r, s, T0)).toMatchObject({
      scoring: "total",
      scores: { a: 4, b: 0 },
      bonusTally: { a: 1, b: 0 },
      tally: { a: 1, b: 0 },
    });
  });

  it("only exists in Versus: a round-wins series and Team Versus carry none of it", () => {
    const plain = newVsSeries({
      matchId: "m",
      length: 3,
      heat: 1,
      racerIds: ["a", "b"],
      startedAt: T0,
    });
    const team = newVsSeries({
      matchId: "m",
      length: 3,
      heat: 1,
      racerIds: ["a", "b"],
      startedAt: T0,
      scoring: "total",
      teams: { rule: "first", of: { a: 0, b: 1 } },
    });
    for (const s of [plain, team]) {
      expect(s.scoring).toBeUndefined();
      const { end } = play(s, { a: ["TEAR"] });
      expect(end.fields).not.toHaveProperty("scores");
      expect(end.fields).not.toHaveProperty("scoring");
    }
  });
});
