import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { befriend, body, client, request, setUpClient, uniqueName, uniqueUid } from "./helpers";

describe("GET /v1/me", () => {
  it("creates the account on first call, with 3 Hammer Strikes and needsSetup", async () => {
    const c = await client();
    const res = await c.get("/v1/me");
    expect(res.status).toBe(200);
    const me = await body(res);
    expect(me).toMatchObject({
      id: c.uid,
      username: null,
      avatar: null,
      needsSetup: true,
      totalXp: 0,
      level: 1,
      xpIntoLevel: 0,
      xpForLevel: 60,
      rank: "Apprentice",
      campaignCompleted: 0,
      nextStage: 1,
      scrapBin: 0,
      hints: { hammer: 3, chisel: 0, sparks: 0 },
      stats: { wordsForged: 0, longestWord: "", soloDone: 0, coopRounds: 0, coopMvps: 0, vsSeries: 0, vsSeriesWon: 0, vsRoundsWon: 0 },
    });
    expect(typeof me.createdAt).toBe("number");

    // The second call reads the same rows rather than making new ones.
    expect(await body(await c.get("/v1/me"))).toEqual(me);
    const rows = await env.DB.prepare("SELECT COUNT(*) AS n FROM inventory WHERE user_id = ?").bind(c.uid).first<{ n: number }>();
    expect(rows?.n).toBe(3);
  });

  it("reports level, rank and next stage from the stored numbers", async () => {
    const c = await client();
    await c.get("/v1/me");
    await env.DB.prepare("UPDATE profiles SET xp = 1000, campaign_stage = 12 WHERE user_id = ?").bind(c.uid).run();
    const me = await body(await c.get("/v1/me"));
    // Level 10 starts at 9 × 100 = 900 XP; level 11 at 10 × 105 = 1050.
    expect(me).toMatchObject({ totalXp: 1000, level: 10, xpIntoLevel: 100, xpForLevel: 150, rank: "Journeyman" });
    expect(me).toMatchObject({ campaignCompleted: 12, nextStage: 13 });
  });
});

