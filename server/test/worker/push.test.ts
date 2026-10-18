/**
 * Invite notifications (shared/push.md): the push-token routes, and the hub
 * sending invites through a stand-in for Google's OAuth endpoint and FCM.
 *
 * The test env has no FCM_SERVICE_ACCOUNT, so every other test file runs with
 * push off. Here, setFcmServiceAccount() installs a key generated per run and
 * setFcmFetcher() routes the Worker's requests to Google into `fakeGoogle`.
 */

import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { dueReminders } from "../../src/db/reminders";
import worker from "../../src/index";
import { fcmSendUrl, GOOGLE_TOKEN_URL, setFcmFetcher, setFcmServiceAccount } from "../../src/push/fcm";
import { befriend, body, client, request, setUpClient, type Client } from "./helpers";
import { closeAll, connect, sleep, type Socket } from "./sockets";

const RS256 = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };
const PUSH_PROJECT = "wordsmith-push-test";
const CLIENT_EMAIL = "firebase-adminsdk-test@wordsmith-push-test.iam.gserviceaccount.com";

let publicKey: CryptoKey;
let serviceAccount: string;

function base64(bytes: ArrayBuffer): string {
  let binary = "";
  for (const b of new Uint8Array(bytes)) binary += String.fromCharCode(b);
  return btoa(binary);
}

