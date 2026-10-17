import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { MAX_OUTGOING_REQUESTS } from "../../src/db/friends";
import { befriend, body, client, setUpClient } from "./helpers";

interface Entry {
  id: string;
  username: string;
  avatar: string | null;
  level: number;
  rank: string;
  since: number;
}
interface FriendsList {
  friends: Entry[];
  incoming: Entry[];
  outgoing: Entry[];
}

describe("friends", () => {
  it("request → accept → list → remove", async () => {
    const ali = await setUpClient(undefined, "avatar_04");
    const sam = await setUpClient(undefined, "avatar_07");

    const req = await ali.post("/v1/friends/request", { username: sam.username.toUpperCase() });
    expect(req.status).toBe(200);
    expect(await body(req)).toEqual({
      status: "pending",
      user: { id: sam.uid, username: sam.username, avatar: "avatar_07", level: 1, rank: "Apprentice" },
    });

    const aliView = await body<FriendsList>(await ali.get("/v1/friends"));
    expect(aliView.friends).toEqual([]);
    expect(aliView.outgoing.map((e) => e.id)).toEqual([sam.uid]);
    const samView = await body<FriendsList>(await sam.get("/v1/friends"));
    expect(samView.incoming).toMatchObject([{ id: ali.uid, username: ali.username, avatar: "avatar_04" }]);
    expect(typeof samView.incoming[0]!.since).toBe("number");

    const accept = await sam.post("/v1/friends/respond", { userId: ali.uid, accept: true });
    expect(accept.status).toBe(200);
    expect(await body(accept)).toMatchObject({ status: "accepted", user: { id: ali.uid } });

    for (const [me, them] of [
      [ali, sam],
      [sam, ali],
    ] as const) {
      const list = await body<FriendsList>(await me.get("/v1/friends"));
      expect(list.friends.map((e) => e.id)).toEqual([them.uid]);
      expect(list.incoming).toEqual([]);
      expect(list.outgoing).toEqual([]);
    }

    const again = await ali.post("/v1/friends/request", { username: sam.username });
    expect(again.status).toBe(409);
    expect(await body(again)).toMatchObject({ error: "already_friends" });

    const remove = await sam.del(`/v1/friends/${encodeURIComponent(ali.uid)}`);
    expect(remove.status).toBe(200);
    expect(await body(remove)).toEqual({ ok: true });
    expect((await body<FriendsList>(await ali.get("/v1/friends"))).friends).toEqual([]);
    const rows = await env.DB.prepare("SELECT COUNT(*) AS n FROM friends WHERE user_id IN (?1, ?2)").bind(ali.uid, sam.uid).first<{ n: number }>();
    expect(rows?.n).toBe(0);

    const gone = await sam.del(`/v1/friends/${encodeURIComponent(ali.uid)}`);
    expect(gone.status).toBe(404);
  });

  it("asking someone who already asked you makes you friends", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    await a.post("/v1/friends/request", { username: b.username });
    const res = await b.post("/v1/friends/request", { username: a.username });
    expect(await body(res)).toMatchObject({ status: "accepted", user: { id: a.uid } });
    expect((await body<FriendsList>(await a.get("/v1/friends"))).friends.map((e) => e.id)).toEqual([b.uid]);
  });

  it("asking twice is harmless", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    await a.post("/v1/friends/request", { username: b.username });
    const res = await a.post("/v1/friends/request", { username: b.username });
    expect(res.status).toBe(200);
    expect(await body(res)).toMatchObject({ status: "pending" });
    expect((await body<FriendsList>(await b.get("/v1/friends"))).incoming).toHaveLength(1);
  });

  it("declining or cancelling removes the request", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const c = await setUpClient();
    await a.post("/v1/friends/request", { username: b.username });
    const decline = await b.post("/v1/friends/respond", { userId: a.uid, accept: false });
    expect(await body(decline)).toMatchObject({ status: "declined", user: { id: a.uid } });
    expect((await body<FriendsList>(await a.get("/v1/friends"))).outgoing).toEqual([]);

    await a.post("/v1/friends/request", { username: c.username });
    expect((await a.del(`/v1/friends/${c.uid}`)).status).toBe(200);
    expect((await body<FriendsList>(await c.get("/v1/friends"))).incoming).toEqual([]);
  });

  it("rejects bad requests", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const cases: [string, unknown, number, string][] = [
      ["/v1/friends/request", { username: "nobody_at_all" }, 404, "user_not_found"],
      ["/v1/friends/request", { username: "no spaces!" }, 404, "user_not_found"],
      ["/v1/friends/request", { username: a.username }, 400, "cannot_friend_self"],
      ["/v1/friends/request", {}, 400, "invalid_username"],
      ["/v1/friends/respond", { userId: b.uid, accept: true }, 404, "request_not_found"],
      ["/v1/friends/respond", { userId: b.uid }, 400, "invalid_body"],
      ["/v1/friends/respond", { accept: true }, 400, "invalid_body"],
    ];
    for (const [path, payload, status, error] of cases) {
      const res = await a.post(path, payload);
      expect(res.status, `${path} ${JSON.stringify(payload)}`).toBe(status);
      expect(await body(res)).toMatchObject({ error });
    }
    // Answering your own request isn't a thing.
    await a.post("/v1/friends/request", { username: b.username });
    const own = await a.post("/v1/friends/respond", { userId: b.uid, accept: true });
    expect(own.status).toBe(404);
  });

  it("can't send a request to someone who hasn't chosen a name", async () => {
    const a = await setUpClient();
    const nameless = await client();
    await nameless.get("/v1/me");
    expect((await a.post("/v1/friends/request", { username: "" })).status).toBe(400);
  });

  it("needs a set-up account", async () => {
    const c = await client();
    for (const res of [
      await c.get("/v1/friends"),
      await c.post("/v1/friends/request", { username: "someone" }),
      await c.post("/v1/friends/respond", { userId: "x", accept: true }),
      await c.del("/v1/friends/x"),
      await c.get("/v1/leaderboard"),
    ]) {
      expect(res.status).toBe(403);
      expect(await body(res)).toMatchObject({ error: "setup_required" });
    }
  });

  it("limits requests waiting on others", async () => {
    const a = await setUpClient();
    const now = Date.now();
    const fake = Array.from({ length: MAX_OUTGOING_REQUESTS }, (_, i) =>
      env.DB.prepare("INSERT INTO friends (user_id, friend_id, status, created_at) VALUES (?, ?, 'pending', ?)").bind(a.uid, `ghost-${a.uid}-${i}`, now),
    );
    await env.DB.batch(fake);
    const b = await setUpClient();
    const res = await a.post("/v1/friends/request", { username: b.username });
    expect(res.status).toBe(409);
    expect(await body(res)).toMatchObject({ error: "too_many_requests" });
  });
});

