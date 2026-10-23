import { describe, expect, it } from "vitest";
import { parseMpPuzzle } from "../../src/rules/mold";
import {
  MAX_TEAM_SIZE,
  resolveTeamRound,
  teamForNewcomer,
  teamRoundDone,
  teamScores,
  teamSizes,
  teamsEven,
  type TeamId,
  type TeamRacerProgress,
  type TeamRule,
} from "../../src/rules/teams";
import {
  applyVsSubmit,
  endVsRound,
  markOut,
  newVsRound,
  newVsSeries,
  seriesDecision,
  stopSeries,
  teamsOf,
  vsAward,
  vsRoundDone,
  vsRoundStartFields,
  vsSeriesResults,
  wonSeries,
  type VsRound,
  type VsSeries,
} from "../../src/rules/vs-round";
import { EXAMPLE, playback } from "./fixtures";

const T0 = 1_800_000_000_000;
// TEAR (4 letters), then EAT (+2), then RATE (+3): 9 letter cells.
const example = parseMpPuzzle(EXAMPLE);

const racer = (playerId: string, team: TeamId, lettersFilled: number, reachedAt: number): TeamRacerProgress => ({
  playerId,
  team,
  lettersFilled,
  reachedAt,
});

describe("teams", () => {
  const teams = { a: 0, b: 1, c: 0 } as const;

  it("counts each team", () => {
    expect(teamSizes(teams, ["a", "b", "c"])).toEqual([2, 1]);
    expect(teamSizes(teams, ["a", "x"])).toEqual([1, 0]);
  });

  it("puts a newcomer on the smaller team, Copper on a tie, and nowhere when both are full", () => {
    expect(teamForNewcomer({}, [])).toBe(0);
    expect(teamForNewcomer({ a: 0 }, ["a"])).toBe(1);
    expect(teamForNewcomer({ a: 0, b: 1 }, ["a", "b"])).toBe(0);
    expect(teamForNewcomer({ a: 1, b: 1 }, ["a", "b"])).toBe(0);
    const full = { a: 0, b: 0, c: 0, d: 1, e: 1, f: 1 } as const;
    expect(MAX_TEAM_SIZE).toBe(3);
    expect(teamForNewcomer(full, Object.keys(full))).toBeNull();
    const { f: _, ...copperFull } = full;
    expect(teamForNewcomer(copperFull, Object.keys(copperFull))).toBe(1);
  });

  it("needs two teams of the same size, one each at least, with everyone on one", () => {
    expect(teamsEven({ a: 0, b: 1 }, ["a", "b"])).toBe(true);
    expect(teamsEven({ a: 0, b: 1, c: 0, d: 1 }, ["a", "b", "c", "d"])).toBe(true);
    expect(teamsEven({ a: 0, b: 0 }, ["a", "b"])).toBe(false);
    expect(teamsEven({ a: 0, b: 1, c: 0 }, ["a", "b", "c"])).toBe(false);
    expect(teamsEven({}, [])).toBe(false);
    expect(teamsEven({ a: 0, b: 1 }, ["a", "b", "x"])).toBe(false);
  });
});

describe("a combined round", () => {
  const rule: TeamRule = "combined";

  it("adds up each team's letters", () => {
    expect(teamScores([racer("a", 0, 4, 1), racer("c", 0, 3, 3), racer("b", 1, 6, 2)])).toEqual([7, 6]);
  });

  it("goes on until every racer on one team has filled their mold", () => {
    expect(teamRoundDone(rule, 9, [racer("a", 0, 9, 4), racer("c", 0, 6, 3), racer("b", 1, 9, 5), racer("d", 1, 2, 1)])).toBe(false);
    expect(teamRoundDone(rule, 9, [racer("a", 0, 9, 4), racer("c", 0, 9, 6), racer("b", 1, 9, 5), racer("d", 1, 2, 1)])).toBe(true);
  });

  it("is won by the team that finished", () => {
    expect(resolveTeamRound(rule, 9, [racer("a", 0, 9, 4), racer("c", 0, 9, 6), racer("b", 1, 9, 5), racer("d", 1, 8, 7)])).toEqual({
      team: 0,
      winner: null,
      how: "finished",
      scores: [18, 17],
    });
  });

  it("is won on the timer by the higher total, even against the best single racer", () => {
    // Cobalt's b filled the most, but Copper's two add up to more.
    expect(resolveTeamRound(rule, 9, [racer("a", 0, 6, 1), racer("c", 0, 4, 2), racer("b", 1, 8, 3), racer("d", 1, 0, 0)])).toEqual({
      team: 0,
      winner: null,
      how: "timeout",
      scores: [10, 8],
    });
  });

  it("breaks a tie by which team reached its total first", () => {
    // Both on 10: Copper's last letters came at 5, Cobalt's at 4.
    const tied = [racer("a", 0, 6, 5), racer("c", 0, 4, 2), racer("b", 1, 6, 4), racer("d", 1, 4, 3)];
    expect(resolveTeamRound(rule, 9, tied)).toMatchObject({ team: 1, how: "timeout", scores: [10, 10] });
  });

  it("has no winner when nobody filled anything", () => {
    expect(resolveTeamRound(rule, 9, [racer("a", 0, 0, 0), racer("b", 1, 0, 0)])).toEqual({ team: null, winner: null, how: "none", scores: [0, 0] });
  });
});

