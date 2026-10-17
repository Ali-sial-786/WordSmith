import { describe, expect, it } from "vitest";
import { campaignPuzzle, type CampaignPuzzle } from "../../src/rules/campaign";
import {
  applyCoopHeat,
  applyCoopMelt,
  applyHint,
  applySubmit,
  coopAward,
  coopMeltAt,
  coopResults,
  newCoopRound,
  roundSnapshot,
  roundStartFields,
  type CoopRound,
} from "../../src/rules/coop-round";
import { parseMpPuzzle, type MpPuzzle } from "../../src/rules/mold";
import { mulberry32 } from "../../src/rules/pickups";
import { noHints } from "../../src/rules/progression";
import {
  applyHeatProgress,
  applySurvivalRun,
  checkSurvivalRun,
  firstClock,
  heatedFields,
  heatOrder,
  isBetterRun,
  meltAt,
  MIN_HEAT_MS,
  nextHeatedSlot,
  parseSurvivalRun,
  pauseClock,
  resumeClock,
  runScore,
  runStageLimit,
  runXp,
  survivalHeatMs,
  SURVIVAL_CAP_MS,
  SURVIVAL_GRACE_MS,
  type HeatClock,
  type SurvivalRun,
  type SurvivalState,
} from "../../src/rules/survival";
import {
  activeRacers,
  applyVsHeat,
  applyVsMelt,
  applyVsSubmit,
  endVsRound,
  markOut,
  newVsRound,
  newVsSeries,
  vsNextMelt,
  vsRoundSnapshot,
  vsRoundStartFields,
  type VsRound,
} from "../../src/rules/vs-round";
import { CROSSED, EXAMPLE, playback } from "./fixtures";

const T0 = 1_800_000_000_000;
const example = parseMpPuzzle(EXAMPLE); // 0 TEAR (4), 1 EAT (3), 2 RATE (4)
const crossed = parseMpPuzzle(CROSSED); // 0 ABC, 1 CDF, 2 DEF, 3 BAF: CDF fills in from the other three

describe("survivalHeatMs", () => {
  it("matches the contract's examples", () => {
    expect(survivalHeatMs(3, 1, 0)).toBe(21_600);
    expect(survivalHeatMs(6, 1, 0)).toBe(33_600);
    expect(survivalHeatMs(4, 6, 0)).toBe(14_400);
  });

  it("takes 3% off for each word saved, up to 20, and never goes under 8 s", () => {
    expect(survivalHeatMs(4, 5, 1)).toBe(15_520);
    expect(survivalHeatMs(4, 5, 2)).toBe(Math.round(16_000 * 0.97 * 0.97));
    expect(survivalHeatMs(8, 1, 20)).toBe(Math.round(26_000 * 1.6 * Math.pow(0.97, 20)));
    expect(survivalHeatMs(8, 1, 35)).toBe(survivalHeatMs(8, 1, 20));
    // 3 letters at White Heat after 20 saves: 6,607 ms, so the floor.
    expect(survivalHeatMs(3, 6, 20)).toBe(MIN_HEAT_MS);
    for (const heat of [1, 2, 3, 4, 5, 6] as const) {
      for (let len = 3; len <= 8; len++) expect(survivalHeatMs(len, heat, 0)).toBeGreaterThan(survivalHeatMs(len, heat, 1));
    }
  });
});