function base64UrlBytes(segment: string): Uint8Array<ArrayBuffer> {
  const binary = atob(segment.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

beforeAll(async () => {
  const pair = (await crypto.subtle.generateKey(
    { ...RS256, modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]) },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  publicKey = pair.publicKey;
  const der = (await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer;
  const pem = `-----BEGIN PRIVATE KEY-----\n${base64(der).match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
  serviceAccount = JSON.stringify({
    type: "service_account",
    project_id: PUSH_PROJECT,
    private_key_id: "test-kid",
    private_key: pem,
    client_email: CLIENT_EMAIL,
  });
});

interface Seen {
  readonly url: string;
  readonly method: string;
  readonly headers: Headers;
  readonly body: string;
}

type Reply = { status: number; body: unknown };

/** Google's OAuth endpoint and FCM, recording every request the Worker makes. */
function fakeGoogle(reply: (token: string) => Reply = () => ({ status: 200, body: { name: `projects/${PUSH_PROJECT}/messages/1` } })) {
  const seen: Seen[] = [];
  const fetchFn: typeof fetch = async (input, init) => {
    const req = new Request(input, init);
    const text = new TextDecoder().decode(await req.arrayBuffer());
    seen.push({ url: req.url, method: req.method, headers: req.headers, body: text });
    if (req.url === GOOGLE_TOKEN_URL) return Response.json({ access_token: "ya29.test-access", expires_in: 3599, token_type: "Bearer" });
    if (req.url === fcmSendUrl(PUSH_PROJECT)) {
      const r = reply((JSON.parse(text) as { message: { token: string } }).message.token);
      return Response.json(r.body, { status: r.status });
    }
    return new Response("unexpected request", { status: 500 });
  };
  return {
    fetch: fetchFn,
    seen,
    oauth: () => seen.filter((s) => s.url === GOOGLE_TOKEN_URL),
    sends: () => seen.filter((s) => s.url === fcmSendUrl(PUSH_PROJECT)),
    messages: () => seen.filter((s) => s.url === fcmSendUrl(PUSH_PROJECT)).map((s) => (JSON.parse(s.body) as { message: unknown }).message),
  };
}

async function until(what: string, check: () => boolean | Promise<boolean>, ms = 3000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!(await check())) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(20);
  }
}

async function tokensOf(uid: string): Promise<string[]> {
  const { results } = await env.DB.prepare("SELECT token FROM push_tokens WHERE user_id = ? ORDER BY id").bind(uid).all<{ token: string }>();
  return results.map((r) => r.token);
}

let tokenCounter = 0;
/** An FCM-looking registration token nobody else has. */
function fcmToken(label = "phone"): string {
  return `${label}-${(tokenCounter++).toString(36)}${crypto.randomUUID().replace(/-/g, "")}:APA91b${"x".repeat(100)}`;
}

async function register(c: Client, token: string): Promise<void> {
  const res = await c.post("/v1/me/push-token", { token });
  expect(res.status, await res.clone().text()).toBe(200);
  expect(await body(res)).toEqual({ ok: true });
}

/** `c`'s nickname for a friend (`PUT /v1/friends/:id/nickname`). */
function nicknameFor(c: Client, friend: string, nickname: string): Promise<Response> {
  return request(`/v1/friends/${friend}/nickname`, {
    method: "PUT",
    headers: { authorization: `Bearer ${c.token}`, "content-type": "application/json" },
    body: JSON.stringify({ nickname }),
  });
}

async function hubSocket(c: Client): Promise<Socket> {
  const s = await connect(c, "/v1/ws/hub");
  await s.next({ op: "OPEN_ROOMS" });
  return s;
}

describe("POST /v1/me/push-token", () => {
  it("stores the caller's token, once", async () => {
    const c = await setUpClient();
    const token = fcmToken();
    await register(c, token);
    await register(c, token);
    expect(await tokensOf(c.uid)).toEqual([token]);
  });

  it("moves a token to the account that registers it", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const shared = fcmToken("shared");
    const mine = fcmToken("mine");
    await register(a, shared);
    await register(a, mine);
    await register(b, shared);
    expect(await tokensOf(a.uid)).toEqual([mine]);
    expect(await tokensOf(b.uid)).toEqual([shared]);
  });

  it("keeps an account's 5 newest tokens", async () => {
    const c = await setUpClient();
    const t = Array.from({ length: 7 }, (_, i) => fcmToken(`t${i}`));
    for (const token of t.slice(0, 6)) await register(c, token);
    expect(await tokensOf(c.uid)).toEqual(t.slice(1, 6));
    // Registering t1 again makes it the newest, so t2 is the one to go next.
    await register(c, t[1]!);
    await register(c, t[6]!);
    expect((await tokensOf(c.uid)).sort()).toEqual([t[1], t[3], t[4], t[5], t[6]].sort());
  });

  it("rejects anything that isn't a token", async () => {
    const c = await setUpClient();
    for (const input of [{}, { token: "" }, { token: 42 }, { token: null }, { token: "has space" }, { token: "x".repeat(4097) }]) {
      const res = await c.post("/v1/me/push-token", input);
      expect(res.status, JSON.stringify(input)).toBe(400);
      expect(await body(res)).toMatchObject({ error: "invalid_push_token" });
      const del = await c.del("/v1/me/push-token", input);
      expect(del.status).toBe(400);
      expect(await body(del)).toMatchObject({ error: "invalid_push_token" });
    }
    const arr = await c.post("/v1/me/push-token", [fcmToken()]);
    expect(await body(arr)).toMatchObject({ error: "invalid_body" });
    expect(await tokensOf(c.uid)).toEqual([]);
  });

  it("needs a set-up account", async () => {
    const c = await client();
    for (const res of [await c.post("/v1/me/push-token", { token: fcmToken() }), await c.del("/v1/me/push-token", { token: fcmToken() })]) {
      expect(res.status).toBe(403);
      expect(await body(res)).toMatchObject({ error: "setup_required" });
    }
  });
});

describe("DELETE /v1/me/push-token", () => {
  it("removes the caller's token; unknown and other people's tokens are left alone", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    const ta = fcmToken();
    const tb = fcmToken();
    await register(a, ta);
    await register(b, tb);

    for (const token of [tb, fcmToken("unknown"), ta]) {
      const res = await a.del("/v1/me/push-token", { token });
      expect(res.status).toBe(200);
      expect(await body(res)).toEqual({ ok: true });
    }
    expect(await tokensOf(a.uid)).toEqual([]);
    expect(await tokensOf(b.uid)).toEqual([tb]);
  });

  it("goes with the account", async () => {
    const c = await setUpClient();
    await register(c, fcmToken());
    await register(c, fcmToken());
    expect((await c.del("/v1/me")).status).toBe(200);
    expect(await tokensOf(c.uid)).toEqual([]);
  });
});

describe("invite notifications", () => {
  let google: ReturnType<typeof fakeGoogle>;

  beforeEach(() => {
    google = fakeGoogle();
    setFcmFetcher(google.fetch);
    setFcmServiceAccount(serviceAccount);
  });

  afterEach(() => {
    setFcmFetcher(null);
    setFcmServiceAccount(null);
  });

  async function friends(): Promise<[Client & { username: string }, Client & { username: string }]> {
    const a = await setUpClient();
    const b = await setUpClient();
    await befriend(a, b);
    return [a, b];
  }

  it("reach an offline friend's phones, signed with the service account, without an error", async () => {
    const [a, b] = await friends();
    const phone = fcmToken("phone");
    const tablet = fcmToken("tablet");
    await register(b, phone);
    await register(b, tablet);
    const sa = await hubSocket(a);

    sa.send({ op: "INVITE", to: b.uid, code: "K7Q2AB", mode: "vs" });
    await until("two sends", () => google.sends().length === 2);

    // One access token, from a JWT signed with the service account's key.
    const [oauth] = google.oauth();
    expect(oauth!.method).toBe("POST");
    expect(oauth!.headers.get("content-type")).toBe("application/x-www-form-urlencoded");
    const form = new URLSearchParams(oauth!.body);
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    const [header, payload, signature] = form.get("assertion")!.split(".");
    expect(JSON.parse(atob(header!.replace(/-/g, "+").replace(/_/g, "/")))).toEqual({ alg: "RS256", typ: "JWT", kid: "test-kid" });
    const claims = JSON.parse(new TextDecoder().decode(base64UrlBytes(payload!))) as Record<string, number | string>;
    expect(claims).toMatchObject({ iss: CLIENT_EMAIL, scope: "https://www.googleapis.com/auth/firebase.messaging", aud: GOOGLE_TOKEN_URL });
    expect(Number(claims.exp) - Number(claims.iat)).toBe(3600);
    const signed = new TextEncoder().encode(`${header}.${payload}`);
    expect(await crypto.subtle.verify(RS256, publicKey, base64UrlBytes(signature!), signed)).toBe(true);

    // One HTTP v1 message per phone.
    for (const send of google.sends()) {
      expect(send.method).toBe("POST");
      expect(send.url).toBe(`https://fcm.googleapis.com/v1/projects/${PUSH_PROJECT}/messages:send`);
      expect(send.headers.get("authorization")).toBe("Bearer ya29.test-access");
      expect(send.headers.get("content-type")).toBe("application/json");
    }
    const expected = (token: string) => ({
      token,
      notification: { title: `${a.username} invited you to Versus`, body: "Tap to join room K7Q2AB" },
      data: { type: "invite", code: "K7Q2AB", mode: "vs", from: a.uid },
      android: { priority: "high", ttl: "300s", collapse_key: "invite-K7Q2AB" },
    });
    expect(google.messages()).toEqual(expect.arrayContaining([expected(phone), expected(tablet)]));

    // No friend_offline, or anything else, for the inviter.
    expect([...sa.seen, ...(await sa.drain())].filter((m) => m.op === "ERROR" && m.code !== "unknown_op")).toEqual([]);

    // The access token is kept for the next invite.
    sa.send({ op: "INVITE", to: b.uid, code: "QQ22ZZ", mode: "coop" });
    await until("two more sends", () => google.sends().length === 4);
    expect(google.oauth()).toHaveLength(1);
    expect(google.messages().slice(2)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ token: phone, notification: { title: `${a.username} invited you to Co-op`, body: "Tap to join room QQ22ZZ" } }),
      ]),
    );
    await closeAll(sa);
  });

  it("reach an online friend's phones too, after the socket relay", async () => {
    const [a, b] = await friends();
    const phone = fcmToken();
    await register(b, phone);
    const sb = await hubSocket(b);
    const sa = await hubSocket(a);
    await sb.next({ op: "PRESENCE", userId: a.uid });

    sa.send({ op: "INVITE", to: b.uid, code: "XYZ234", mode: "coop" });
    expect(await sb.next({ op: "INVITE" })).toEqual({ op: "INVITE", from: a.uid, fromUsername: a.username, code: "XYZ234", mode: "coop" });
    await until("a send", () => google.sends().length === 1);
    expect(google.messages()[0]).toMatchObject({ token: phone, data: { type: "invite", code: "XYZ234", mode: "coop", from: a.uid } });
    expect((await sa.drain()).filter((m) => m.op === "ERROR")).toEqual([]);
    await closeAll(sa, sb);
  });

  it("use the nickname the invited friend gave the inviter", async () => {
    const [a, b] = await friends();
    const phone = fcmToken();
    await register(b, phone);
    expect((await nicknameFor(b, a.uid, "Big Al")).status).toBe(200);
    const sa = await hubSocket(a);

    sa.send({ op: "INVITE", to: b.uid, code: "NICK22", mode: "vs" });
    await until("a send", () => google.sends().length === 1);
    expect(google.messages()[0]).toMatchObject({ token: phone, notification: { title: "Big Al invited you to Versus" } });
    await closeAll(sa);
  });

  it("forget the tokens FCM says are dead, and keep the rest", async () => {
    const [a, b] = await friends();
    const gone = fcmToken("gone");
    const invalid = fcmToken("invalid");
    const flaky = fcmToken("flaky");
    const fine = fcmToken("fine");
    google = fakeGoogle((token): Reply => {
      if (token === gone) {
        return {
          status: 404,
          body: { error: { code: 404, status: "NOT_FOUND", message: "Requested entity was not found.", details: [{ errorCode: "UNREGISTERED" }] } },
        };
      }
      if (token === invalid) {
        return {
          status: 400,
          body: {
            error: {
              code: 400,
              status: "INVALID_ARGUMENT",
              message: "The registration token is not a valid FCM registration token",
              details: [{ errorCode: "INVALID_ARGUMENT" }],
            },
          },
        };
      }
      if (token === flaky) return { status: 503, body: { error: { code: 503, status: "UNAVAILABLE", message: "Try later" } } };
      return { status: 200, body: { name: "m/1" } };
    });
    setFcmFetcher(google.fetch);
    for (const token of [gone, invalid, flaky, fine]) await register(b, token);
    const sa = await hubSocket(a);

    sa.send({ op: "INVITE", to: b.uid, code: "K7Q2AB", mode: "vs" });
    await until("four sends", () => google.sends().length === 4);
    await until("the dead tokens to go", async () => (await tokensOf(b.uid)).length === 2);
    expect((await tokensOf(b.uid)).sort()).toEqual([flaky, fine].sort());
    expect((await sa.drain()).filter((m) => m.op === "ERROR")).toEqual([]);

    // With every token gone, an offline friend is offline again.
    await env.DB.prepare("DELETE FROM push_tokens WHERE user_id = ?").bind(b.uid).run();
    sa.send({ op: "INVITE", to: b.uid, code: "K7Q2AB", mode: "vs" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "friend_offline" });
    await closeAll(sa);
  });

  it("still say friend_offline when the friend has no socket and no phone", async () => {
    const [a, b] = await friends();
    const sa = await hubSocket(a);
    sa.send({ op: "INVITE", to: b.uid, code: "K7Q2AB", mode: "coop" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "friend_offline" });
    // Nobody to notify, so Google never hears about it.
    expect(google.seen).toEqual([]);
    // And strangers still get not_friends, phones or not.
    const stranger = await setUpClient();
    await register(stranger, fcmToken());
    sa.send({ op: "INVITE", to: stranger.uid, code: "K7Q2AB", mode: "coop" });
    expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "not_friends" });
    expect(google.seen).toEqual([]);
    await closeAll(sa);
  });

  it("are off without a usable FCM_SERVICE_ACCOUNT: invites work as before", async () => {
    expect(env.FCM_SERVICE_ACCOUNT).toBeUndefined();
    for (const secret of [null, "{not a key"]) {
      setFcmServiceAccount(secret);
      const [a, b] = await friends();
      await register(b, fcmToken());
      const sa = await hubSocket(a);

      sa.send({ op: "INVITE", to: b.uid, code: "K7Q2AB", mode: "vs" });
      expect(await sa.next({ op: "ERROR" })).toEqual({ op: "ERROR", code: "friend_offline" });

      const sb = await hubSocket(b);
      sa.send({ op: "INVITE", to: b.uid, code: "K7Q2AB", mode: "vs" });
      expect(await sb.next({ op: "INVITE" })).toMatchObject({ from: a.uid, code: "K7Q2AB" });
      await closeAll(sa, sb);
    }
    expect(google.seen).toEqual([]);
  });
});