describe("a first-to-finish round", () => {
  const rule: TeamRule = "first";

  it("ends when anyone fills their mold, and their team wins", () => {
    const racers = [racer("a", 0, 6, 1), racer("c", 0, 4, 2), racer("b", 1, 9, 3), racer("d", 1, 0, 0)];
    expect(teamRoundDone(rule, 9, racers)).toBe(true);
    expect(resolveTeamRound(rule, 9, racers)).toEqual({ team: 1, winner: "b", how: "finished", scores: [10, 9] });
  });

  it("is won on the timer by the single best racer, whatever the totals", () => {
    const racers = [racer("a", 0, 6, 1), racer("c", 0, 4, 2), racer("b", 1, 7, 3), racer("d", 1, 0, 0)];
    expect(teamRoundDone(rule, 9, racers)).toBe(false);
    expect(resolveTeamRound(rule, 9, racers)).toEqual({ team: 1, winner: "b", how: "timeout", scores: [10, 7] });
  });
});

/** a and c are Copper, b and d Cobalt. */
function teamSeries(rule: TeamRule, length: 3 | 5 = 3): VsSeries {
  return newVsSeries({
    matchId: "team-1",
    length,
    heat: 1,
    racerIds: ["a", "b", "c", "d"],
    startedAt: T0,
    teams: { rule, of: { a: 0, b: 1, c: 0, d: 1 } },
  });
}

function round(players: readonly string[], n = 1, suddenDeath = false): VsRound {
  const r = newVsRound({ round: n, suddenDeath, heat: 1, puzzle: example, playerIds: players, startsAt: T0, rand: playback(0.5) });
  return { ...r, embers: [] };
}

function forge(r: VsRound, id: string, ...words: string[]): void {
  for (const w of words) applyVsSubmit(r, id, w);
}