describe("heatOrder and nextHeatedSlot", () => {
  it("puts one of the shortest slots first, in a random order of all of them", () => {
    const slots = [
      { slot: 0, len: 5 },
      { slot: 1, len: 3 },
      { slot: 2, len: 4 },
      { slot: 3, len: 3 },
      { slot: 4, len: 6 },
    ];
    const firsts = new Set<number>();
    const seconds = new Set<number>();
    for (let seed = 0; seed < 200; seed++) {
      const order = heatOrder(slots, mulberry32(seed));
      expect([...order].sort()).toEqual([0, 1, 2, 3, 4]);
      expect([1, 3]).toContain(order[0]);
      firsts.add(order[0]!);
      seconds.add(order[1]!);
    }
    expect([...firsts].sort()).toEqual([1, 3]);
    expect(seconds.size).toBe(5);
    expect(heatOrder(example.slots, Math.random)[0]).toBe(1); // EAT is the only 3-letter word
  });

  it("heats the first slot in the order that isn't complete", () => {
    expect(nextHeatedSlot([2, 0, 1], new Set())).toBe(2);
    expect(nextHeatedSlot([2, 0, 1], new Set([2, 1]))).toBe(0);
    expect(nextHeatedSlot([2, 0, 1], new Set([0, 1, 2]))).toBeNull();
  });
});