describe("GET /v1/leaderboard", () => {
  it("ranks me and my friends by XP, with VS and co-op numbers", async () => {
    const me = await setUpClient();
    const f1 = await setUpClient();
    const f2 = await setUpClient();
    const stranger = await setUpClient();
    await befriend(me, f1);
    await befriend(f2, me);
    const set = (uid: string, xp: number, won: number) =>
      env.DB.batch([
        env.DB.prepare("UPDATE profiles SET xp = ? WHERE user_id = ?").bind(xp, uid),
        env.DB.prepare("UPDATE stats SET vs_series_won = ?, vs_rounds_won = ?, coop_rounds = 4, coop_mvps = 1 WHERE user_id = ?").bind(won, won * 2, uid),
      ]);
    await set(me.uid, 500, 1);
    await set(f1.uid, 1000, 3);
    await set(f2.uid, 500, 0);
    await set(stranger.uid, 99999, 9);

    const res = await me.get("/v1/leaderboard");
    expect(res.status).toBe(200);
    const { entries } = await body<{ entries: Record<string, unknown>[] }>(res);
    expect(entries.map((e) => e.id)).not.toContain(stranger.uid);
    expect(entries[0]).toEqual({
      place: 1,
      id: f1.uid,
      username: f1.username,
      avatar: "avatar_01",
      level: 10,
      rank: "Journeyman",
      totalXp: 1000,
      vsSeriesWon: 3,
      vsRoundsWon: 6,
      coopRounds: 4,
      coopMvps: 1,
      me: false,
    });
    // Equal XP shares a place.
    expect(entries.slice(1).map((e) => [e.place, e.totalXp])).toEqual([
      [2, 500],
      [2, 500],
    ]);
    expect(entries.filter((e) => e.me).map((e) => e.id)).toEqual([me.uid]);
  });

  it("is just me with no friends", async () => {
    const me = await setUpClient();
    const { entries } = await body<{ entries: Record<string, unknown>[] }>(await me.get("/v1/leaderboard"));
    expect(entries).toMatchObject([{ place: 1, id: me.uid, me: true }]);
  });
});