describe("gift notifications (shared/forge-board.md, \"Gifts\")", () => {
  let google: ReturnType<typeof fakeGoogle>;

  beforeEach(() => {
    google = fakeGoogle((token) => (token.startsWith("dead") ? { status: 404, body: { error: { status: "NOT_FOUND" } } } : { status: 200, body: { name: "m" } }));
    setFcmFetcher(google.fetch);
    setFcmServiceAccount(serviceAccount);
  });

  afterEach(() => {
    setFcmFetcher(null);
    setFcmServiceAccount(null);
  });

  it("tell the friend about the gift on each of their phones, and forget dead tokens", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    await befriend(a, b);
    const phone = fcmToken("phone");
    const dead = fcmToken("dead");
    await register(b, phone);
    await register(b, dead);

    const res = await a.post(`/v1/friends/${b.uid}/gift`, {});
    expect(res.status, await res.clone().text()).toBe(200);
    await until("two sends", () => google.sends().length === 2);
    const expected = (token: string) => ({
      token,
      notification: { title: `${a.username} sent you a gift`, body: "A free Hammer Strike is waiting in the Forge Hall" },
      data: { type: "gift", from: a.uid },
      android: { priority: "normal", ttl: "86400s", collapse_key: `gift-${a.uid}` },
    });
    expect(google.messages()).toEqual(expect.arrayContaining([expected(phone), expected(dead)]));
    await until("the dead token forgotten", async () => (await tokensOf(b.uid)).length === 1);
    expect(await tokensOf(b.uid)).toEqual([phone]);

    // A gift that isn't sent (already sent today) notifies nobody.
    expect((await a.post(`/v1/friends/${b.uid}/gift`, {})).status).toBe(409);
    await sleep(100);
    expect(google.sends()).toHaveLength(2);
  });

  it("use the nickname the receiver gave the sender", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    await befriend(a, b);
    await register(b, fcmToken("phone"));
    expect((await nicknameFor(b, a.uid, "Auntie 🔨")).status).toBe(200);
    expect((await a.post(`/v1/friends/${b.uid}/gift`, {})).status).toBe(200);
    await until("a send", () => google.sends().length === 1);
    expect(google.messages()[0]).toMatchObject({ notification: { title: "Auntie 🔨 sent you a gift" } });
  });

  it("send nothing to a friend with no phones, and the gift still goes", async () => {
    const a = await setUpClient();
    const b = await setUpClient();
    await befriend(a, b);
    expect((await a.post(`/v1/friends/${b.uid}/gift`, {})).status).toBe(200);
    await sleep(100);
    expect(google.sends()).toHaveLength(0);
    expect((await body<{ gifts: { pending: unknown[] } }>(await b.get("/v1/me/board"))).gifts.pending).toHaveLength(1);
  });
});

