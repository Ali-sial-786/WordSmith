import { describe, expect, it } from "vitest";
import { parseClientMessage, parseIdentity } from "../../src/room/protocol";

describe("room parseClientMessage", () => {
  it.each([
    ['{"op":"READY","ready":true}', { op: "READY", ready: true }],
    ['{"op":"START"}', { op: "START" }],
    ['{"op":"AGAIN","extra":1}', { op: "AGAIN" }],
    ['{"op":"LEAVE"}', { op: "LEAVE" }],
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
