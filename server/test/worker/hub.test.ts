import { evictDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { hub } from "../../src/routes/context";
import { befriend, request, setUpClient, type Client } from "./helpers";

type Message = Record<string, unknown> & { op: string };

interface Socket {
  readonly ws: WebSocket;
  readonly protocol: string | null;
  /** Every message received so far. */
  readonly seen: Message[];
  /** Resolves with the next unread message matching `match` (waiting up to 2 s). */
  next(match?: Partial<Message>): Promise<Message>;
  /** All unread messages up to and including an ERROR, provoked by an invalid message. */
  drain(): Promise<Message[]>;
  send(message: unknown): void;
  closed: Promise<{ code: number; reason: string }>;
}

async function connect(c: Client, how: "protocol" | "bearer" = "protocol"): Promise<Socket> {
  const headers: Record<string, string> =
    how === "protocol"
      ? { upgrade: "websocket", "sec-websocket-protocol": `wordsmith.v1, ${c.token}` }
      : { upgrade: "websocket", authorization: `Bearer ${c.token}` };
  const res = await request("/v1/ws/hub", { headers });
  if (res.status !== 101) throw new Error(`upgrade failed: ${res.status} ${await res.text()}`);
  const ws = res.webSocket!;
  ws.accept();

  const seen: Message[] = [];
  let read = 0;
  let wake: (() => void) | null = null;
  ws.addEventListener("message", (e) => {
    seen.push(JSON.parse(e.data as string) as Message);
    wake?.();
  });
  const closed = new Promise<{ code: number; reason: string }>((resolve) =>
    ws.addEventListener("close", (e) => resolve({ code: e.code, reason: e.reason })),
  );

  const matches = (m: Message, want: Partial<Message>) => Object.entries(want).every(([k, v]) => m[k] === v);
  const next = async (want: Partial<Message> = {}): Promise<Message> => {
    const deadline = Date.now() + 2000;
    for (;;) {
      while (read < seen.length) {
        const m = seen[read++]!;
        if (matches(m, want)) return m;
      }
      if (Date.now() > deadline) throw new Error(`no message matching ${JSON.stringify(want)}; saw ${JSON.stringify(seen)}`);
      await new Promise<void>((resolve) => {
        wake = resolve;
        setTimeout(resolve, 50);
      });
    }
  };

  return {
    ws,
    protocol: res.headers.get("sec-websocket-protocol"),
    seen,
    next,
    async drain() {
      // The hub handles messages in order, so the reply to this comes after
      // anything it sent this socket before.
      const from = read;
      ws.send(JSON.stringify({ op: "SET_STATUS", status: "not-a-status" }));
      await next({ op: "ERROR", code: "bad_status" });
      return seen.slice(from, read - 1);
    },
    send: (message) => ws.send(typeof message === "string" ? message : JSON.stringify(message)),
    closed,
  };
}

const presence = (userId: string, status: string) => ({ op: "PRESENCE", userId, status });

describe("HubDO presence", () => {
  it("shows friends to each other as they come and go", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    await befriend(a, b);

    const sa = await connect(a);
    expect(sa.protocol).toBe("wordsmith.v1");
    // Nobody's online yet, so the snapshot is just the (empty) open rooms.
    expect(await sa.next()).toEqual({ op: "OPEN_ROOMS", rooms: [] });

    const sb = await connect(b);
    expect(await sb.next()).toEqual(presence(a.uid, "online"));
    expect(await sb.next()).toEqual({ op: "OPEN_ROOMS", rooms: [] });
    expect(await sa.next()).toEqual(presence(b.uid, "online"));

    sa.send({ op: "SET_STATUS", status: "solo" });
    expect(await sb.next()).toEqual(presence(a.uid, "solo"));
    sa.send({ op: "SET_STATUS", status: "in_room:ABC234" });
    expect(await sb.next()).toEqual(presence(a.uid, "in_room:ABC234"));
    // Setting the same status again doesn't repeat it.
    sa.send({ op: "SET_STATUS", status: "in_room:ABC234" });
    expect(await sb.drain()).toEqual([]);

    // A newcomer sees the current status, not just "online".
    sb.ws.close(1000, "bye");
    expect(await sa.next()).toEqual(presence(b.uid, "offline"));
    const sb2 = await connect(b);
    expect(await sb2.next()).toEqual(presence(a.uid, "in_room:ABC234"));

    expect(await sb2.next()).toEqual({ op: "OPEN_ROOMS", rooms: [] });

    sa.ws.close(1000, "bye");
    expect(await sb2.next()).toEqual(presence(a.uid, "offline"));
    sb2.ws.close();
  });

  it("tells non-friends nothing", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const stranger = await setUpClient();
    await befriend(a, b);
    const ss = await connect(stranger);
    const sa = await connect(a);
    const sb = await connect(b);
    sa.send({ op: "SET_STATUS", status: "solo" });
    await sb.next(presence(a.uid, "solo"));
    sb.ws.close();
    await sa.next(presence(b.uid, "offline"));

    const strangerSaw = [...ss.seen, ...(await ss.drain())];
    expect(strangerSaw.filter((m) => m.op === "PRESENCE")).toEqual([]);
    // And the friends never heard about the stranger.
    expect((await sa.drain()).filter((m) => m.userId === stranger.uid)).toEqual([]);
    expect(sa.seen.filter((m) => m.userId === stranger.uid)).toEqual([]);
    sa.ws.close();
    ss.ws.close();
  });

  it("keeps a player online while any of their sockets is open", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    await befriend(a, b);
    const sb = await connect(b);
    const phone = await connect(a);
    const tablet = await connect(a, "bearer");
    expect(tablet.protocol).toBeNull(); // not offered, so not echoed
    await sb.next(presence(a.uid, "online"));

    tablet.send({ op: "SET_STATUS", status: "solo" });
    await sb.next(presence(a.uid, "solo"));
    phone.ws.close();
    // The tablet's status is the latest, so closing the phone changes nothing.
    expect((await sb.drain()).filter((m) => m.op === "PRESENCE")).toEqual([]);
    tablet.ws.close();
    expect(await sb.next()).toEqual(presence(a.uid, "offline"));
    sb.ws.close();
  });

  it("answers PING without a round trip through the hub's code", async () => {
    const a = await setUpClient();
    const sa = await connect(a);
    await sa.next({ op: "OPEN_ROOMS" });
    sa.send('{"op":"PING"}');
    expect(await sa.next()).toEqual({ op: "PONG" });
    sa.ws.close();
  });

  it("rejects bad messages", async () => {
    const a = await setUpClient();
    const sa = await connect(a);
    await sa.next({ op: "OPEN_ROOMS" });
    for (const [raw, code] of [
      ["not json", "bad_message"],
      ["[1,2]", "bad_message"],
      [JSON.stringify({ op: "DANCE" }), "unknown_op"],
      [JSON.stringify({ op: "SET_STATUS", status: "offline" }), "bad_status"],
      [JSON.stringify({ op: "SET_STATUS", status: "in_room:abc" }), "bad_status"],
      [JSON.stringify({ op: "INVITE", to: "x", code: "ABC234", mode: "solo" }), "bad_invite"],
      [JSON.stringify({ op: "SET_STATUS", status: "x".repeat(2000) }), "bad_message"],
    ] as const) {
      sa.send(raw);
      expect(await sa.next()).toEqual({ op: "ERROR", code });
    }
    sa.ws.close();
  });

  it("rate-limits a socket that floods the hub", async () => {
    const a = await setUpClient();
    const sa = await connect(a);
    await sa.next({ op: "OPEN_ROOMS" });
    for (let i = 0; i < 25; i++) sa.send({ op: "SET_STATUS", status: i % 2 === 0 ? "solo" : "online" });
    await sa.next({ op: "ERROR", code: "rate_limited" });
    sa.ws.close();
  });

  it("survives the hub hibernating", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    await befriend(a, b);
    const sa = await connect(a);
    const sb = await connect(b);
    await sa.next(presence(b.uid, "online"));
    sb.send({ op: "SET_STATUS", status: "solo" });
    await sa.next(presence(b.uid, "solo"));

    await evictDurableObject(hub(env), { webSockets: "hibernate" });

    // Friend lists and statuses come back from storage and the socket attachments.
    sb.send({ op: "SET_STATUS", status: "online" });
    expect(await sa.next()).toEqual(presence(b.uid, "online"));
    sa.send({ op: "INVITE", to: b.uid, code: "QWE789", mode: "vs" });
    expect(await sb.next({ op: "INVITE" })).toMatchObject({ from: a.uid, fromUsername: a.username });
    expect(await hub(env).presenceOf(b.uid)).toBe("online");
    sb.ws.close();
    expect(await sa.next()).toEqual(presence(b.uid, "offline"));
    sa.ws.close();
  });
});