describe("POST /v1/me/setup", () => {
  it("sets the username and avatar", async () => {
    const c = await client();
    const name = uniqueName("Ali");
    const res = await c.post("/v1/me/setup", { username: name, avatar: "avatar_16" });
    expect(res.status).toBe(200);
    expect(await body(res)).toMatchObject({ id: c.uid, username: name, avatar: "avatar_16", needsSetup: false });
    expect(await body(await c.get("/v1/me"))).toMatchObject({ username: name, needsSetup: false });
  });

  it("works before GET /v1/me has ever been called", async () => {
    const c = await client();
    const res = await c.post("/v1/me/setup", { username: uniqueName(), avatar: "avatar_01" });
    expect(res.status).toBe(200);
    expect(await body(res)).toMatchObject({ hints: { hammer: 3 } });
  });

  it.each([
    [{ username: "ab", avatar: "avatar_01" }, 400, "invalid_username"],
    [{ username: "a".repeat(17), avatar: "avatar_01" }, 400, "invalid_username"],
    [{ username: "has space", avatar: "avatar_01" }, 400, "invalid_username"],
    [{ username: "émile", avatar: "avatar_01" }, 400, "invalid_username"],
    [{ username: 42, avatar: "avatar_01" }, 400, "invalid_username"],
    [{ avatar: "avatar_01" }, 400, "invalid_username"],
    [{ username: "fuckface", avatar: "avatar_01" }, 400, "username_not_allowed"],
    [{ username: "Deleted_smith", avatar: "avatar_01" }, 400, "username_not_allowed"],
    [{ username: "goodname", avatar: "avatar_17" }, 400, "invalid_avatar"],
    [{ username: "goodname", avatar: "avatar_1" }, 400, "invalid_avatar"],
    [{ username: "goodname" }, 400, "invalid_avatar"],
  ])("rejects %j", async (input, status, error) => {
    const c = await client();
    const res = await c.post("/v1/me/setup", input);
    expect(res.status).toBe(status);
    expect(await body(res)).toMatchObject({ error });
  });

  it("rejects a body that isn't a JSON object", async () => {
    const c = await client();
    const bad = await request("/v1/me/setup", { method: "POST", headers: { authorization: `Bearer ${c.token}` }, body: "{nope" });
    expect(bad.status).toBe(400);
    expect(await body(bad)).toEqual({ error: "invalid_json" });
    const arr = await c.post("/v1/me/setup", ["x"]);
    expect(arr.status).toBe(400);
    expect(await body(arr)).toMatchObject({ error: "invalid_body" });
    const huge = await c.post("/v1/me/setup", { username: "x".repeat(20_000) });
    expect(huge.status).toBe(413);
  });

  it("keeps usernames unique, ignoring case", async () => {
    const first = await setUpClient(uniqueName("Sam"));
    const second = await client();
    const res = await second.post("/v1/me/setup", { username: first.username.toUpperCase(), avatar: "avatar_02" });
    expect(res.status).toBe(409);
    expect(await body(res)).toMatchObject({ error: "username_taken" });
  });

  it("can't change the username (POST /v1/me/username does), but can repeat it to change the avatar", async () => {
    const c = await setUpClient(uniqueName("Kai"), "avatar_03");
    const rename = await c.post("/v1/me/setup", { username: uniqueName("Other"), avatar: "avatar_03" });
    expect(rename.status).toBe(409);
    expect(await body(rename)).toMatchObject({ error: "already_set" });

    const again = await c.post("/v1/me/setup", { username: c.username.toLowerCase(), avatar: "avatar_09" });
    expect(again.status).toBe(200);
    expect(await body(again)).toMatchObject({ username: c.username, avatar: "avatar_09" });
  });
});

describe("GET /v1/users/:username", () => {
  it("shows a public profile, found ignoring case", async () => {
    const viewer = await setUpClient();
    const target = await setUpClient(uniqueName("Rin"), "avatar_05");
    const res = await viewer.get(`/v1/users/${target.username.toUpperCase()}`);
    expect(res.status).toBe(200);
    const profile = await body(res);
    expect(profile).toMatchObject({
      id: target.uid,
      username: target.username,
      avatar: "avatar_05",
      level: 1,
      rank: "Apprentice",
      campaignCompleted: 0,
      friendship: "none",
      stats: { wordsForged: 0, vsSeriesWon: 0 },
    });
    // Nothing private.
    expect(profile).not.toHaveProperty("hints");
    expect(profile).not.toHaveProperty("totalXp");
  });

  it("says how I stand with them", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    expect(await body(await a.get(`/v1/users/${a.username}`))).toMatchObject({ friendship: "self" });
    await a.post("/v1/friends/request", { username: b.username });
    expect(await body(await a.get(`/v1/users/${b.username}`))).toMatchObject({ friendship: "request_sent" });
    expect(await body(await b.get(`/v1/users/${a.username}`))).toMatchObject({ friendship: "request_received" });
    await b.post("/v1/friends/respond", { userId: a.uid, accept: true });
    expect(await body(await a.get(`/v1/users/${b.username}`))).toMatchObject({ friendship: "friends" });
  });

  it("404s for unknown or unset names", async () => {
    const viewer = await client();
    for (const name of ["nobody_here_xyz", "x", "%E2%9C%93", "a%2Fb"]) {
      const res = await viewer.get(`/v1/users/${name}`);
      expect(res.status).toBe(404);
      expect(await body(res)).toEqual({ error: "user_not_found" });
    }
  });
});

