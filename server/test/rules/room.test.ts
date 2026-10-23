import { describe, expect, it } from "vitest";
import { mulberry32 } from "../../src/rules/pickups";
import {
  choosePuzzle,
  COLORS,
  freeColor,
  INVALID_LIMIT,
  isJoinablePhase,
  isPlayingPhase,
  MAX_PLAYERS,
  MIN_PLAYERS,
  LOCKOUT_MS,
  normalizeRoomCode,
  pickHost,
  puzzleSizeFor,
  RECENT_PUZZLES,
  rememberPuzzle,
  ROOM_CODE_ALPHABET,
  ROOM_CODE_RE,
  roomCodeFromBytes,
  SubmitLimiter,
} from "../../src/rules/room";

describe("room codes", () => {
  it("use 32 characters without look-alikes", () => {
    expect(ROOM_CODE_ALPHABET).toHaveLength(32);
    for (const c of "01OI") expect(ROOM_CODE_ALPHABET).not.toContain(c);
  });

  it("map bytes onto the alphabet", () => {
    expect(roomCodeFromBytes(new Uint8Array([0, 1, 2, 31, 32, 255]))).toBe("ABC9A9");
  });

  it("are 6 characters", () => {
    const code = roomCodeFromBytes(new Uint8Array([7, 8, 9, 10, 11, 12, 13, 14]));
    expect(code).toHaveLength(6);
    expect(code).toMatch(ROOM_CODE_RE);
    expect(() => roomCodeFromBytes(new Uint8Array(5))).toThrow(RangeError);
  });

  it("normalise what a player typed", () => {
    expect(normalizeRoomCode(" abc234 ")).toBe("ABC234");
    for (const bad of ["ABC23", "ABC2345", "ABC0DE", "ABC1DE", "ABCODE", "ABC-23", ""]) expect(normalizeRoomCode(bad)).toBeNull();
  });
});

describe("roomCodeFromBytes", () => {
  it("only ever uses the alphabet", () => {
    const bytes = new Uint8Array(6);
    for (let b = 0; b < 256; b++) {
      bytes.fill(b);
      expect(roomCodeFromBytes(bytes)).toMatch(ROOM_CODE_RE);
    }
  });
});

describe("seats", () => {
  it("give the lowest free colour", () => {
    expect(freeColor([])).toBe(0);
    expect(freeColor([0, 2])).toBe(1);
    expect(freeColor([1, 0, 2])).toBe(3);
    expect(freeColor([0, 1, 2, 3])).toBeNull();
    // Versus adds titanium for a fifth player.
    expect(freeColor([0, 1, 2, 3], COLORS.vs)).toBe(4);
    expect(freeColor([0, 1, 2, 3, 4], COLORS.vs)).toBeNull();
    expect(COLORS.coop).toBe(4);
  });

  it("hold 4 in co-op (solo allowed), 5 in Versus and 6 in Team Versus (2 to start)", () => {
    expect(MAX_PLAYERS).toEqual({ coop: 4, vs: 5, team: 6 });
    expect(MIN_PLAYERS).toEqual({ coop: 1, vs: 2, team: 2 });
  });

  it("only take newcomers in the lobby and results", () => {
    expect((["lobby", "countdown", "round", "standings", "results"] as const).map(isJoinablePhase)).toEqual([true, false, false, false, true]);
    expect((["lobby", "countdown", "round", "standings", "results"] as const).map(isPlayingPhase)).toEqual([false, true, true, true, false]);
  });

  it("keep the host while they're present, even dropped (they have their rejoin time)", () => {
    const seats = [
      { id: "a", joinedAt: 0, present: true, connected: true },
      { id: "b", joinedAt: 1, present: true, connected: false },
    ];
    expect(pickHost("b", seats)).toBe("b");
  });

  it("move the host to the earliest joiner still present", () => {
    expect(
      pickHost("a", [
        { id: "c", joinedAt: 2, present: true, connected: true },
        { id: "a", joinedAt: 0, present: false, connected: false },
        { id: "b", joinedAt: 1, present: true, connected: true },
      ]),
    ).toBe("b");
    expect(pickHost("gone", [{ id: "c", joinedAt: 5, present: true, connected: true }])).toBe("c");
    expect(pickHost(null, [{ id: "c", joinedAt: 5, present: true, connected: true }])).toBe("c");
    expect(pickHost("a", [{ id: "a", joinedAt: 0, present: false, connected: false }])).toBeNull();
    expect(pickHost("a", [])).toBeNull();
  });

  it("move the host to someone connected, or to anyone present if nobody is", () => {
    const seats = [
      { id: "a", joinedAt: 0, present: false, connected: false },
      { id: "b", joinedAt: 1, present: true, connected: false },
      { id: "c", joinedAt: 2, present: true, connected: true },
      { id: "d", joinedAt: 3, present: true, connected: true },
    ];
    expect(pickHost("a", seats)).toBe("c");
    expect(pickHost("a", seats.map((s) => ({ ...s, connected: false })))).toBe("b");
  });

  it("size puzzles by team", () => {
    expect([0, 1, 2, 3, 4, 5].map(puzzleSizeFor)).toEqual([1, 1, 2, 3, 4, 4]);
  });
});

