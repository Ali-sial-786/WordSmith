import { describe, expect, it } from "vitest";
import {
  applyRunePatch,
  applyRuneSubmit,
  DEFAULT_RUNE,
  endRuneRound,
  isRuneWord,
  markRuneOut,
  MAX_TIEBREAKS,
  neighbours,
  newBoard,
  newRuneRound,
  newRuneSeries,
  parseRunePatch,
  rollGrid,
  runeDecision,
  runeSeriesResults,
  scoreRound,
  solveGrid,
  teammatesOf,
  wordPoints,
  type RuneRound,
  type RuneSeries,
} from "../../src/rules/rune";

/** A seeded generator, so boards are the same every run. */
function seeded(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

/**
 * C A T S
 * O R E X
 * D O G Z
 * QU I L T
 */
const TILES = ["C", "A", "T", "S", "O", "R", "E", "X", "D", "O", "G", "Z", "QU", "I", "L", "T"];

/** A round on {@link TILES}, for players `ids`, without rolling. */
function roundOn(ids: readonly string[], min = 3): RuneRound {
  return {
    game: "rune",
    round: 1,
    tiebreak: false,
    heat: 2,
    startsAt: 0,
    endsAt: 180_000,
    size: 4,
    min: min as 3,
    tiles: TILES,
    words: solveGrid(TILES, 4, min),
    playerIds: [...ids],
    finds: [],
  };
}

describe("settings", () => {
  it("takes known settings and refuses anything else", () => {
    expect(parseRunePatch({ size: 5, seconds: 90 })).toEqual({ size: 5, seconds: 90 });
    expect(parseRunePatch({ teamScoring: "sum", rounds: 1, min: 4 })).toEqual({ teamScoring: "sum", rounds: 1, min: 4 });
    expect(parseRunePatch({})).toBeNull();
    expect(parseRunePatch({ size: 7 })).toBeNull();
    expect(parseRunePatch({ seconds: 45 })).toBeNull();
    expect(parseRunePatch({ colour: "red" })).toBeNull();
    expect(parseRunePatch([4])).toBeNull();
    expect(applyRunePatch(DEFAULT_RUNE, { size: 4 })).toEqual({ settings: DEFAULT_RUNE, changed: false });
    expect(applyRunePatch(DEFAULT_RUNE, { size: 6 })).toEqual({ settings: { ...DEFAULT_RUNE, size: 6 }, changed: true });
  });
});

describe("the board", () => {
  it("rolls one die per tile, with QU for the Q face", () => {
    for (const size of [4, 5, 6] as const) {
      const tiles = rollGrid(size, seeded(size));
      expect(tiles).toHaveLength(size * size);
      for (const t of tiles) expect(t).toMatch(/^([A-PR-Z]|QU)$/);
    }
  });

  it("knows each tile's neighbours, diagonals included", () => {
    expect(neighbours(4)[0]).toEqual([1, 4, 5]);
    expect(neighbours(4)[5]).toEqual([0, 1, 2, 4, 6, 8, 9, 10]);
    expect(neighbours(4)[15]).toEqual([10, 11, 14]);
  });

  it("finds every word made of touching tiles, each tile once, longest first", () => {
    const words = solveGrid(TILES, 4, 3);
    // Across, down, diagonally, and with the QU tile.
    for (const w of ["CAT", "CATS", "CAR", "CORD", "ORE", "QUILT", "DOG", "GOD", "ROE"]) {
      if (isRuneWord(w.toLowerCase())) expect(words).toContain(w);
    }
    expect(words).toContain("QUILT");
    // Not touching: C and S are on opposite corners of the top row.
    expect(words).not.toContain("CASS");
    // A tile twice: there's one A.
    expect(words).not.toContain("ATTAR");
    expect(words.every((w) => w.length >= 3)).toBe(true);
    for (let i = 1; i < words.length; i++) expect(words[i - 1]!.length).toBeGreaterThanOrEqual(words[i]!.length);
    expect(solveGrid(TILES, 4, 5).every((w) => w.length >= 5)).toBe(true);
  });

  it("makes boards with plenty of words, quickly", () => {
    const started = Date.now();
    for (const size of [4, 5, 6] as const) {
      const board = newBoard(size, 3, seeded(100 + size));
      expect(board.words.length).toBeGreaterThan(20);
    }
    expect(Date.now() - started).toBeLessThan(5000);
  });

  it("scores a word its length less two, at least 1", () => {
    expect([3, 4, 5, 6, 7, 8].map((n) => wordPoints("X".repeat(n)))).toEqual([1, 2, 3, 4, 5, 6]);
  });
});

describe("a round", () => {
  it("takes words on the board once, and turns down the rest", () => {
    const r = roundOn(["ali", "sam"]);
    expect(applyRuneSubmit(r, "ali", "quilt")).toEqual({ result: "found", word: "QUILT", points: 3 });
    expect(applyRuneSubmit(r, "ali", "QUILT")).toEqual({ result: "already", word: "QUILT", by: "ali" });
    expect(applyRuneSubmit(r, "sam", "QUILT")).toEqual({ result: "found", word: "QUILT", points: 3 });
    expect(applyRuneSubmit(r, "ali", "CASS")).toEqual({ result: "invalid" });
    expect(applyRuneSubmit(r, "ali", "c4t")).toEqual({ result: "invalid" });
    const short = roundOn(["ali"], 4);
    expect(applyRuneSubmit(short, "ali", "CAT")).toEqual({ result: "invalid" });
  });

  it("doubles words nobody else found", () => {
    const r = roundOn(["ali", "sam", "kim"]);
    applyRuneSubmit(r, "ali", "QUILT"); // unique: 3 × 2
    applyRuneSubmit(r, "ali", "CAT"); // shared with sam: 1
    applyRuneSubmit(r, "sam", "CAT");
    applyRuneSubmit(r, "sam", "CATS"); // unique: 2 × 2
    const score = scoreRound(r);
    expect(score.points).toEqual({ ali: 7, sam: 5, kim: 0 });
    expect(score.found.ali).toEqual([
      { word: "QUILT", points: 6, unique: true },
      { word: "CAT", points: 1, unique: false },
    ]);
    expect(score.teamPoints).toBeUndefined();
  });

  it("pooled teams share one list: a teammate's word is already theirs, and unique means the other team missed it", () => {
    const of = { ali: 0, bo: 0, sam: 1, kim: 1 } as const;
    const s = newRuneSeries({ matchId: "m", settings: DEFAULT_RUNE, heat: 2, racerIds: ["ali", "bo", "sam", "kim"], startedAt: 0, teams: of });
    expect(teammatesOf(s, "ali")).toEqual(["bo"]);
    const r = roundOn(["ali", "bo", "sam", "kim"]);
    expect(applyRuneSubmit(r, "ali", "CAT", teammatesOf(s, "ali")).result).toBe("found");
    expect(applyRuneSubmit(r, "bo", "CAT", teammatesOf(s, "bo"))).toEqual({ result: "already", word: "CAT", by: "ali" });
    applyRuneSubmit(r, "bo", "QUILT", teammatesOf(s, "bo")); // copper only: 6
    applyRuneSubmit(r, "sam", "CAT", teammatesOf(s, "sam")); // both teams: 1 each
    applyRuneSubmit(r, "kim", "CATS", teammatesOf(s, "kim")); // cobalt only: 4
    const score = scoreRound(r, { of, scoring: "pooled" });
    expect(score.points).toEqual({ ali: 1, bo: 6, sam: 1, kim: 4 });
    expect(score.teamPoints).toEqual([7, 5]);
  });

  it("summed teams score everyone alone and add them up", () => {
    const of = { ali: 0, bo: 0, sam: 1, kim: 1 } as const;
    const r = roundOn(["ali", "bo", "sam", "kim"]);
    // Teammates can both find a word; then it isn't unique.
    applyRuneSubmit(r, "ali", "CAT");
    applyRuneSubmit(r, "bo", "CAT");
    applyRuneSubmit(r, "sam", "QUILT");
    const score = scoreRound(r, { of, scoring: "sum" });
    expect(score.points).toEqual({ ali: 1, bo: 1, sam: 6, kim: 0 });
    expect(score.teamPoints).toEqual([2, 6]);
  });
});

/** Plays a round of `s` where each player finds `words[id]`. */
function play(s: RuneSeries, words: Record<string, string[]>, now = 0): ReturnType<typeof endRuneRound> {
  const d = runeDecision(s);
  if (d.over) throw new Error("game over");
  const r = newRuneRound({ ...d.next, heat: 2, settings: s.settings, playerIds: d.next.players, startsAt: now, rand: seeded(now + 7) });
  // Stand-in board: every word given is on it.
  const board = { ...r, words: [...new Set([...r.words, ...Object.values(words).flat()])] };
  for (const [id, list] of Object.entries(words)) for (const w of list) applyRuneSubmit(board, id, w, teammatesOf(s, id));
  return endRuneRound(s, board, now, 30_000);
}

describe("a game", () => {
  it("plays every round and is won on the total", () => {
    const s = newRuneSeries({ matchId: "m", settings: { ...DEFAULT_RUNE, rounds: 3 }, heat: 2, racerIds: ["ali", "sam"], startedAt: 0 });
    const first = play(s, { ali: ["QUILT"], sam: ["CAT"] });
    expect(first.fields).toMatchObject({ round: 1, winner: "ali", points: { ali: 6, sam: 2 }, totals: { ali: 6, sam: 2 } });
    expect(first.fields.next).toEqual({ round: 2, tiebreak: false, players: ["ali", "sam"] });
    expect(first.fields.standingsEndsAt).toBe(30_000);
    expect(first.outcome).toBeNull();
    play(s, { ali: [], sam: ["QUILTS"] });
    const last = play(s, { ali: ["CAT"], sam: [] });
    expect(last.fields.next).toBeNull();
    expect(last.outcome).toEqual({ winner: "sam", early: false, forfeit: false });
    const results = runeSeriesResults(s, last.outcome!);
    expect(results).toMatchObject({ winner: "sam", scoring: "total", rounds: 3 });
    expect(results.players.map((p) => [p.id, p.place, p.score, p.wins, p.words, p.bonus])).toEqual([
      ["sam", 1, 10, 1, 2, 0],
      ["ali", 2, 8, 2, 2, 0],
    ]);
    expect(s.history.map((h) => h.round)).toEqual([1, 2, 3]);
  });

  it("goes to a tiebreaker between the tied leaders, then to the winner of it", () => {
    const s = newRuneSeries({ matchId: "m", settings: { ...DEFAULT_RUNE, rounds: 1 }, heat: 2, racerIds: ["ali", "sam", "kim"], startedAt: 0 });
    const tied = play(s, { ali: ["CATS"], sam: ["TOES"], kim: ["CAT"] });
    expect(tied.fields.winner).toBeNull();
    expect(tied.fields.next).toEqual({ round: 2, tiebreak: true, players: ["ali", "sam"] });
    const decided = play(s, { ali: [], sam: ["CAT"] });
    expect(decided.outcome).toEqual({ winner: "sam", early: false, forfeit: false });
    expect(runeSeriesResults(s, decided.outcome!).tiebreak).toBe(true);
  });

  it("shares first place after too many tiebreakers", () => {
    const s = newRuneSeries({ matchId: "m", settings: { ...DEFAULT_RUNE, rounds: 1 }, heat: 2, racerIds: ["ali", "sam"], startedAt: 0 });
    let end = play(s, {});
    for (let i = 0; i < MAX_TIEBREAKS; i++) end = play(s, {});
    expect(end.outcome).toEqual({ winner: null, early: false, forfeit: false });
    expect(runeSeriesResults(s, end.outcome!).players.map((p) => p.place)).toEqual([1, 1]);
  });

  it("ends by forfeit when only one racer is left", () => {
    const s = newRuneSeries({ matchId: "m", settings: DEFAULT_RUNE, heat: 2, racerIds: ["ali", "sam"], startedAt: 0 });
    play(s, { ali: ["CAT"], sam: ["QUILT"] });
    expect(markRuneOut(s, "sam")).toBe(true);
    expect(markRuneOut(s, "sam")).toBe(false);
    expect(runeDecision(s)).toEqual({ over: true, winner: "ali", early: false, forfeit: true });
    // Sam keeps their points on the podium.
    expect(runeSeriesResults(s, { winner: "ali", early: false, forfeit: true }).players.map((p) => [p.id, p.place, p.score])).toEqual([
      ["ali", 1, 2],
      ["sam", 1 + 1, 6],
    ]);
  });

  it("teams win on the team's total; a team with nobody left forfeits", () => {
    const of = { ali: 0, bo: 0, sam: 1, kim: 1 } as const;
    const s = newRuneSeries({ matchId: "m", settings: { ...DEFAULT_RUNE, rounds: 1, teamScoring: "sum" }, heat: 2, racerIds: ["ali", "bo", "sam", "kim"], startedAt: 0, teams: of });
    const end = play(s, { ali: ["CAT"], bo: ["CATS"], sam: ["QUILT"], kim: [] });
    expect(end.fields).toMatchObject({ team: null, teamPoints: [6, 6], teamTotals: [6, 6] });
    // Equal points, but copper found more words: copper wins.
    expect(end.outcome).toEqual({ winner: null, team: 0, early: false, forfeit: false });
    const results = runeSeriesResults(s, end.outcome!);
    expect(results.team).toBe(0);
    expect(results.players.map((p) => [p.id, p.place])).toEqual([
      ["bo", 1],
      ["ali", 1],
      ["sam", 2],
      ["kim", 2],
    ]);

    const t = newRuneSeries({ matchId: "n", settings: DEFAULT_RUNE, heat: 2, racerIds: ["ali", "bo", "sam", "kim"], startedAt: 0, teams: of });
    markRuneOut(t, "sam");
    expect(runeDecision(t).over).toBe(false);
    markRuneOut(t, "kim");
    expect(runeDecision(t)).toEqual({ over: true, winner: null, team: 0, early: false, forfeit: true });
  });
});
