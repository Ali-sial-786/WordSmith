import { describe, expect, it } from "vitest";
import { cleanChatText, parseClientMessage, parseIdentity } from "../../src/room/protocol";

describe("room parseClientMessage", () => {
  it.each([
    ['{"op":"READY","ready":true}', { op: "READY", ready: true }],
    ['{"op":"START"}', { op: "START" }],
    ['{"op":"AGAIN","extra":1}', { op: "AGAIN" }],
    ['{"op":"LEAVE"}', { op: "LEAVE" }],
    ['{"op":"NEXT"}', { op: "NEXT" }],
    ['{"op":"SUBMIT","word":"tear","seq":0}', { op: "SUBMIT", word: "tear", seq: 0 }],
    ['{"op":"SUBMIT","word":"nonsense!","seq":12}', { op: "SUBMIT", word: "nonsense!", seq: 12 }],
    ['{"op":"HINT","kind":"hammer"}', { op: "HINT", hint: { kind: "hammer" } }],
    ['{"op":"HINT","kind":"sparks","x":1}', { op: "HINT", hint: { kind: "sparks" } }],
    ['{"op":"HINT","kind":"chisel","x":3,"y":0}', { op: "HINT", hint: { kind: "chisel", x: 3, y: 0 } }],
    ['{"op":"EMOTE","emote":"gg"}', { op: "EMOTE", emote: "gg" }],
    ['{"op":"CONFIG","series":3}', { op: "CONFIG", series: 3 }],
    ['{"op":"CONFIG","series":10}', { op: "CONFIG", series: 10 }],
  ])("reads %s", (raw, message) => {
    expect(parseClientMessage(raw)).toEqual({ ok: true, message });
  });

  it.each<string | ArrayBuffer>([
    new ArrayBuffer(4),
    "{",
    "null",
    "[]",
    '"START"',
    "x".repeat(1025),
    '{"op":"PING"}',
    '{"op":"DANCE"}',
    '{"ready":true}',
    '{"op":"READY"}',
    '{"op":"READY","ready":"yes"}',
    '{"op":"SUBMIT","word":"tear"}',
    '{"op":"SUBMIT","seq":1}',
    '{"op":"SUBMIT","word":"tear","seq":-1}',
    '{"op":"SUBMIT","word":"tear","seq":1.5}',
    `{"op":"SUBMIT","word":"${"a".repeat(65)}","seq":1}`,
    '{"op":"HINT"}',
    '{"op":"HINT","kind":"turn"}',
    '{"op":"HINT","kind":"chisel"}',
    '{"op":"HINT","kind":"chisel","x":10,"y":0}',
    '{"op":"HINT","kind":"chisel","x":1,"y":-1}',
    '{"op":"HINT","kind":"chisel","x":"1","y":1}',
    '{"op":"EMOTE","emote":"wave"}',
    '{"op":"EMOTE"}',
    '{"op":"CONFIG"}',
    '{"op":"CONFIG","series":4}',
    '{"op":"CONFIG","series":"5"}',
    '{"op":"CONFIG","series":5.5}',
  ])("refuses %j", (raw) => {
    expect(parseClientMessage(raw)).toEqual({ ok: false });
  });
});

describe("room parseClientMessage: Team Versus", () => {
  it.each([
    ['{"op":"TEAM","team":0}', { op: "TEAM", team: 0 }],
    ['{"op":"TEAM","team":1,"id":"u2"}', { op: "TEAM", team: 1, id: "u2" }],
    ['{"op":"CONFIG","rule":"first"}', { op: "CONFIG", rule: "first" }],
    ['{"op":"CONFIG","rule":"combined","series":5}', { op: "CONFIG", rule: "combined", series: 5 }],
    ['{"op":"CONFIG","scoring":"total"}', { op: "CONFIG", scoring: "total" }],
    ['{"op":"CONFIG","scoring":"rounds","series":7}', { op: "CONFIG", scoring: "rounds", series: 7 }],
  ])("reads %s", (raw, message) => {
    expect(parseClientMessage(raw)).toEqual({ ok: true, message });
  });

  it.each([
    '{"op":"TEAM"}',
    '{"op":"TEAM","team":2}',
    '{"op":"TEAM","team":"0"}',
    '{"op":"TEAM","team":0,"id":""}',
    '{"op":"TEAM","team":0,"id":7}',
    '{"op":"CONFIG","rule":"fastest"}',
    '{"op":"CONFIG","rule":null}',
    '{"op":"CONFIG","scoring":"points"}',
  ])("refuses %j", (raw) => {
    expect(parseClientMessage(raw)).toEqual({ ok: false });
  });
});

