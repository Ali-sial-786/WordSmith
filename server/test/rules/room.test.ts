import { describe, expect, it } from "vitest";
import {
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

  it("hold 4 in co-op (solo allowed) and 5 in Versus (2 to start)", () => {
    expect(MAX_PLAYERS).toEqual({ coop: 4, vs: 5 });
    expect(MIN_PLAYERS).toEqual({ coop: 1, vs: 2 });
  });

  it("only take newcomers in the lobby and results", () => {
    expect((["lobby", "countdown", "round", "standings", "results"] as const).map(isJoinablePhase)).toEqual([true, false, false, false, true]);
    expect((["lobby", "countdown", "round", "standings", "results"] as const).map(isPlayingPhase)).toEqual([false, true, true, true, false]);
  });

  it("keep the host while they're present", () => {
    const seats = [
      { id: "a", joinedAt: 0, present: true },
      { id: "b", joinedAt: 1, present: true },
    ];
    expect(pickHost("b", seats)).toBe("b");
  });

  it("move the host to the earliest joiner still present", () => {
    expect(
      pickHost("a", [
        { id: "c", joinedAt: 2, present: true },
        { id: "a", joinedAt: 0, present: false },
        { id: "b", joinedAt: 1, present: true },
      ]),
    ).toBe("b");
    expect(pickHost("gone", [{ id: "c", joinedAt: 5, present: true }])).toBe("c");
    expect(pickHost(null, [{ id: "c", joinedAt: 5, present: true }])).toBe("c");
    expect(pickHost("a", [{ id: "a", joinedAt: 0, present: false }])).toBeNull();
    expect(pickHost("a", [])).toBeNull();
  });

  it("size puzzles by team", () => {
    expect([0, 1, 2, 3, 4, 5].map(puzzleSizeFor)).toEqual([1, 1, 2, 3, 4, 4]);
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