describe("a Team Versus series", () => {
  it("starts with everyone's team, and both teams on no wins", () => {
    const s = teamSeries("combined");
    expect(s.teams).toEqual({ rule: "combined", wins: [0, 0] });
    expect(teamsOf(s)).toEqual({ a: 0, b: 1, c: 0, d: 1 });
    expect(vsRoundStartFields(round(["a", "b", "c", "d"]), s, T0)).toMatchObject({
      rule: "combined",
      teams: { a: 0, b: 1, c: 0, d: 1 },
      teamTally: [0, 0],
      tally: { a: 0, b: 0, c: 0, d: 0 },
    });
  });

  it("combined: one racer finishing isn't enough; the team wins once both have", () => {
    const s = teamSeries("combined");
    const r = round(["a", "b", "c", "d"]);
    forge(r, "a", "TEAR", "EAT", "RATE");
    forge(r, "b", "TEAR", "EAT");
    expect(vsRoundDone(s, r)).toBe(false);
    forge(r, "c", "TEAR", "EAT", "RATE");
    expect(vsRoundDone(s, r)).toBe(true);

    const end = endVsRound(s, r, "finished", T0 + 60_000);
    expect(end.fields).toMatchObject({
      winner: null,
      how: "finished",
      team: 0,
      teamScores: [18, 6],
      teamTally: [1, 0],
      rule: "combined",
      tally: { a: 1, b: 0, c: 1, d: 0 },
      next: { round: 2, suddenDeath: false, players: ["a", "b", "c", "d"] },
    });
    expect(end.outcome).toBeNull();
  });

  it("first: whoever finishes first wins it for their team", () => {
    const s = teamSeries("first");
    const r = round(["a", "b", "c", "d"]);
    forge(r, "a", "TEAR", "EAT");
    forge(r, "d", "TEAR", "EAT", "RATE");
    expect(vsRoundDone(s, r)).toBe(true);
    expect(endVsRound(s, r, "finished", T0).fields).toMatchObject({ winner: "d", how: "finished", team: 1, teamTally: [0, 1], tally: { b: 1, d: 1 } });
  });

  it("is clinched on team wins, and every racer on the winning team wins the series", () => {
    const s = teamSeries("first");
    for (const n of [1, 2]) {
      const r = round(["a", "b", "c", "d"], n);
      forge(r, "c", "TEAR", "EAT", "RATE");
      const end = endVsRound(s, r, "finished", T0);
      if (n === 2) expect(end.outcome).toEqual({ winner: null, team: 0, early: true, forfeit: false });
    }
    const results = vsSeriesResults(s, { winner: null, team: 0, early: true, forfeit: false });
    expect(results).toMatchObject({ team: 0, teamTally: [2, 0], rounds: 2 });
    expect(results.players.map((p) => [p.id, p.team, p.place, p.wins, p.rounds])).toEqual([
      ["a", 0, 1, 2, 2],
      ["c", 0, 1, 2, 2],
      ["b", 1, 2, 0, 2],
      ["d", 1, 2, 0, 2],
    ]);
    const [a, , b] = results.players;
    expect(wonSeries(results, a!)).toBe(true);
    expect(wonSeries(results, b!)).toBe(false);
    // 5 per round raced, 10 per round their team won, 30 for the series.
    expect(vsAward(a!, true, { totalXp: 0, scrapBin: 0 }, 1).amount).toBe(10 + 20 + 30);
    expect(vsAward(b!, false, { totalXp: 0, scrapBin: 0 }, 1).amount).toBe(10);
  });

  it("goes to sudden death for everyone still in it when the teams are level after the last round", () => {
    const s = teamSeries("combined");
    const winners = ["a", "b", null] as const;
    for (const [i, w] of winners.entries()) {
      const r = round(["a", "b", "c", "d"], i + 1);
      if (w !== null) forge(r, w, "TEAR");
      endVsRound(s, r, "timeout", T0);
    }
    expect(s.teams!.wins).toEqual([1, 1]);
    expect(seriesDecision(s)).toEqual({ over: false, next: { round: 4, suddenDeath: true, players: ["a", "b", "c", "d"] } });
  });

  it("is lost by forfeit when a whole team has left, and the racers who left can't win rounds", () => {
    const s = teamSeries("combined");
    markOut(s, "b");
    const r = round(["a", "b", "c", "d"]);
    forge(r, "b", "TEAR", "EAT", "RATE");
    forge(r, "d", "TEAR");
    forge(r, "a", "EAT");
    // b's letters don't count any more: Cobalt has d's 4, Copper a's 3.
    expect(endVsRound(s, r, "timeout", T0).fields).toMatchObject({ team: 1, teamScores: [3, 4], tally: { b: 0, d: 1 } });
    markOut(s, "d");
    expect(seriesDecision(s)).toEqual({ over: true, winner: null, team: 0, early: false, forfeit: true });
  });

  it("stops with no winning team when the room closes before it's decided", () => {
    const s = teamSeries("combined");
    expect(stopSeries(s)).toEqual({ winner: null, early: false, forfeit: false, team: null });
    // Places still follow the round wins so far.
    s.teams!.wins[1] = 1;
    expect(vsSeriesResults(s, stopSeries(s)).players.map((p) => [p.id, p.place])).toEqual([
      ["b", 1],
      ["d", 1],
      ["a", 2],
      ["c", 2],
    ]);
  });

  it("leaves Versus as it was", () => {
    const s = newVsSeries({ matchId: "vs", length: 3, heat: 1, racerIds: ["a", "b"], startedAt: T0 });
    expect(s).not.toHaveProperty("teams");
    const r = round(["a", "b"]);
    forge(r, "a", "TEAR", "EAT", "RATE");
    expect(vsRoundDone(s, r)).toBe(true);
    const end = endVsRound(s, r, "finished", T0);
    expect(end.fields).not.toHaveProperty("team");
    expect(end.fields).not.toHaveProperty("teams");
    expect(vsSeriesResults(s, { winner: "a", early: false, forfeit: false })).not.toHaveProperty("teamTally");
  });
});