describe("HubDO invites", () => {
  it("relays invites only between friends", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const stranger = await setUpClient();
    await befriend(a, b);
    const sa = await connect(a);
    const sb = await connect(b);
    const ss = await connect(stranger);
    await sa.next(presence(b.uid, "online"));

    sa.send({ op: "INVITE", to: b.uid, code: "XYZ234", mode: "coop" });
    expect(await sb.next({ op: "INVITE" })).toEqual({ op: "INVITE", from: a.uid, fromUsername: a.username, code: "XYZ234", mode: "coop" });

    ss.send({ op: "INVITE", to: a.uid, code: "XYZ234", mode: "vs" });
    expect(await ss.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_friends" });
    sa.send({ op: "INVITE", to: a.uid, code: "XYZ234", mode: "vs" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_friends" });
    expect((await sa.drain()).filter((m) => m.op === "INVITE")).toEqual([]);

    sb.ws.close();
    await sa.next(presence(b.uid, "offline"));
    sa.send({ op: "INVITE", to: b.uid, code: "XYZ234", mode: "coop" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "friend_offline" });
    sa.ws.close();
    ss.ws.close();
  });
});

describe("HubDO and the friends routes", () => {
  it("shows a new friend at once, and an ex-friend as gone", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const sa = await connect(a);
    const sb = await connect(b);
    await sa.next({ op: "OPEN_ROOMS" });
    await sb.next({ op: "OPEN_ROOMS" });
    expect((await sa.drain()).filter((m) => m.op === "PRESENCE")).toEqual([]);

    await befriend(a, b);
    expect(await sa.next({ op: "PRESENCE" })).toEqual(presence(b.uid, "online"));
    expect(await sb.next({ op: "PRESENCE" })).toEqual(presence(a.uid, "online"));
    sa.send({ op: "INVITE", to: b.uid, code: "LMN234", mode: "vs" });
    await sb.next({ op: "INVITE" });

    expect((await a.del(`/v1/friends/${b.uid}`)).status).toBe(200);
    expect(await sa.next({ op: "PRESENCE" })).toEqual(presence(b.uid, "offline"));
    expect(await sb.next({ op: "PRESENCE" })).toEqual(presence(a.uid, "offline"));
    sa.send({ op: "INVITE", to: b.uid, code: "LMN234", mode: "vs" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_friends" });
    sb.send({ op: "SET_STATUS", status: "solo" });
    expect((await sa.drain()).filter((m) => m.op === "PRESENCE")).toEqual([]);
    sa.ws.close();
    sb.ws.close();
  });

  it("closes a deleted account's sockets and tells its friends", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    await befriend(a, b);
    const sa = await connect(a);
    const sb = await connect(b);
    await sa.next(presence(b.uid, "online"));

    expect((await b.del("/v1/me")).status).toBe(200);
    expect(await sa.next({ op: "PRESENCE" })).toEqual(presence(b.uid, "offline"));
    expect(await sb.closed).toEqual({ code: 4001, reason: "account_deleted" });
    sa.ws.close();
  });

  it("needs a set-up account and a token", async () => {
    const res = await request("/v1/ws/hub", { headers: { upgrade: "websocket", "sec-websocket-protocol": "wordsmith.v1, not.a.token" } });
    expect(res.status).toBe(401);
  });
});