describe("a mold's countdown", () => {
  const lenOf = (slot: number) => example.slots[slot]!.len;

  it("starts with the round, and moves on when the heated slot completes", () => {
    const clock = firstClock([1, 0, 2], lenOf, 1, T0);
    expect(clock).toEqual({ slot: 1, startsAt: T0, deadline: T0 + 21_600, durationMs: 21_600, saved: 0, pausedAt: null });
    expect(meltAt(clock)).toBe(T0 + 21_600 + SURVIVAL_GRACE_MS);
    // Another slot completing changes nothing.
    expect(applyHeatProgress(clock, [1, 0, 2], new Set([0]), lenOf, 1, T0 + 5000)).toBe(false);
    expect(clock.slot).toBe(1);
    // The heated one: saved, and the next one not yet complete heats up from now.
    expect(applyHeatProgress(clock, [1, 0, 2], new Set([0, 1]), lenOf, 1, T0 + 9000)).toBe(true);
    expect(clock).toEqual({ slot: 2, startsAt: T0 + 9000, deadline: T0 + 9000 + survivalHeatMs(4, 1, 1), durationMs: survivalHeatMs(4, 1, 1), saved: 1, pausedAt: null });
    expect(heatedFields(clock, T0 + 9001)).toEqual({ slot: 2, startsAt: T0 + 9000, deadline: clock.deadline, durationMs: clock.durationMs, saved: 1, serverNow: T0 + 9001 });
    // The last one: nothing glows any more.
    expect(applyHeatProgress(clock, [1, 0, 2], new Set([0, 1, 2]), lenOf, 1, T0 + 12_000)).toBe(true);
    expect(clock).toMatchObject({ slot: null, saved: 2 });
    expect(meltAt(clock)).toBeNull();
    expect(heatedFields(clock, T0)).toBeNull();
  });

  it("pauses, and moves the deadline on by the pause when it resumes", () => {
    const clock = firstClock([1, 0, 2], lenOf, 1, T0);
    expect(resumeClock(clock, T0)).toBe(false);
    expect(pauseClock(clock, T0 + 1000)).toBe(true);
    expect(pauseClock(clock, T0 + 2000)).toBe(false);
    expect(meltAt(clock)).toBeNull();
    expect(resumeClock(clock, T0 + 6000)).toBe(true);
    expect(clock).toMatchObject({ startsAt: T0 + 5000, deadline: T0 + 5000 + 21_600, durationMs: 21_600, pausedAt: null });

    // A pause during the round's countdown phase only counts from the start.
    const early = firstClock([1, 0, 2], lenOf, 1, T0);
    pauseClock(early, T0 - 2000);
    resumeClock(early, T0 - 1000);
    expect(early.deadline).toBe(T0 + 21_600);
    pauseClock(early, T0 - 2000);
    resumeClock(early, T0 + 3000);
    expect(early.deadline).toBe(T0 + 3000 + 21_600);

    // Once the melt is due, a pause can't save it.
    const late = firstClock([1, 0, 2], lenOf, 1, T0);
    expect(pauseClock(late, T0 + 21_600 + SURVIVAL_GRACE_MS)).toBe(false);
    expect(pauseClock(late, T0 + 21_600 + SURVIVAL_GRACE_MS - 1)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Co-op
// ---------------------------------------------------------------------------

/** A survival round of `puzzle` for `a` and `b` with no embers, heating in `order`. */
function coopRound(puzzle: MpPuzzle, order: number[]): CoopRound {
  const r = newCoopRound({ round: 1, heat: 1, matchId: "m", puzzle, playerIds: ["a", "b"], startsAt: T0, rand: playback(0.5), variant: "survival" });
  const lenOf = (slot: number) => puzzle.slots[slot]!.len;
  return { ...r, embers: [], survival: { order, clock: firstClock(order, lenOf, 1, T0), melted: null } };
}

describe("co-op survival rounds", () => {
  it("cap the round at 10 minutes and tell everyone the first heated word", () => {
    for (let seed = 0; seed < 20; seed++) {
      const r = newCoopRound({ round: 1, heat: 3, matchId: "m", puzzle: example, playerIds: ["a"], startsAt: T0, rand: mulberry32(seed), variant: "survival" });
      expect(r.endsAt - r.startsAt).toBe(SURVIVAL_CAP_MS);
      expect(r.survival!.order[0]).toBe(1);
      expect([...r.survival!.order].sort()).toEqual([0, 1, 2]);
      expect(r.survival!.clock).toEqual({ slot: 1, startsAt: T0, deadline: T0 + survivalHeatMs(3, 3, 0), durationMs: survivalHeatMs(3, 3, 0), saved: 0, pausedAt: null });
      expect(roundStartFields(r, T0 - 3000)).toMatchObject({
        endsAt: T0 + SURVIVAL_CAP_MS,
        variant: "survival",
        heated: { slot: 1, startsAt: T0, deadline: r.survival!.clock.deadline, durationMs: r.survival!.clock.durationMs, saved: 0, serverNow: T0 - 3000 },
      });
    }
    // A classic round has none of it, and draws the same letters and embers as before.
    const classic = newCoopRound({ round: 1, heat: 3, matchId: "m", puzzle: example, playerIds: ["a"], startsAt: T0, rand: mulberry32(7) });
    const same = newCoopRound({ round: 1, heat: 3, matchId: "m", puzzle: example, playerIds: ["a"], startsAt: T0, rand: mulberry32(7), variant: "survival" });
    expect(classic.survival).toBeUndefined();
    expect([classic.letters, classic.embers]).toEqual([same.letters, same.embers]);
    expect(Object.keys(roundStartFields(classic, T0))).not.toContain("variant");
    expect(Object.keys(coopResults(classic, "timeout", T0))).not.toContain("variant");
  });

  it("move the heat on when the heated word is forged, and not for other words", () => {
    const r = coopRound(example, [1, 2, 0]);
    applySubmit(r, "a", "TEAR");
    expect(applyCoopHeat(r, T0 + 4000)).toBe(false);
    applySubmit(r, "b", "EAT");
    expect(applyCoopHeat(r, T0 + 8000)).toBe(true);
    expect(r.survival!.clock).toEqual({ slot: 2, startsAt: T0 + 8000, deadline: T0 + 8000 + survivalHeatMs(4, 1, 1), durationMs: survivalHeatMs(4, 1, 1), saved: 1, pausedAt: null });
    expect(coopMeltAt(r)).toBe(r.survival!.clock.deadline + SURVIVAL_GRACE_MS);
    // The last word: saved, and nothing glows.
    expect(applySubmit(r, "a", "RATE")).toMatchObject({ complete: true });
    expect(applyCoopHeat(r, T0 + 9000)).toBe(true);
    expect(r.survival!.clock).toMatchObject({ slot: null, saved: 2 });
    expect(coopMeltAt(r)).toBeNull();
    expect(coopResults(r, "complete", T0 + 9000)).toMatchObject({ reason: "complete", variant: "survival", saved: 2, melted: null, stars: 3 });
  });

  it("count a heated word completed by crossings or by hints as saved", () => {
    // CDF fills in once ABC, DEF and BAF are forged.
    const r = coopRound(crossed, [1, 0, 2, 3]);
    applySubmit(r, "a", "ABC");
    applySubmit(r, "a", "DEF");
    expect(applyCoopHeat(r, T0 + 1000)).toBe(false);
    expect(applySubmit(r, "b", "BAF")).toMatchObject({ auto: [{ slot: 1, word: "CDF" }], complete: true });
    expect(applyCoopHeat(r, T0 + 2000)).toBe(true);
    expect(r.survival!.clock).toMatchObject({ slot: null, saved: 1 });

    // EAT's last two letters shown by Chisels.
    const h = coopRound(example, [1, 2, 0]);
    applySubmit(h, "a", "TEAR");
    applyHint(h, "b", { kind: "chisel", x: 1, y: 1 }, playback(0));
    expect(applyCoopHeat(h, T0 + 1000)).toBe(false);
    expect(applyHint(h, "b", { kind: "chisel", x: 1, y: 2 }, playback(0))).toMatchObject({ auto: [{ slot: 1, word: "EAT" }] });
    expect(applyCoopHeat(h, T0 + 2000)).toBe(true);
    expect(h.survival!.clock).toMatchObject({ slot: 2, saved: 1, startsAt: T0 + 2000 });
  });

  it("end melted, scored as a timeout, with the melted slot and the team's saves", () => {
    const r = coopRound(example, [1, 2, 0]);
    applySubmit(r, "a", "EAT");
    applyCoopHeat(r, T0 + 5000);
    expect(roundSnapshot(r, T0 + 6000)).toMatchObject({ variant: "survival", saved: 1, heated: { slot: 2, saved: 1, serverNow: T0 + 6000 } });
    expect(applyCoopMelt(r)).toBe(2);
    expect(coopMeltAt(r)).toBeNull();
    expect(applyCoopHeat(r, T0 + 7000)).toBe(false);
    const results = coopResults(r, "melted", T0 + 40_000);
    expect(results).toMatchObject({ reason: "melted", variant: "survival", saved: 1, melted: { slot: 2 }, filled: 3, stars: 0 });
    expect(roundSnapshot(r, T0 + 41_000, false)).toMatchObject({ heated: null, saved: 1 });
  });

  it("pay 2 XP per word saved on top of co-op XP, up to +30", () => {
    const player = { id: "a", points: 40, words: 1, longest: "TEAR", bonus: 0 };
    const profile = { totalXp: 0, scrapBin: 0 };
    expect(coopAward(player, { reason: "melted", mvp: "a", saved: 4 }, profile).amount).toBe(20 + 4 + 10 + 8);
    expect(coopAward(player, { reason: "complete", mvp: null, saved: 20 }, profile).amount).toBe(20 + 4 + 20 + 30);
    expect(coopAward(player, { reason: "timeout", mvp: null }, profile).amount).toBe(24);
  });
});

// ---------------------------------------------------------------------------
// Versus
// ---------------------------------------------------------------------------

function vsRound(players: string[], order = [1, 2, 0]): VsRound {
  const r = newVsRound({ round: 1, suddenDeath: false, heat: 1, puzzle: example, playerIds: players, startsAt: T0, rand: playback(0.5), variant: "survival" });
  const lenOf = (slot: number) => example.slots[slot]!.len;
  return { ...r, embers: [], survival: { order, clocks: Object.fromEntries(players.map((id) => [id, firstClock(order, lenOf, 1, T0)])), melted: null } };
}

describe("Versus survival rounds", () => {
  it("give every racer the same first heated word, on their own mold", () => {
    const r = newVsRound({ round: 1, suddenDeath: false, heat: 2, puzzle: example, playerIds: ["a", "b"], startsAt: T0, rand: mulberry32(3), variant: "survival" });
    expect(r.endsAt - r.startsAt).toBe(SURVIVAL_CAP_MS);
    expect(r.survival!.clocks.a).toEqual(r.survival!.clocks.b);
    expect(r.survival!.clocks.a).toMatchObject({ slot: 1, durationMs: survivalHeatMs(3, 2, 0) });
    const s = newVsSeries({ matchId: "s", length: 3, heat: 2, racerIds: ["a", "b"], startedAt: T0, variant: "survival" });
    expect(s.variant).toBe("survival");
    expect(vsRoundStartFields(r, s, T0)).toMatchObject({ variant: "survival", heated: { slot: 1, startsAt: T0, saved: 0 } });
    expect(newVsSeries({ matchId: "s", length: 3, heat: 2, racerIds: ["a"], startedAt: T0 })).not.toHaveProperty("variant");
  });

  it("move each racer's heat on by their own words", () => {
    const r = vsRound(["a", "b"]);
    applyVsSubmit(r, "a", "EAT");
    expect(applyVsHeat(r, "a", T0 + 3000)).toBe(true);
    expect(applyVsHeat(r, "b", T0 + 3000)).toBe(false);
    expect(r.survival!.clocks.a).toMatchObject({ slot: 2, saved: 1, startsAt: T0 + 3000 });
    expect(r.survival!.clocks.b).toMatchObject({ slot: 1, saved: 0, startsAt: T0 });
    const s = newVsSeries({ matchId: "s", length: 3, heat: 1, racerIds: ["a", "b", "c"], startedAt: T0, variant: "survival" });
    expect(vsRoundSnapshot(r, s, "a", T0 + 4000)).toMatchObject({ heated: { slot: 2, saved: 1 }, saved: 1 });
    expect(vsRoundSnapshot(r, s, "c", T0 + 4000)).toMatchObject({ heated: null, saved: 0 });
  });

  it("melt the earliest deadline first, among racers still in the series", () => {
    const r = vsRound(["a", "b", "c"]);
    // B saved one word late on, so B's countdown runs longest; A and C tie, and A comes first.
    applyVsSubmit(r, "b", "EAT");
    applyVsHeat(r, "b", T0 + 15_000);
    const first = T0 + 21_600 + SURVIVAL_GRACE_MS;
    expect(vsNextMelt(r, ["a", "b", "c"])).toEqual({ id: "a", slot: 1, at: first });
    expect(vsNextMelt(r, ["b", "c"])).toEqual({ id: "c", slot: 1, at: first });
    pauseClock(r.survival!.clocks.c!, T0 + 1000);
    expect(vsNextMelt(r, ["b", "c"])).toMatchObject({ id: "b" });
    expect(applyVsMelt(r, "b")).toBe(true);
    expect(r.survival!.melted).toEqual({ id: "b", slot: 2 });
    expect(vsNextMelt(r, ["a", "b", "c"])).toBeNull();
  });

  it("go to the racer with the most letters among those who didn't melt (`survived`), or nobody", () => {
    const players = ["a", "b", "c"];
    const s = newVsSeries({ matchId: "s", length: 3, heat: 1, racerIds: players, startedAt: T0, variant: "survival" });
    const r = vsRound(players);
    // A has the most letters but melts; B and C tie on EAT, and C got there first.
    applyVsSubmit(r, "a", "TEAR");
    applyVsSubmit(r, "a", "RATE");
    applyVsSubmit(r, "c", "EAT");
    applyVsSubmit(r, "b", "EAT");
    applyVsMelt(r, "a");
    const end = endVsRound(s, r, "melted", T0 + 30_000);
    expect(end.fields).toMatchObject({
      reason: "melted",
      winner: "c",
      how: "survived",
      variant: "survival",
      saved: { a: 0, b: 0, c: 0 },
      melted: { id: "a", slot: 1 },
      tally: { a: 0, b: 0, c: 1 },
    });
    // Everyone's mold as it was when a melted, theirs included.
    expect(end.fields.molds).toEqual({ a: [0, 2], b: [1], c: [1] });

    // Nobody else has a letter: no winner.
    const s2 = newVsSeries({ matchId: "s2", length: 3, heat: 1, racerIds: ["a", "b"], startedAt: T0, variant: "survival" });
    const r2 = vsRound(["a", "b"]);
    applyVsSubmit(r2, "a", "TEAR");
    applyVsMelt(r2, "b");
    expect(endVsRound(s2, r2, "melted", T0).fields).toMatchObject({ winner: "a", how: "survived" });
    const r3 = vsRound(["a", "b"]);
    applyVsSubmit(r3, "b", "TEAR");
    applyVsMelt(r3, "b");
    expect(endVsRound(s2, r3, "melted", T0).fields).toMatchObject({ winner: null, how: "none", melted: { id: "b", slot: 1 } });

    // At the 10-minute cap it's a timeout as usual; someone out of the series can't win.
    const s4 = newVsSeries({ matchId: "s4", length: 3, heat: 1, racerIds: ["a", "b"], startedAt: T0, variant: "survival" });
    const r4 = vsRound(["a", "b"]);
    applyVsSubmit(r4, "a", "TEAR");
    applyVsSubmit(r4, "b", "EAT");
    markOut(s4, "a");
    expect(activeRacers(s4)).toEqual(["b"]);
    expect(endVsRound(s4, r4, "timeout", T0 + SURVIVAL_CAP_MS).fields).toMatchObject({ reason: "timeout", winner: "b", how: "timeout", melted: null });
  });
});

// ---------------------------------------------------------------------------
// The Crucible
// ---------------------------------------------------------------------------

const NOW = Date.UTC(2026, 9, 17, 12);

/** A campaign puzzle for `stage`: AAA, BBB, … on separate rows (3 cells each). */
function synthetic(stage: number, words: number): CampaignPuzzle {
  return campaignPuzzle(stage, {
    id: `c-${String(stage).padStart(4, "0")}`,
    letters: "ABC",
    words: Array.from({ length: words }, (_, i) => ({ w: String.fromCharCode(65 + i).repeat(3), x: 0, y: 2 * i, d: "a" })),
    bonus: [],
  });
}

const PUZZLES = new Map([1, 2, 3, 12, 40].map((stage) => [stage, synthetic(stage, 3)]));

function run(overrides: Partial<SurvivalRun> = {}): SurvivalRun {
  return {
    runId: "0b9e5a7c-3d4e-4f60-8a1b-2c3d4e5f6a7b",
    startedAt: NOW - 600_000,
    endedAt: NOW - 300_000,
    saved: 4,
    puzzles: [
      { stage: 1, puzzleId: "c-0001", foundWords: ["AAA", "BBB", "CCC"], hintsUsed: noHints(), cleared: true },
      { stage: 12, puzzleId: "c-0012", foundWords: ["AAA"], hintsUsed: { hammer: 1, chisel: 0, sparks: 0 }, cleared: false },
    ],
    ...overrides,
  };
}

function state(overrides: Partial<SurvivalState> = {}): SurvivalState {
  return { totalXp: 0, hints: { hammer: 3, chisel: 0, sparks: 0 }, wordsForged: 0, longestWord: "", best: null, ...overrides };
}

describe("parseSurvivalRun", () => {
  it("reads the app's body; hintsUsed may be left out", () => {
    const raw = { ...run(), puzzles: [{ stage: 2, puzzleId: "c-0002", foundWords: ["aaa"], cleared: false, extra: 1 }] };
    expect(parseSurvivalRun(raw)).toEqual({
      ok: true,
      run: { ...run(), puzzles: [{ stage: 2, puzzleId: "c-0002", foundWords: ["aaa"], hintsUsed: noHints(), cleared: false }] },
    });
  });

  it.each([
    [{ runId: "" }, "runId"],
    [{ runId: "has space" }, "runId"],
    [{ runId: "x".repeat(65) }, "runId"],
    [{ startedAt: "soon" }, "startedAt"],
    [{ endedAt: 1.5 }, "endedAt"],
    [{ saved: -1 }, "saved"],
    [{ puzzles: {} }, "puzzles"],
    [{ puzzles: Array.from({ length: 51 }, () => run().puzzles[0]) }, "puzzles: more than 50"],
    [{ puzzles: [7] }, "puzzles[0]"],
    [{ puzzles: [{ ...run().puzzles[0], stage: 0 }] }, "puzzles[0].stage"],
    [{ puzzles: [{ ...run().puzzles[0], puzzleId: 12 }] }, "puzzles[0].puzzleId"],
    [{ puzzles: [{ ...run().puzzles[0], foundWords: "AAA" }] }, "puzzles[0].foundWords"],
    [{ puzzles: [{ ...run().puzzles[0], hintsUsed: { hammer: -1 } }] }, "puzzles[0].hintsUsed.hammer"],
    [{ puzzles: [{ ...run().puzzles[0], cleared: "yes" }] }, "puzzles[0].cleared"],
  ])("refuses %j", (overrides, detail) => {
    expect(parseSurvivalRun({ ...run(), ...overrides })).toEqual({ ok: false, detail });
  });
});

describe("checkSurvivalRun", () => {
  it("accepts a run that adds up", () => {
    expect(checkSurvivalRun(run(), PUZZLES, 0, NOW)).toBeNull();
    // A cleared puzzle may have had help from hints: two words typed, one shown by a Spark Shower.
    const hinted = run({ saved: 3, puzzles: [{ stage: 1, puzzleId: "c-0001", foundWords: ["AAA", "BBB"], hintsUsed: { hammer: 0, chisel: 0, sparks: 1 }, cleared: true }] });
    expect(checkSurvivalRun(hinted, PUZZLES, 0, NOW)).toBeNull();
    // An empty run is fine too.
    expect(checkSurvivalRun(run({ puzzles: [], saved: 0 }), PUZZLES, 0, NOW)).toBeNull();
  });

  it.each<[string, Partial<SurvivalRun>, number, string]>([
    ["a stage that isn't in the campaign", { puzzles: [{ ...run().puzzles[0]!, stage: 5 }] }, 0, "puzzles[0]: stage 5 isn't in the campaign"],
    ["another stage's puzzle", { puzzles: [{ ...run().puzzles[0]!, puzzleId: "c-0002" }] }, 0, "puzzles[0]: puzzleId isn't stage 1's"],
    ["a stage beyond max(highest + 10, 30)", { puzzles: [{ ...run().puzzles[0]!, stage: 40, puzzleId: "c-0040" }] }, 29, "puzzles[0]: stage 40 is beyond 39"],
    ["a word that isn't a grid word", { puzzles: [{ ...run().puzzles[0]!, foundWords: ["AAA", "ZZZ"] }] }, 0, "puzzles[0]: a found word isn't a grid word"],
    ["a word that isn't A–Z", { puzzles: [{ ...run().puzzles[0]!, foundWords: ["A-A"] }] }, 0, "puzzles[0]: a found word isn't a grid word"],
    ["a cleared puzzle that can't be full", { puzzles: [{ ...run().puzzles[0]!, foundWords: ["AAA", "BBB"] }] }, 0, "puzzles[0]: incomplete"],
    ["times out of order", { endedAt: NOW - 700_000 }, 0, "endedAt is before startedAt"],
    ["a run more than 24 h old", { startedAt: NOW - 24 * 3600_000 - 1 }, 0, "the run is more than 24 h old"],
    ["a run in the future", { endedAt: NOW + 10 * 60_000 + 1 }, 0, "the run ends in the future"],
    ["under 1 s per found word", { startedAt: NOW - 300_000 - 3999 }, 0, "too_fast"],
    ["more saves than words", { saved: 7 }, 0, "saved is more than the run's words"],
  ])("refuses %s", (_name, overrides, highest, detail) => {
    expect(checkSurvivalRun(run(overrides), PUZZLES, highest, NOW)).toBe(detail);
  });

  it("lets a run reach 30 stages, or 10 past the highest stage played", () => {
    expect(runStageLimit(0)).toBe(30);
    expect(runStageLimit(20)).toBe(30);
    expect(runStageLimit(30)).toBe(40);
    const far = run({ saved: 3, puzzles: [{ ...run().puzzles[0]!, stage: 40, puzzleId: "c-0040" }] });
    expect(checkSurvivalRun(far, PUZZLES, 30, NOW)).toBeNull();
    // Exactly 1 s per word is enough.
    expect(checkSurvivalRun(run({ startedAt: NOW - 304_000 }), PUZZLES, 0, NOW)).toBeNull();
  });
});

describe("a run's XP and best", () => {
  it("pays 1 per grid word and 8 per cleared puzzle, at most 150", () => {
    expect(runScore(run())).toEqual({ puzzles: 1, words: 4, saved: 4 });
    expect(runXp(runScore(run()))).toBe(4 + 8);
    expect(runXp({ puzzles: 15, words: 40, saved: 0 })).toBe(150);
    expect(runXp({ puzzles: 0, words: 0, saved: 0 })).toBe(0);
    // A word typed twice in a puzzle counts once; in two puzzles, twice.
    const twice = run({ puzzles: [{ ...run().puzzles[0]!, foundWords: ["aaa", "AAA", "BBB", "CCC"] }, { ...run().puzzles[1]!, foundWords: ["AAA"] }] });
    expect(runScore(twice).words).toBe(4);
  });

  it("ranks runs by puzzles cleared, then words, then saves", () => {
    const best = { puzzles: 3, words: 20, saved: 5 };
    expect(isBetterRun(best, null)).toBe(true);
    expect(isBetterRun({ puzzles: 4, words: 1, saved: 0 }, best)).toBe(true);
    expect(isBetterRun({ puzzles: 3, words: 21, saved: 0 }, best)).toBe(true);
    expect(isBetterRun({ puzzles: 3, words: 20, saved: 6 }, best)).toBe(true);
    expect(isBetterRun(best, best)).toBe(false);
    expect(isBetterRun({ puzzles: 2, words: 99, saved: 99 }, best)).toBe(false);
  });

  it("takes the hints off the stock without going below zero, and keeps the best run", () => {
    const hinted = run({
      puzzles: [
        { ...run().puzzles[0]!, hintsUsed: { hammer: 2, chisel: 1, sparks: 0 } },
        { ...run().puzzles[1]!, hintsUsed: { hammer: 2, chisel: 0, sparks: 0 } },
      ],
    });
    const award = applySurvivalRun(state({ totalXp: 50 }), hinted);
    // 12 XP takes 50 to 62: level 2, with its Hammer Strike after the hints came off.
    expect(award).toMatchObject({ xp: 12, award: { level: 2, levelsGained: 1 }, hintsClamped: { hammer: 1, chisel: 1, sparks: 0 }, newBest: true });
    expect(award.state).toEqual({
      totalXp: 62,
      hints: { hammer: 1, chisel: 0, sparks: 0 },
      wordsForged: 4,
      longestWord: "AAA",
      best: { puzzles: 1, words: 4, saved: 4, at: hinted.endedAt },
    });
    expect(award.facts).toEqual({ soloPuzzles: 1, forged: ["AAA", "BBB", "CCC", "AAA"] });

    const better = { puzzles: 2, words: 0, saved: 0, at: 1 };
    const worse = applySurvivalRun(state({ best: better }), run());
    expect(worse).toMatchObject({ newBest: false, hintsClamped: null, state: { best: better, hints: { hammer: 2 } } });
  });
});

describe("clocks stay plain JSON", () => {
  it("survive a trip through storage", () => {
    const clock: HeatClock = firstClock([1], () => 3, 1, T0);
    pauseClock(clock, T0 + 1);
    expect(JSON.parse(JSON.stringify(clock))).toEqual(clock);
  });
});