describe("choosing a puzzle", () => {
  const NOW = 1_800_000_000_000;
  const SINCE = NOW - 60 * 24 * 3600_000;
  /** p0…p(n-1): p0 seen longest ago, `last` given by `seen(i)` (`null`: never). */
  const pool = (n: number, seen: (i: number) => number | null) => Array.from({ length: n }, (_, i) => ({ id: `p${i}`, last: seen(i) }));
  const runs = (candidates: { id: string; last: number | null }[], seed: number, avoid: string[] = []) => {
    const rand = mulberry32(seed);
    return Array.from({ length: 200 }, () => choosePuzzle(candidates, SINCE, avoid, rand)!);
  };

  it("picks at random among those nobody has seen lately", () => {
    // p0–p9 never seen, p10–p19 seen before the window, p20–p39 seen in it.
    const candidates = pool(40, (i) => (i < 10 ? null : i < 20 ? SINCE - 1000 * i : NOW - 1000 * i));
    const picks = runs(candidates, 1);
    expect(new Set(picks)).toEqual(new Set(candidates.slice(0, 20).map((c) => c.id)));
  });

  it("when everything was seen lately, picks at random among the third seen longest ago", () => {
    // p0 is the oldest; 40 / 3 rounds up to 14.
    const candidates = pool(40, (i) => NOW - 1000 * (40 - i));
    const shuffled = [...candidates].reverse();
    for (const seed of [1, 2, 3]) {
      const picks = runs(shuffled, seed);
      expect(new Set(picks)).toEqual(new Set(candidates.slice(0, 14).map((c) => c.id)));
    }
    // Different dice, different runs: no fixed order.
    expect(runs(shuffled, 1).slice(0, 10)).not.toEqual(runs(shuffled, 2).slice(0, 10));
    expect(choosePuzzle(pool(1, () => NOW), SINCE, [], Math.random)).toBe("p0");
    expect(choosePuzzle(pool(2, (i) => NOW - i), SINCE, [], () => 0.99)).toBe("p1");
  });

  it("leaves out the room's latest puzzles unless nothing else is left", () => {
    const candidates = pool(4, () => null);
    expect(new Set(runs(candidates, 4, ["p0", "p1", "p2"]))).toEqual(new Set(["p3"]));
    // Everything avoided: the third seen longest ago, as if none were.
    expect(new Set(runs(pool(3, (i) => NOW - i), 5, ["p0", "p1", "p2"]))).toEqual(new Set(["p2"]));
    expect(choosePuzzle([], SINCE, [], Math.random)).toBeNull();
  });

  it("remembers the room's latest puzzles, newest last", () => {
    expect(rememberPuzzle(["a", "b"], "c")).toEqual(["a", "b", "c"]);
    expect(rememberPuzzle(["a", "b", "c"], "a")).toEqual(["b", "c", "a"]);
    const full = Array.from({ length: RECENT_PUZZLES }, (_, i) => `p${i}`);
    expect(rememberPuzzle(full, "new")).toEqual([...full.slice(1), "new"]);
  });
});

describe("SubmitLimiter", () => {
  it("allows a burst of 4, then 4 a second", () => {
    const limiter = new SubmitLimiter(0);
    expect([0, 0, 0, 0, 0].map((t) => limiter.take(t))).toEqual([true, true, true, true, false]);
    expect(limiter.take(100)).toBe(false);
    expect(limiter.take(250)).toBe(true);
    expect(limiter.take(250)).toBe(false);
    // The bucket never holds more than the burst.
    expect([10_000, 10_000, 10_000, 10_000, 10_000].map((t) => limiter.take(t))).toEqual([true, true, true, true, false]);
  });

  it("locks a player out for 3 s after 10 invalid words in 5 s", () => {
    const limiter = new SubmitLimiter(0);
    for (let i = 0; i < INVALID_LIMIT - 1; i++) limiter.recordInvalid(i * 400);
    expect(limiter.locked(3600)).toBe(false);
    limiter.recordInvalid(3700);
    expect(limiter.locked(3700)).toBe(true);
    expect(limiter.take(3700 + LOCKOUT_MS - 1)).toBe(false);
    expect(limiter.take(3700 + LOCKOUT_MS)).toBe(true);
  });

  it("forgets invalid words older than 5 s", () => {
    const limiter = new SubmitLimiter(0);
    for (let i = 0; i < INVALID_LIMIT - 1; i++) limiter.recordInvalid(i * 100);
    limiter.recordInvalid(5_900);
    expect(limiter.locked(5_900)).toBe(false);
  });
});