describe("DELETE /v1/me", () => {
  it("removes every row about the player and anonymises their matches", async () => {
    const me = await setUpClient();
    const friend = await setUpClient();
    const asker = await setUpClient();
    await befriend(me, friend);
    await asker.post("/v1/friends/request", { username: me.username });
    const uid = me.uid;
    const now = Date.now();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO puzzle_seen VALUES (?, 'm-00001', ?)").bind(uid, now),
      env.DB.prepare("INSERT INTO xp_events (user_id, source, amount, ref, created_at) VALUES (?, 'solo', 10, 'c-0001', ?)").bind(uid, now),
      env.DB.prepare("INSERT INTO solo_results VALUES (?, 1, ?)").bind(uid, now),
      env.DB.prepare("INSERT INTO pickup_seeds VALUES (?, 'install-00000000000000000000000000000000', ?)").bind(uid, now),
      env.DB.prepare("INSERT INTO push_tokens (token, user_id, registered_at) VALUES (?, ?, ?)").bind(`fcm-${uid}`, uid, now),
      env.DB.prepare("INSERT INTO matches VALUES ('match-del', 'coop', 'ABCDEF', ?, ?, ?)").bind(
        now,
        now,
        JSON.stringify({ players: [uid, friend.uid], mvp: uid }),
      ),
      env.DB.prepare("INSERT INTO match_players VALUES ('match-del', ?, 1, 120, 0, 50)").bind(uid),
      env.DB.prepare("INSERT INTO match_players VALUES ('match-del', ?, 2, 60, 0, 30)").bind(friend.uid),
    ]);

    const res = await me.del("/v1/me");
    expect(res.status).toBe(200);
    expect(await body(res)).toEqual({ ok: true });

    for (const [table, column] of [
      ["users", "id"],
      ["profiles", "user_id"],
      ["inventory", "user_id"],
      ["stats", "user_id"],
      ["friends", "user_id"],
      ["friends", "friend_id"],
      ["puzzle_seen", "user_id"],
      ["xp_events", "user_id"],
      ["solo_results", "user_id"],
      ["pickup_seeds", "user_id"],
      ["push_tokens", "user_id"],
      ["match_players", "user_id"],
    ]) {
      const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${column} = ?`).bind(uid).first<{ n: number }>();
      expect(row?.n, `${table}.${column}`).toBe(0);
    }

    // The match keeps both rows; mine now points at nobody, so it reads as a deleted smith.
    const players = await env.DB.prepare(
      `SELECT mp.user_id, COALESCE(u.username, 'Deleted smith') AS name, mp.points
         FROM match_players mp LEFT JOIN users u ON u.id = mp.user_id WHERE mp.match_id = 'match-del' ORDER BY mp.placement`,
    ).all<{ user_id: string; name: string; points: number }>();
    expect(players.results).toHaveLength(2);
    expect(players.results[0]).toMatchObject({ name: "Deleted smith", points: 120 });
    expect(players.results[0]!.user_id).toMatch(/^deleted:/);
    expect(players.results[1]).toMatchObject({ user_id: friend.uid, name: friend.username });
    const summary = await env.DB.prepare("SELECT summary FROM matches WHERE id = 'match-del'").first<{ summary: string }>();
    expect(summary!.summary).not.toContain(uid);
    expect(JSON.parse(summary!.summary).players[1]).toBe(friend.uid);

    // Friends and requesters no longer see them.
    expect((await body<{ friends: unknown[] }>(await friend.get("/v1/friends"))).friends).toEqual([]);
    expect((await body<{ outgoing: unknown[] }>(await asker.get("/v1/friends"))).outgoing).toEqual([]);
    expect((await friend.get(`/v1/users/${me.username}`)).status).toBe(404);

    // The name is free again.
    const newcomer = await client(uniqueUid());
    expect((await newcomer.post("/v1/me/setup", { username: me.username, avatar: "avatar_02" })).status).toBe(200);
  });

  it("is fine for an account that was never created", async () => {
    const c = await client();
    const res = await c.del("/v1/me");
    expect(res.status).toBe(200);
  });
});
