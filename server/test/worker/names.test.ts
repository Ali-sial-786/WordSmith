/**
 * Changing your username (`POST /v1/me/username`) and nicknames for friends
 * (`PUT /v1/friends/:id/nickname`), with migrations/0007_names.sql.
 */

import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { USERNAME_CHANGE_COOLDOWN_MS } from "../../src/account/username";
import { befriend, body, client, request, setUpClient, uniqueName, type Client } from "./helpers";
import { closeAll, connect, type Socket } from "./sockets";

type Smith = Client & { username: string };

interface Entry {
  id: string;
  username: string;
  nickname: string | null;
}
interface FriendsList {
  friends: Entry[];
  incoming: Entry[];
  outgoing: Entry[];
}

function put(c: Client, path: string, payload: unknown): Promise<Response> {
  return request(path, {
    method: "PUT",
    headers: { authorization: `Bearer ${c.token}`, "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
}

const rename = (c: Client, username: unknown) => c.post("/v1/me/username", { username });
const nickname = (c: Client, friend: string, nick: unknown) => put(c, `/v1/friends/${encodeURIComponent(friend)}/nickname`, { nickname: nick });
const friendsOf = async (c: Client) => body<FriendsList>(await c.get("/v1/friends"));

/** Lets the cooldown run out, as if the last change was a week and a bit ago. */
async function weekPasses(uid: string): Promise<void> {
  await env.DB.prepare("UPDATE users SET username_changed_at = username_changed_at - ?2 WHERE id = ?1")
    .bind(uid, USERNAME_CHANGE_COOLDOWN_MS + 1000)
    .run();
}

async function hubSocket(c: Client): Promise<Socket> {
  const s = await connect(c, "/v1/ws/hub");
  await s.next({ op: "OPEN_ROOMS" });
  return s;
}

describe("migrations/0007_names.sql", () => {
  it("adds users.username_changed_at and friends.nickname", async () => {
    const columns = async (table: string) =>
      (await env.DB.prepare(`PRAGMA table_info(${table})`).all<{ name: string }>()).results.map((r) => r.name);
    expect(await columns("users")).toContain("username_changed_at");
    expect(await columns("friends")).toContain("nickname");
  });
});

describe("POST /v1/me/username", () => {
  it("changes the name everywhere it's read from D1, and frees the old one", async () => {
    const me = await setUpClient(uniqueName("Old"));
    const friend = await setUpClient();
    await befriend(me, friend);
    // A gift from me waiting on the friend's Forge Board.
    expect((await me.post(`/v1/friends/${friend.uid}/gift`, {})).status).toBe(200);

    expect(await body(await me.get("/v1/me"))).toMatchObject({ username: me.username, nextUsernameChangeAt: null });
    const name = uniqueName("New");
    const before = Date.now();
    const res = await rename(me, `  ${name} `);
    expect(res.status, await res.clone().text()).toBe(200);
    const profile = await body<{ username: string; nextUsernameChangeAt: number }>(res);
    expect(profile.username).toBe(name);
    expect(profile.nextUsernameChangeAt).toBeGreaterThanOrEqual(before + USERNAME_CHANGE_COOLDOWN_MS);
    expect(profile.nextUsernameChangeAt).toBeLessThanOrEqual(Date.now() + USERNAME_CHANGE_COOLDOWN_MS);
    expect(await body(await me.get("/v1/me"))).toMatchObject({ username: name });

    // Friends, the leaderboard, the board's Trials and gifts all join users.
    expect((await friendsOf(friend)).friends).toMatchObject([{ id: me.uid, username: name }]);
    const { entries } = await body<{ entries: Entry[] }>(await friend.get("/v1/leaderboard"));
    expect(entries.find((e) => e.id === me.uid)?.username).toBe(name);
    const board = await body<{ trials: { standings: Entry[] }; gifts: { pending: { from: Entry }[] } }>(await friend.get("/v1/me/board"));
    expect(board.trials.standings.find((e) => e.id === me.uid)?.username).toBe(name);
    expect(board.gifts.pending.map((g) => g.from.username)).toEqual([name]);

    // Found by the new name only; the old one is free for someone else.
    expect((await friend.get(`/v1/users/${name.toLowerCase()}`)).status).toBe(200);
    expect((await friend.get(`/v1/users/${me.username}`)).status).toBe(404);
    const newcomer = await client();
    expect((await newcomer.post("/v1/me/setup", { username: me.username, avatar: "avatar_02" })).status).toBe(200);
  });

  it("refuses a name someone has, ignoring case", async () => {
    const holder = await setUpClient(uniqueName("Sam"));
    const me = await setUpClient();
    for (const name of [holder.username, holder.username.toUpperCase(), holder.username.toLowerCase()]) {
      const res = await rename(me, name);
      expect(res.status).toBe(409);
      expect(await body(res)).toMatchObject({ error: "username_taken" });
    }
    // Nothing changed, so the cooldown hasn't started.
    expect(await body(await me.get("/v1/me"))).toMatchObject({ username: me.username, nextUsernameChangeAt: null });
  });

  it.each([
    ["ab", "invalid_username"],
    ["a".repeat(17), "invalid_username"],
    ["has space", "invalid_username"],
    ["émile", "invalid_username"],
    [42, "invalid_username"],
    [undefined, "invalid_username"],
    ["fuckface", "username_not_allowed"],
    ["Deleted_smith", "username_not_allowed"],
    ["admin", "username_not_allowed"],
  ])("refuses %j", async (name, error) => {
    const me = await setUpClient();
    const res = await rename(me, name);
    expect(res.status).toBe(400);
    expect(await body(res)).toMatchObject({ error });
  });

  it("needs a set-up account (setup picks the first name)", async () => {
    const c = await client();
    await c.get("/v1/me");
    const res = await rename(c, uniqueName());
    expect(res.status).toBe(403);
    expect(await body(res)).toMatchObject({ error: "setup_required" });
  });

  it("allows one change a week, says when the next is, and lets a case change count", async () => {
    const me = await setUpClient(uniqueName("kai"));
    const first = uniqueName("kai");
    expect((await rename(me, first)).status).toBe(200);
    const { nextUsernameChangeAt } = await body<{ nextUsernameChangeAt: number }>(await me.get("/v1/me"));

    const again = await rename(me, uniqueName("kai"));
    expect(again.status).toBe(429);
    expect(await body(again)).toEqual({ error: "too_soon", message: expect.any(String), nextChangeAt: nextUsernameChangeAt });
    // Asking for the name I already have is fine (a retry), and changes nothing.
    const retry = await rename(me, first);
    expect(retry.status).toBe(200);
    expect(await body(retry)).toMatchObject({ username: first, nextUsernameChangeAt });

    await weekPasses(me.uid);
    const upper = first.toUpperCase();
    const res = await rename(me, upper);
    expect(res.status).toBe(200);
    expect(await body(res)).toMatchObject({ username: upper });
    expect((await rename(me, first)).status).toBe(429);
  });

  it("settles races: one of two players gets a free name, and one of two changes goes through", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const wanted = uniqueName("Race");
    const both = await Promise.all([rename(a, wanted), rename(b, wanted.toLowerCase())]);
    expect(both.map((r) => r.status).sort()).toEqual([200, 409]);
    const owners = await env.DB.prepare("SELECT id FROM users WHERE username = ?1").bind(wanted).all<{ id: string }>();
    expect(owners.results).toHaveLength(1);
    const loser = owners.results[0]!.id === a.uid ? b : a;
    expect(await body(await loser.get("/v1/me"))).toMatchObject({ username: loser.username, nextUsernameChangeAt: null });

    const c = await setUpClient();
    const changes = await Promise.all([rename(c, uniqueName("One")), rename(c, uniqueName("Two"))]);
    expect(changes.map((r) => r.status).sort()).toEqual([200, 429]);
  });

  it("tells the hub: friends see the new name on the room I host, and on my invites", async () => {
    const me = await setUpClient();
    const friend = await setUpClient();
    await befriend(me, friend);
    const mine = await hubSocket(me);
    const theirs = await hubSocket(friend);

    const created = await me.post("/v1/rooms", { mode: "coop" });
    const { code } = await body<{ code: string }>(created);
    const listed = await theirs.next({ op: "OPEN_ROOMS" });
    expect(listed.rooms).toMatchObject([{ code, hostUsername: me.username }]);

    const name = uniqueName("Renamed");
    expect((await rename(me, name)).status).toBe(200);
    expect((await theirs.next({ op: "OPEN_ROOMS" })).rooms).toMatchObject([{ code, hostUsername: name }]);

    // The socket opened before the change invites under the new name.
    mine.send({ op: "INVITE", to: friend.uid, code, mode: "coop" });
    expect(await theirs.next({ op: "INVITE" })).toEqual({ op: "INVITE", from: me.uid, fromUsername: name, code, mode: "coop" });
    expect((await body<{ host: { username: string } }>(await friend.get(`/v1/rooms/${code}`))).host.username).toBe(name);
    await closeAll(mine, theirs);
  });

  it("tells the rooms I'm in: everyone there gets a LOBBY with the new name", async () => {
    const host = await setUpClient();
    const me = await setUpClient();
    const created = await host.post("/v1/rooms", { mode: "vs" });
    const { code } = await body<{ code: string }>(created);
    const sh = await connect(host, `/v1/ws/room/${code}`);
    await sh.next({ op: "SNAPSHOT" });
    const sm = await connect(me, `/v1/ws/room/${code}`);
    await sm.next({ op: "SNAPSHOT" });
    // The app sets this status while the room is open; it's how the hub knows.
    const hub = await hubSocket(me);
    hub.send({ op: "SET_STATUS", status: `in_room:${code}` });
    await hub.drain();

    const name = uniqueName("Clash");
    expect((await rename(me, name)).status).toBe(200);
    for (const s of [sh, sm]) {
      for (;;) {
        const lobby = await s.next({ op: "LOBBY" });
        const player = (lobby.players as { id: string; username: string }[]).find((p) => p.id === me.uid);
        if (player?.username === name) break;
      }
    }
    await closeAll(hub, sh, sm);
  });
});

describe("PUT /v1/friends/:id/nickname", () => {
  async function pair(): Promise<[Smith, Smith]> {
    const a = await setUpClient();
    const b = await setUpClient();
    await befriend(a, b);
    return [a, b];
  }

  it("sets, trims, changes and clears my nickname for a friend", async () => {
    const [me, friend] = await pair();
    const res = await nickname(me, friend.uid, "  Big Al 🔨 ");
    expect(res.status, await res.clone().text()).toBe(200);
    expect(await body(res)).toEqual({ ok: true, nickname: "Big Al 🔨" });
    expect((await friendsOf(me)).friends).toEqual([expect.objectContaining({ id: friend.uid, username: friend.username, nickname: "Big Al 🔨" })]);

    expect(await body(await nickname(me, friend.uid, "Al"))).toEqual({ ok: true, nickname: "Al" });
    expect((await friendsOf(me)).friends[0]!.nickname).toBe("Al");

    expect(await body(await nickname(me, friend.uid, null))).toEqual({ ok: true, nickname: null });
    expect((await friendsOf(me)).friends[0]!.nickname).toBeNull();
  });

  it("is private to me", async () => {
    const [me, friend] = await pair();
    expect((await nickname(me, friend.uid, "Sparky")).status).toBe(200);
    const theirs = JSON.stringify(await friendsOf(friend));
    expect((await friendsOf(friend)).friends).toEqual([expect.objectContaining({ id: me.uid, nickname: null })]);
    expect(theirs).not.toContain("Sparky");
    // Nothing anyone else reads carries it either.
    for (const path of [`/v1/users/${friend.username}`, `/v1/users/${me.username}`, "/v1/leaderboard", "/v1/me/board"]) {
      expect(JSON.stringify(await body(await friend.get(path))), path).not.toContain("Sparky");
    }
    expect(JSON.stringify(await body(await me.get("/v1/leaderboard")))).not.toContain("Sparky");
  });

  it("lists friends by the name I see", async () => {
    const me = await setUpClient();
    const zed = await setUpClient(uniqueName("zzz"));
    const amy = await setUpClient(uniqueName("aaa"));
    await befriend(me, zed);
    await befriend(me, amy);
    expect((await friendsOf(me)).friends.map((f) => f.id)).toEqual([amy.uid, zed.uid]);
    await nickname(me, zed.uid, "007");
    expect((await friendsOf(me)).friends.map((f) => f.id)).toEqual([zed.uid, amy.uid]);
  });

  it("goes with the friendship", async () => {
    const [me, friend] = await pair();
    await nickname(me, friend.uid, "Bestie");
    expect((await friend.del(`/v1/friends/${me.uid}`)).status).toBe(200);
    await befriend(me, friend);
    expect((await friendsOf(me)).friends[0]!.nickname).toBeNull();
  });

  it("is only for accepted friends", async () => {
    const me = await setUpClient();
    const asked = await setUpClient();
    const asker = await setUpClient();
    const stranger = await setUpClient();
    await me.post("/v1/friends/request", { username: asked.username });
    await asker.post("/v1/friends/request", { username: me.username });
    for (const id of [asked.uid, asker.uid, stranger.uid, me.uid, "nobody"]) {
      const res = await nickname(me, id, "Pal");
      expect(res.status, id).toBe(404);
      expect(await body(res)).toMatchObject({ error: "not_friends" });
    }
    // Requests never carry one.
    const list = await friendsOf(me);
    expect([...list.incoming, ...list.outgoing].map((e) => e.nickname)).toEqual([null, null]);
  });

  it.each([
    ["", "empty"],
    ["    ", "only spaces"],
    ["​", "invisible"],
    ["a".repeat(21), "21 characters"],
    ["bell\u0007", "a control character"],
    ["two\nlines", "a line break"],
    ["‮evil", "a bidi override"],
    [42, "a number"],
    [{}, "an object"],
  ])("refuses %j (%s)", async (nick, _why) => {
    const [me, friend] = await pair();
    const res = await nickname(me, friend.uid, nick);
    expect(res.status).toBe(400);
    expect(await body(res)).toMatchObject({ error: "invalid_nickname" });
  });

  it("refuses a body without a nickname, and needs a set-up account", async () => {
    const [me, friend] = await pair();
    const res = await put(me, `/v1/friends/${friend.uid}/nickname`, {});
    expect(res.status).toBe(400);
    expect(await body(res)).toMatchObject({ error: "invalid_nickname" });
    const nameless = await client();
    expect((await nickname(nameless, friend.uid, "Pal")).status).toBe(403);
  });

  it("counts characters as they show: 20 emoji are fine", async () => {
    const [me, friend] = await pair();
    const flags = "🏴‍☠️".repeat(20);
    const res = await nickname(me, friend.uid, flags);
    expect(res.status, await res.clone().text()).toBe(200);
    expect((await friendsOf(me)).friends[0]!.nickname).toBe(flags);
  });
});