describe("daily reminders (shared/push.md, \"Daily reminders\")", () => {
  let google: ReturnType<typeof fakeGoogle>;

  beforeEach(() => {
    google = fakeGoogle();
    setFcmFetcher(google.fetch);
    setFcmServiceAccount(serviceAccount);
  });

  afterEach(() => {
    setFcmFetcher(null);
    setFcmServiceAccount(null);
  });

  async function setHour(c: Client, hour: unknown): Promise<{ status: number; body: Record<string, unknown> }> {
    const res = await request("/v1/me/reminder", {
      method: "PUT",
      headers: { authorization: `Bearer ${c.token}`, "content-type": "application/json" },
      body: JSON.stringify(hour === undefined ? {} : { hour }),
    });
    return { status: res.status, body: await body(res) };
  }

  /** The hourly Cron Trigger, as if it fired at `iso`. */
  async function cron(iso: string): Promise<void> {
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({ scheduledTime: Date.parse(iso), cron: "0 * * * *" }), env, ctx);
    await waitOnExecutionContext(ctx);
  }

  async function done(uid: string, ...days: [string, number][]): Promise<void> {
    const insert = env.DB.prepare("INSERT INTO daily_completions (user_id, date, completed_at, xp, late) VALUES (?1, ?2, 0, 0, ?3)");
    await env.DB.batch(days.map(([date, late]) => insert.bind(uid, date, late)));
  }

  const lastReminded = async (uid: string) => env.DB.prepare("SELECT reminder_last AS d FROM profiles WHERE user_id = ?1").bind(uid).first<string | null>("d");

  it("sets the hour, which the profile shows", async () => {
    const c = await setUpClient();
    expect((await body(await c.get("/v1/me"))).reminderHour).toBeNull();
    expect(await setHour(c, 7)).toEqual({ status: 200, body: { ok: true, hour: 7 } });
    expect((await body(await c.get("/v1/me"))).reminderHour).toBe(7);
    expect(await setHour(c, null)).toEqual({ status: 200, body: { ok: true, hour: null } });
    expect((await body(await c.get("/v1/me"))).reminderHour).toBeNull();
    for (const bad of [24, -1, 7.5, "7", undefined]) expect(await setHour(c, bad)).toMatchObject({ status: 400, body: { error: "invalid_body" } });
    expect((await setHour(await client(), 7)).status).toBe(403);
  });

  it("reminds each account due this hour once a day, with its streak, unless today's is done", async () => {
    const [streaky, fresh, finished, noPhone, later, off] = await Promise.all(Array.from({ length: 6 }, () => setUpClient()));
    const tokens = new Map<string, string>();
    for (const c of [streaky, fresh, finished, later, off]) {
      const token = fcmToken("phone");
      tokens.set(c!.uid, token);
      await register(c!, token);
    }
    for (const c of [streaky, fresh, finished, noPhone]) expect((await setHour(c!, 3)).status).toBe(200);
    expect((await setHour(later!, 4)).status).toBe(200);
    // Three on-time days to yesterday; a late day doesn't make a streak; today's done.
    await done(streaky!.uid, ["2026-03-14", 0], ["2026-03-15", 0], ["2026-03-16", 0]);
    await done(fresh!.uid, ["2026-03-16", 1]);
    await done(finished!.uid, ["2026-03-16", 0], ["2026-03-17", 0]);

    await cron("2026-03-17T03:00:00Z");
    const to = (c: Client) => google.messages().filter((m) => (m as { token: string }).token === tokens.get(c.uid));
    expect(to(streaky!)).toEqual([
      {
        token: tokens.get(streaky!.uid),
        notification: { title: "Today's Daily Commission is waiting", body: "Keep your 3-day streak going!" },
        data: { type: "daily" },
        android: { priority: "normal", ttl: "3600s", collapse_key: "daily" },
      },
    ]);
    expect(to(fresh!)).toMatchObject([{ notification: { body: "A new puzzle is on the anvil." } }]);
    for (const c of [finished!, later!, off!]) expect(to(c)).toEqual([]);
    expect(await lastReminded(streaky!.uid)).toBe("2026-03-17");
    expect(await lastReminded(noPhone!.uid)).toBeNull();

    // Not twice in a day, even if the trigger fires again.
    const sent = google.sends().length;
    await cron("2026-03-17T03:00:00Z");
    expect(google.sends()).toHaveLength(sent);
    // The next day at the same hour, yes: the streak (ending yesterday) is gone now.
    await cron("2026-03-18T03:00:00Z");
    expect(to(streaky!).map((m) => (m as { notification: { body: string } }).notification.body)).toEqual([
      "Keep your 3-day streak going!",
      "A new puzzle is on the anvil.",
    ]);
    expect(to(finished!)).toHaveLength(1);
    // And the other account at its own hour.
    await cron("2026-03-18T04:00:00Z");
    expect(to(later!)).toHaveLength(1);
  });

  it("takes the accounts reminded longest ago first, and does nothing without an FCM key", async () => {
    const [a, b, c] = await Promise.all(Array.from({ length: 3 }, () => setUpClient()));
    for (const x of [a!, b!, c!]) {
      await register(x, fcmToken("phone"));
      expect((await setHour(x, 5)).status).toBe(200);
    }
    await env.DB.prepare("UPDATE profiles SET reminder_last = ?2 WHERE user_id = ?1").bind(a!.uid, "2026-04-02").run();
    await env.DB.prepare("UPDATE profiles SET reminder_last = ?2 WHERE user_id = ?1").bind(b!.uid, "2026-04-01").run();
    const due = await dueReminders(env.DB, 5, "2026-04-03", 2);
    expect(due).toEqual([c!.uid, b!.uid]);

    setFcmServiceAccount(null);
    await cron("2026-04-03T05:00:00Z");
    expect(google.sends()).toEqual([]);
    expect(await lastReminded(c!.uid)).toBeNull();
  });
});
