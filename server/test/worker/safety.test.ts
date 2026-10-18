/**
 * Blocking and reporting (shared/safety.md), with migrations/0008_safety.sql.
 */

import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { MAX_REPORTS_PER_WINDOW, REPORT_REASONS, REPORT_WINDOW_MS } from "../../src/db/safety";
import { befriend, body, client, request, setUpClient, uniqueName, type Client } from "./helpers";
import { closeAll, connect, type Socket } from "./sockets";

interface BlockEntry {
  id: string;
  username: string;
  avatar: string | null;
  at: number;
}
interface Entry {
  id: string;
}
interface FriendsList {
  friends: Entry[];
  incoming: Entry[];
  outgoing: Entry[];
}
interface ReportRow {
  reporter_id: string;
  reported_id: string;
  reported_username: string;
  reason: string;
  details: string | null;
  room: string | null;
  lines: string;
  created_at: number;
  status: string;
}

const block = (c: Client, id: string) =>
  request(`/v1/me/blocks/${encodeURIComponent(id)}`, { method: "PUT", headers: { authorization: `Bearer ${c.token}` } });
const unblock = (c: Client, id: string) => c.del(`/v1/me/blocks/${encodeURIComponent(id)}`);
const blocksOf = async (c: Client) => (await body<{ blocks: BlockEntry[] }>(await c.get("/v1/me/blocks"))).blocks;
const friendsOf = async (c: Client) => body<FriendsList>(await c.get("/v1/friends"));
const ask = (c: Client, username: string) => c.post("/v1/friends/request", { username });
const report = (c: Client, payload: unknown) => c.post("/v1/reports", payload);
const reportsBy = async (uid: string) =>
  (await env.DB.prepare("SELECT * FROM reports WHERE reporter_id = ?1 ORDER BY id").bind(uid).all<ReportRow>()).results;

async function hubSocket(c: Client): Promise<Socket> {
  const s = await connect(c, "/v1/ws/hub");
  await s.next({ op: "OPEN_ROOMS" });
  return s;
}

describe("migrations/0008_safety.sql", () => {
  it("adds blocks and reports, with their indexes", async () => {
    const columns = async (table: string) =>
      (await env.DB.prepare(`PRAGMA table_info(${table})`).all<{ name: string }>()).results.map((r) => r.name);
    expect(await columns("blocks")).toEqual(["user_id", "blocked_id", "created_at"]);
    expect(await columns("reports")).toEqual([
      "id",
      "reporter_id",
      "reported_id",
      "reported_username",
      "reason",
      "details",
      "room",
      "lines",
      "created_at",
      "status",
    ]);
    const { results } = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name IN ('blocks', 'reports') AND sql IS NOT NULL ORDER BY name",
    ).all<{ name: string }>();
    expect(results.map((r) => r.name)).toEqual(["blocks_by_blocked", "reports_by_reporter", "reports_by_status"]);
  });
});

