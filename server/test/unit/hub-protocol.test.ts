import { describe, expect, it } from "vitest";
import { parseClientMessage, parseStatus, RateLimiter } from "../../src/hub/protocol";

describe("parseStatus", () => {
  it.each(["online", "solo", "in_room:ABC234", "in_room:XYZ999"])("allows %s", (s) => {
    expect(parseStatus(s)).toBe(s);
  });
  it.each(["offline", "away", "in_room:", "in_room:abc234", "in_room:ABC23", "in_room:ABC2345", "in_room:AB-234", 7, null])(
    "refuses %j",
    (s) => {
      expect(parseStatus(s)).toBeNull();
    },
  );
});

describe("parseClientMessage", () => {
  it("reads SET_STATUS and INVITE", () => {
    expect(parseClientMessage('{"op":"SET_STATUS","status":"solo"}')).toEqual({ ok: true, message: { op: "SET_STATUS", status: "solo" } });
    expect(parseClientMessage(JSON.stringify({ op: "INVITE", to: "u1", code: "ABC234", mode: "vs", extra: 1 }))).toEqual({
      ok: true,
      message: { op: "INVITE", to: "u1", code: "ABC234", mode: "vs" },
    });
  });

  it.each<[string | ArrayBuffer, string]>([
    [new ArrayBuffer(4), "bad_message"],
    ["{", "bad_message"],
    ["null", "bad_message"],
    ['"SET_STATUS"', "bad_message"],
    ["x".repeat(1025), "bad_message"],
    ['{"op":"HELLO"}', "unknown_op"],
    ['{"status":"solo"}', "unknown_op"],
    ['{"op":"SET_STATUS"}', "bad_status"],
    ['{"op":"INVITE","to":"","code":"ABC234","mode":"vs"}', "bad_invite"],
    ['{"op":"INVITE","to":"u","code":"abc234","mode":"vs"}', "bad_invite"],
    ['{"op":"INVITE","to":"u","code":"ABC234","mode":"solo"}', "bad_invite"],
    ['{"op":"INVITE","code":"ABC234","mode":"coop"}', "bad_invite"],
  ])("refuses %j with %s", (raw, code) => {
    expect(parseClientMessage(raw)).toEqual({ ok: false, code });
  });
});

describe("RateLimiter", () => {
  it("allows a burst, then refills over time", () => {
    const limiter = new RateLimiter(3, 1, 0);
    expect([limiter.take(0), limiter.take(0), limiter.take(0), limiter.take(0)]).toEqual([true, true, true, false]);
    expect(limiter.take(500)).toBe(false);
    expect(limiter.take(1000)).toBe(true);
    expect(limiter.take(1000)).toBe(false);
    expect([limiter.take(60_000), limiter.take(60_000), limiter.take(60_000), limiter.take(60_000)]).toEqual([true, true, true, false]);
  });
});