describe("room parseClientMessage: CONFIG with a variant (shared/survival.md)", () => {
  it.each([
    ['{"op":"CONFIG","variant":"survival"}', { op: "CONFIG", variant: "survival" }],
    ['{"op":"CONFIG","variant":"classic"}', { op: "CONFIG", variant: "classic" }],
    ['{"op":"CONFIG","variant":"survival","series":7}', { op: "CONFIG", variant: "survival", series: 7 }],
  ])("reads %s", (raw, message) => {
    expect(parseClientMessage(raw)).toEqual({ ok: true, message });
  });

  it.each(['{"op":"CONFIG","variant":"hard"}', '{"op":"CONFIG","variant":null}', '{"op":"CONFIG","variant":"survival","series":4}', '{"op":"CONFIG","variant":"Survival"}'])(
    "refuses %j",
    (raw) => {
      expect(parseClientMessage(raw)).toEqual({ ok: false });
    },
  );
});

describe("room parseClientMessage: CONFIG with a heat", () => {
  it.each([
    ['{"op":"CONFIG","heat":1}', { op: "CONFIG", heat: 1 }],
    ['{"op":"CONFIG","heat":6}', { op: "CONFIG", heat: 6 }],
    ['{"op":"CONFIG","heat":"auto"}', { op: "CONFIG", heat: "auto" }],
    ['{"op":"CONFIG","heat":4,"variant":"survival","series":5}', { op: "CONFIG", variant: "survival", series: 5, heat: 4 }],
  ])("reads %s", (raw, message) => {
    expect(parseClientMessage(raw)).toEqual({ ok: true, message });
  });

  it.each([
    '{"op":"CONFIG","heat":0}',
    '{"op":"CONFIG","heat":7}',
    '{"op":"CONFIG","heat":2.5}',
    '{"op":"CONFIG","heat":"3"}',
    '{"op":"CONFIG","heat":"Auto"}',
    '{"op":"CONFIG","heat":null}',
    '{"op":"CONFIG","heat":3,"series":4}',
  ])("refuses %j", (raw) => {
    expect(parseClientMessage(raw)).toEqual({ ok: false });
  });
});

describe("room parseClientMessage: CHAT", () => {
  it.each([
    ['{"op":"CHAT","text":"gg, again?"}', "gg, again?"],
    ['{"op":"CHAT","text":"  so\\nclose   "}', "so close"],
    ['{"op":"CHAT","text":"🔥🔥 nice"}', "🔥🔥 nice"],
  ])("reads %s", (raw, text) => {
    expect(parseClientMessage(raw)).toEqual({ ok: true, message: { op: "CHAT", text } });
  });

  it.each(['{"op":"CHAT"}', '{"op":"CHAT","text":7}', '{"op":"CHAT","text":""}', '{"op":"CHAT","text":"   "}', '{"op":"CHAT","text":"\\u202e\\u0007"}'])(
    "refuses %j",
    (raw) => {
      expect(parseClientMessage(raw)).toEqual({ ok: false });
    },
  );
});

describe("cleanChatText", () => {
  it("drops control and invisible characters, but not the joiners inside emoji", () => {
    expect(cleanChatText("a\u0000b\u202ec\u200bd")).toBe("abcd");
    expect(cleanChatText("👩\u200d🔬 ok")).toBe("👩\u200d🔬 ok");
    expect(cleanChatText("🏴\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}")).toBe("🏴\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}");
  });

  it("cuts long lines at 160 characters, emoji counting as one", () => {
    expect(cleanChatText("a".repeat(200))).toBe("a".repeat(160));
    expect([...cleanChatText("🔥".repeat(170))!]).toHaveLength(160);
    expect(cleanChatText(`${"a".repeat(159)} b`)).toBe("a".repeat(159));
  });
});

describe("parseIdentity", () => {
  it("reads what the Worker sends", () => {
    expect(parseIdentity('{"id":"u1","username":"Ali","avatar":"avatar_03","level":12}')).toEqual({
      id: "u1",
      username: "Ali",
      avatar: "avatar_03",
      level: 12,
    });
  });

  it.each([null, "", "{", "null", '{"id":"","username":"Ali","avatar":"a","level":1}', '{"id":"u","username":"Ali","avatar":"a","level":0}', '{"id":"u","avatar":"a","level":1}'])(
    "refuses %j",
    (raw) => {
      expect(parseIdentity(raw)).toBeNull();
    },
  );
});