describe("blocks", () => {
  it("blocks, lists newest first and unblocks; both are idempotent", async () => {
    const me = await setUpClient();
    const first = await setUpClient(undefined, "avatar_05");
    const second = await setUpClient(undefined, "avatar_09");
    expect(await blocksOf(me)).toEqual([]);

    const res = await block(me, first.uid);
    expect(res.status, await res.clone().text()).toBe(200);
    expect(await body(res)).toEqual({ ok: true });
    expect((await block(me, second.uid)).status).toBe(200);
    // Again keeps the first time, so the order stays.
    expect(await body(await block(me, first.uid))).toEqual({ ok: true });

    const list = await blocksOf(me);
    expect(list).toEqual([
      { id: second.uid, username: second.username, avatar: "avatar_09", at: expect.any(Number) },
      { id: first.uid, username: first.username, avatar: "avatar_05", at: expect.any(Number) },
    ]);
    expect(list[0]!.at).toBeGreaterThanOrEqual(list[1]!.at);
    // The blocked players aren't told, and their own lists are theirs.
    expect(await blocksOf(first)).toEqual([]);
    expect(await blocksOf(second)).toEqual([]);

    for (let i = 0; i < 2; i++) {
      const res = await unblock(me, first.uid);
      expect(res.status).toBe(200);
      expect(await body(res)).toEqual({ ok: true });
    }
    expect((await blocksOf(me)).map((b) => b.id)).toEqual([second.uid]);
    // Unblocking someone I never blocked, or nobody at all, is fine too.
    expect((await unblock(me, first.uid)).status).toBe(200);
    expect((await unblock(me, "nobody-at-all")).status).toBe(200);
    expect((await unblock(me, me.uid)).status).toBe(200);
  });

  it("refuses myself and players who don't exist", async () => {
    const me = await setUpClient();
    const nameless = await client();
    await nameless.get("/v1/me");
    const cases: [string, number, string][] = [
      [me.uid, 400, "cannot_block_self"],
      ["nobody-at-all", 404, "user_not_found"],
      [nameless.uid, 404, "user_not_found"],
    ];
    for (const [id, status, error] of cases) {
      const res = await block(me, id);
      expect(res.status, id).toBe(status);
      expect(await body(res)).toEqual({ error });
    }
    expect(await blocksOf(me)).toEqual([]);
  });

  it("needs a set-up account, like friends", async () => {
    const c = await client();
    const other = await setUpClient();
    for (const res of [
      await c.get("/v1/me/blocks"),
      await block(c, other.uid),
      await unblock(c, other.uid),
      await report(c, { userId: other.uid, reason: "spam" }),
    ]) {
      expect(res.status).toBe(403);
      expect(await body(res)).toMatchObject({ error: "setup_required" });
    }
  });

  it("ends a friendship, either way, and tells the hub as removing the friend would", async () => {
    const me = await setUpClient();
    const friend = await setUpClient();
    await befriend(friend, me);
    const mine = await hubSocket(me);
    const theirs = await hubSocket(friend);
    await mine.next({ op: "PRESENCE", userId: friend.uid, status: "online" });

    expect((await block(me, friend.uid)).status).toBe(200);
    expect(await mine.next({ op: "PRESENCE" })).toEqual({ op: "PRESENCE", userId: friend.uid, status: "offline" });
    expect(await theirs.next({ op: "PRESENCE" })).toEqual({ op: "PRESENCE", userId: me.uid, status: "offline" });
    expect((await friendsOf(me)).friends).toEqual([]);
    expect((await friendsOf(friend)).friends).toEqual([]);
    const rows = await env.DB.prepare("SELECT COUNT(*) AS n FROM friends WHERE user_id IN (?1, ?2) OR friend_id IN (?1, ?2)")
      .bind(me.uid, friend.uid)
      .first<{ n: number }>();
    expect(rows?.n).toBe(0);
    // No more invites between them.
    theirs.send({ op: "INVITE", to: me.uid, code: "K7Q2AB", mode: "coop" });
    expect(await theirs.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_friends" });
    await closeAll(mine, theirs);
  });

  it("ends a pending request, either way; answering it afterwards finds no request", async () => {
    const me = await setUpClient();
    const asked = await setUpClient();
    const asker = await setUpClient();
    expect((await ask(me, asked.username)).status).toBe(200);
    expect((await ask(asker, me.username)).status).toBe(200);
    expect((await friendsOf(me)).outgoing).toHaveLength(1);
    expect((await friendsOf(me)).incoming).toHaveLength(1);

    expect((await block(me, asked.uid)).status).toBe(200);
    expect((await block(me, asker.uid)).status).toBe(200);
    expect(await friendsOf(me)).toEqual({ friends: [], incoming: [], outgoing: [] });
    expect((await friendsOf(asked)).incoming).toEqual([]);
    expect((await friendsOf(asker)).outgoing).toEqual([]);

    // Neither side can accept what was there before the block.
    for (const [who, from] of [
      [me, asker],
      [asked, me],
    ] as const) {
      const res = await who.post("/v1/friends/respond", { userId: from.uid, accept: true });
      expect(res.status).toBe(404);
      expect(await body(res)).toMatchObject({ error: "request_not_found" });
    }
    expect((await friendsOf(asked)).friends).toEqual([]);
  });

  it("doesn't accept a request that slipped in alongside a block", async () => {
    const me = await setUpClient();
    const them = await setUpClient();
    expect((await block(me, them.uid)).status).toBe(200);
    // As if their request had passed its check just before the block landed.
    await env.DB.prepare("INSERT INTO friends (user_id, friend_id, status, created_at) VALUES (?1, ?2, 'pending', ?3)")
      .bind(them.uid, me.uid, Date.now())
      .run();
    const res = await me.post("/v1/friends/respond", { userId: them.uid, accept: true });
    expect(res.status).toBe(404);
    expect(await body(res)).toMatchObject({ error: "request_not_found" });
    expect((await friendsOf(me)).friends).toEqual([]);
    // It can still be turned down.
    expect(await body(await me.post("/v1/friends/respond", { userId: them.uid, accept: false }))).toMatchObject({ status: "declined" });
  });

  it("refuses friend requests either way: the blocked player sees a wrong name, the blocker 409 blocked", async () => {
    const me = await setUpClient();
    const them = await setUpClient();
    const wrongName = await body(await ask(them, uniqueName("nobody")));
    expect(wrongName).toEqual({ error: "user_not_found" });

    expect((await block(me, them.uid)).status).toBe(200);
    const blocked = await ask(them, me.username);
    expect(blocked.status).toBe(404);
    expect(await body(blocked)).toEqual(wrongName);
    const blocker = await ask(me, them.username);
    expect(blocker.status).toBe(409);
    expect(await body(blocker)).toMatchObject({ error: "blocked" });

    // Both ways: each is the blocker.
    expect((await block(them, me.uid)).status).toBe(200);
    for (const [from, to] of [
      [me, them],
      [them, me],
    ] as const) {
      const res = await ask(from, to.username);
      expect(res.status).toBe(409);
      expect(await body(res)).toMatchObject({ error: "blocked" });
    }

    // Once I unblock, I'm the blocked one.
    expect((await unblock(me, them.uid)).status).toBe(200);
    expect(await body(await ask(me, them.username))).toEqual(wrongName);
    expect((await ask(them, me.username)).status).toBe(409);
    expect(await friendsOf(me)).toEqual({ friends: [], incoming: [], outgoing: [] });

    expect((await unblock(them, me.uid)).status).toBe(200);
    expect(await body(await ask(me, them.username))).toMatchObject({ status: "pending" });
  });

  it("unblocking doesn't bring the friendship back", async () => {
    const me = await setUpClient();
    const friend = await setUpClient();
    await befriend(me, friend);
    expect((await block(me, friend.uid)).status).toBe(200);
    expect((await unblock(me, friend.uid)).status).toBe(200);
    expect((await friendsOf(me)).friends).toEqual([]);
    expect((await friendsOf(friend)).friends).toEqual([]);
    expect(await body(await me.get(`/v1/users/${friend.username}`))).toMatchObject({ friendship: "none" });
    // They can be friends again the usual way.
    await befriend(friend, me);
    expect((await friendsOf(me)).friends.map((f) => f.id)).toEqual([friend.uid]);
  });
});

describe("POST /v1/reports", () => {
  it("stores the report with their name at the time and status open", async () => {
    const me = await setUpClient();
    const target = await setUpClient();
    const before = Date.now();
    const res = await report(me, {
      userId: target.uid,
      reason: "harassment",
      details: "  Kept calling me names.\nAll round.  ",
      room: "K7Q2AB",
      lines: [
        { id: 12, text: "you're rubbish", at: 1760000000000, username: "ignored" },
        { id: 13, text: "🔥".repeat(200), at: 1760000001000 },
      ],
    });
    expect(res.status, await res.clone().text()).toBe(201);
    expect(await body(res)).toEqual({ ok: true });

    const rows = await reportsBy(me.uid);
    expect(rows).toEqual([
      {
        id: expect.any(Number),
        reporter_id: me.uid,
        reported_id: target.uid,
        reported_username: target.username,
        reason: "harassment",
        details: "Kept calling me names.\nAll round.",
        room: "K7Q2AB",
        lines: expect.any(String),
        created_at: expect.any(Number),
        status: "open",
      },
    ]);
    expect(JSON.parse(rows[0]!.lines)).toEqual([
      { id: 12, text: "you're rubbish", at: 1760000000000 },
      { id: 13, text: "🔥".repeat(200), at: 1760000001000 },
    ]);
    expect(rows[0]!.created_at).toBeGreaterThanOrEqual(before);

    // The name stays as it was when reported.
    expect((await target.post("/v1/me/username", { username: uniqueName("renamed") })).status).toBe(200);
    expect((await reportsBy(me.uid))[0]!.reported_username).toBe(target.username);
  });

  it("needs only userId and a reason; missing and null optional fields are the same", async () => {
    const me = await setUpClient();
    const target = await setUpClient();
    for (const payload of [
      { userId: target.uid, reason: "name" },
      { userId: target.uid, reason: "spam", details: null, room: null, lines: null },
      { userId: target.uid, reason: "other", details: "   ", lines: [] },
      { userId: target.uid, reason: "cheating", details: ` ${"é".repeat(500)} ` },
    ]) {
      const res = await report(me, payload);
      expect(res.status, `${JSON.stringify(payload)}: ${await res.clone().text()}`).toBe(201);
    }
    const rows = await reportsBy(me.uid);
    expect(rows.map((r) => [r.reason, r.details, r.room, r.lines])).toEqual([
      ["name", null, null, "[]"],
      ["spam", null, null, "[]"],
      ["other", null, null, "[]"],
      ["cheating", "é".repeat(500), null, "[]"],
    ]);
  });

  it("takes every reason", async () => {
    const me = await setUpClient();
    const target = await setUpClient();
    for (const reason of REPORT_REASONS) expect((await report(me, { userId: target.uid, reason })).status, reason).toBe(201);
    expect((await reportsBy(me.uid)).map((r) => r.reason)).toEqual([...REPORT_REASONS]);
  });

  const line = { id: 3, text: "hi", at: 1760000000000 };
  it.each<[string, Record<string, unknown>]>([
    ["no userId", { userId: undefined }],
    ["an empty userId", { userId: "" }],
    ["a number for userId", { userId: 42 }],
    ["no reason", { reason: undefined }],
    ["an unknown reason", { reason: "rude" }],
    ["a reason in capitals", { reason: "SPAM" }],
    ["details that aren't text", { details: 42 }],
    ["501 characters of details", { details: "x".repeat(501) }],
    ["501 emoji of details", { details: "😀".repeat(501) }],
    ["a lowercase room code", { room: "k7q2ab" }],
    ["a short room code", { room: "K7Q2A" }],
    ["a room code with a 0", { room: "K7Q2A0" }],
    ["a number for room", { room: 123456 }],
    ["lines that aren't a list", { lines: "hi" }],
    ["lines as an object", { lines: { 0: line } }],
    ["21 lines", { lines: Array.from({ length: 21 }, (_, i) => ({ ...line, id: i + 1 })) }],
    ["a line that isn't an object", { lines: ["hi"] }],
    ["a line without an id", { lines: [{ text: "hi", at: 1 }] }],
    ["a line with a negative id", { lines: [{ ...line, id: -1 }] }],
    ["a line with a fractional id", { lines: [{ ...line, id: 1.5 }] }],
    ["a line with a text id", { lines: [{ ...line, id: "3" }] }],
    ["a line without text", { lines: [{ id: 3, at: 1 }] }],
    ["a line whose text isn't text", { lines: [{ ...line, text: 42 }] }],
    ["a line of 201 characters", { lines: [{ ...line, text: "x".repeat(201) }] }],
    ["a line without a time", { lines: [{ id: 3, text: "hi" }] }],
    ["a line with a text time", { lines: [{ ...line, at: "now" }] }],
  ])("refuses %s with 400 bad_request", async (_why, change) => {
    const me = await setUpClient();
    const target = await setUpClient();
    const res = await report(me, { userId: target.uid, reason: "harassment", lines: [line], ...change });
    expect(res.status).toBe(400);
    expect(await body(res)).toMatchObject({ error: "bad_request" });
    expect(await reportsBy(me.uid)).toEqual([]);
  });

  it("refuses a body that isn't a JSON object with 400 bad_request too", async () => {
    const me = await setUpClient();
    const headers = { authorization: `Bearer ${me.token}`, "content-type": "application/json" };
    const raw = (text: string) => request("/v1/reports", { method: "POST", headers, body: text });
    for (const text of ["{nope", "[]", '"spam"', "null", JSON.stringify({ details: "x".repeat(70_000) })]) {
      const res = await raw(text);
      expect(res.status, text.slice(0, 20)).toBe(400);
      expect(await body(res)).toMatchObject({ error: "bad_request" });
    }
  });

  it("refuses myself and players who don't exist", async () => {
    const me = await setUpClient();
    const nameless = await client();
    await nameless.get("/v1/me");
    const cases: [string, number, string][] = [
      [me.uid, 400, "cannot_report_self"],
      ["nobody-at-all", 404, "user_not_found"],
      [nameless.uid, 404, "user_not_found"],
    ];
    for (const [userId, status, error] of cases) {
      const res = await report(me, { userId, reason: "spam" });
      expect(res.status, userId).toBe(status);
      expect(await body(res)).toEqual({ error });
    }
    expect(await reportsBy(me.uid)).toEqual([]);
  });

  it(`allows ${MAX_REPORTS_PER_WINDOW} reports per player in 24 hours`, async () => {
    const me = await setUpClient();
    const other = await setUpClient();
    const targets = [await setUpClient(), await setUpClient()];
    for (let i = 0; i < MAX_REPORTS_PER_WINDOW; i++) {
      expect((await report(me, { userId: targets[i % 2]!.uid, reason: "spam" })).status, `report ${i + 1}`).toBe(201);
    }
    const res = await report(me, { userId: targets[0]!.uid, reason: "hate" });
    expect(res.status).toBe(429);
    expect(await body(res)).toMatchObject({ error: "too_many_reports" });
    expect(await reportsBy(me.uid)).toHaveLength(MAX_REPORTS_PER_WINDOW);
    // It's per reporter.
    expect((await report(other, { userId: targets[0]!.uid, reason: "hate" })).status).toBe(201);

    // A day later there's room again, one report at a time.
    await env.DB.prepare("UPDATE reports SET created_at = created_at - ?2 WHERE id = (SELECT MIN(id) FROM reports WHERE reporter_id = ?1)")
      .bind(me.uid, REPORT_WINDOW_MS)
      .run();
    expect((await report(me, { userId: targets[0]!.uid, reason: "hate" })).status).toBe(201);
    expect((await report(me, { userId: targets[0]!.uid, reason: "hate" })).status).toBe(429);
  });

  it("isn't visible anywhere to the reported player, and changes nothing between them", async () => {
    const me = await setUpClient();
    const target = await setUpClient();
    await befriend(me, target);
    const theirs = await hubSocket(target);
    const mine = await hubSocket(me);
    await theirs.next({ op: "PRESENCE", userId: me.uid, status: "online" });

    const secret = `secret-${uniqueName("rpt")}`;
    const lines = [{ id: 1, text: secret, at: Date.now() }];
    expect((await report(me, { userId: target.uid, reason: "harassment", details: secret, lines })).status).toBe(201);

    expect(await theirs.drain()).toEqual([]);
    const paths = ["/v1/me", "/v1/friends", "/v1/me/board", "/v1/me/blocks", "/v1/leaderboard", `/v1/users/${target.username}`];
    for (const path of [...paths, `/v1/users/${me.username}`]) {
      const text = await (await target.get(path)).text();
      expect(text, path).not.toContain(secret);
      expect(text.toLowerCase(), path).not.toContain("report");
    }
    // Still friends: a report isn't a block.
    expect((await friendsOf(target)).friends.map((f) => f.id)).toEqual([me.uid]);
    await closeAll(mine, theirs);
  });
});

describe("DELETE /v1/me", () => {
  it("deletes the player's blocks both ways and every report by or about them", async () => {
    const gone = await setUpClient();
    const a = await setUpClient();
    const b = await setUpClient();
    const c = await setUpClient();
    expect((await block(gone, a.uid)).status).toBe(200);
    expect((await block(b, gone.uid)).status).toBe(200);
    expect((await block(b, c.uid)).status).toBe(200);
    expect((await report(gone, { userId: a.uid, reason: "spam" })).status).toBe(201);
    expect((await report(c, { userId: gone.uid, reason: "name" })).status).toBe(201);
    expect((await report(a, { userId: c.uid, reason: "cheating" })).status).toBe(201);

    expect((await gone.del("/v1/me")).status).toBe(200);

    const count = async (sql: string) => (await env.DB.prepare(sql).bind(gone.uid).first<{ n: number }>())?.n;
    expect(await count("SELECT COUNT(*) AS n FROM blocks WHERE user_id = ?1 OR blocked_id = ?1")).toBe(0);
    expect(await count("SELECT COUNT(*) AS n FROM reports WHERE reporter_id = ?1 OR reported_id = ?1")).toBe(0);
    // Everyone else's stay.
    expect((await blocksOf(b)).map((x) => x.id)).toEqual([c.uid]);
    expect((await reportsBy(a.uid)).map((r) => r.reported_id)).toEqual([c.uid]);
  });
});
