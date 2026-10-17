import { describe, expect, it } from "vitest";
import { JwksCache, parseMaxAge, verifyFirebaseToken, type JwksResult } from "../../src/auth/firebase";
import { base64Url, body, makeKey, PROJECT_ID, request, signToken, trustedKey, uniqueUid } from "./helpers";

async function getMe(token: string | null, headers: Record<string, string> = {}): Promise<Response> {
  return request("/v1/me", { headers: token === null ? headers : { authorization: `Bearer ${token}`, ...headers } });
}

async function expect401(res: Response, reason: string): Promise<void> {
  expect(res.status).toBe(401);
  expect(res.headers.get("content-type")).toMatch(/^application\/json/);
  expect(await res.json()).toEqual({ error: "unauthorized", message: reason });
}

describe("Firebase ID tokens (REST)", () => {
  it("accepts a valid token and uses sub as the user ID", async () => {
    const uid = uniqueUid();
    const res = await getMe(await signToken(uid));
    expect(res.status).toBe(200);
    expect((await body(res)).id).toBe(uid);
  });

  it("rejects a missing or non-Bearer Authorization header", async () => {
    await expect401(await getMe(null), "missing_token");
    await expect401(await getMe(null, { authorization: "Basic abc" }), "missing_token");
  });

  it("rejects garbage", async () => {
    await expect401(await getMe("not-a-jwt"), "malformed");
    await expect401(await getMe("a.b.c"), "malformed");
  });

  it("rejects an expired token, allowing 60 s of clock skew", async () => {
    const now = Math.floor(Date.now() / 1000);
    await expect401(await getMe(await signToken(uniqueUid(), { iat: now - 7200, exp: now - 120 })), "expired");
    const res = await getMe(await signToken(uniqueUid(), { iat: now - 3600, exp: now - 30 }));
    expect(res.status).toBe(200);
  });

  it("rejects a token issued in the future", async () => {
    const now = Math.floor(Date.now() / 1000);
    await expect401(await getMe(await signToken(uniqueUid(), { iat: now + 600, exp: now + 4000 })), "issued_in_future");
  });

  it("rejects the wrong audience or issuer", async () => {
    await expect401(await getMe(await signToken(uniqueUid(), { aud: "some-other-project" })), "bad_audience");
    await expect401(
      await getMe(await signToken(uniqueUid(), { iss: "https://securetoken.google.com/some-other-project" })),
      "bad_issuer",
    );
    await expect401(await getMe(await signToken(uniqueUid(), { iss: `https://evil.example/${PROJECT_ID}` })), "bad_issuer");
  });

  it("rejects an empty or missing subject", async () => {
    await expect401(await getMe(await signToken("", { sub: "" })), "bad_subject");
    await expect401(await getMe(await signToken("x", { sub: undefined })), "bad_subject");
    await expect401(await getMe(await signToken("x", { sub: "a".repeat(129) })), "bad_subject");
  });

  it("rejects an auth_time in the future", async () => {
    const now = Math.floor(Date.now() / 1000);
    await expect401(await getMe(await signToken(uniqueUid(), { auth_time: now + 3600 })), "bad_auth_time");
    await expect401(await getMe(await signToken(uniqueUid(), { auth_time: undefined })), "bad_auth_time");
  });

  it("rejects a bad signature", async () => {
    const token = await signToken(uniqueUid());
    const [h, p, s] = token.split(".");
    // Same header and signature, different payload.
    const forged = `${h}.${base64Url(JSON.stringify({ ...JSON.parse(atob(p!.replace(/-/g, "+").replace(/_/g, "/"))), sub: "someone-else" }))}.${s}`;
    await expect401(await getMe(forged), "bad_signature");
    // Signed by a key with the trusted kid but a different secret.
    const impostor = await makeKey((await trustedKey()).kid);
    await expect401(await getMe(await signToken(uniqueUid(), {}, { key: impostor })), "bad_signature");
  });

  it("rejects an unknown kid, or none", async () => {
    const stranger = await makeKey("unknown-kid");
    await expect401(await getMe(await signToken(uniqueUid(), {}, { key: stranger })), "unknown_kid");
    await expect401(await getMe(await signToken(uniqueUid(), {}, { header: { kid: undefined } })), "unknown_kid");
  });

  it("rejects any algorithm but RS256", async () => {
    await expect401(await getMe(await signToken(uniqueUid(), {}, { header: { alg: "HS256" } })), "bad_alg");
    await expect401(await getMe(await signToken(uniqueUid(), {}, { header: { alg: "none" } })), "bad_alg");
  });

  it("protects every route but /v1/version and /v1/health", async () => {
    const routes: [string, string][] = [
      ["GET", "/v1/me"],
      ["POST", "/v1/me/setup"],
      ["DELETE", "/v1/me"],
      ["GET", "/v1/users/someone"],
      ["POST", "/v1/solo/sync"],
      ["GET", "/v1/friends"],
      ["POST", "/v1/friends/request"],
      ["POST", "/v1/friends/respond"],
      ["DELETE", "/v1/friends/abc"],
      ["GET", "/v1/leaderboard"],
    ];
    for (const [method, path] of routes) {
      await expect401(await request(path, { method }), "missing_token");
    }
    expect((await request("/v1/health")).status).toBe(200);
    expect((await request("/v1/version")).status).toBe(200);
  });
});

describe("verifyFirebaseToken", () => {
  it("returns the identity", async () => {
    const key = await makeKey("k1");
    const cache = new JwksCache(async () => ({ keys: [key.publicJwk], maxAgeSeconds: 60 }));
    const token = await signToken("user-9", { email: "a@example.com" }, { key });
    const id = await verifyFirebaseToken(token, { projectId: PROJECT_ID, keys: cache.lookup });
    expect(id.uid).toBe("user-9");
    expect(id.email).toBe("a@example.com");
  });
});

describe("JwksCache", () => {
  it("parses Cache-Control max-age", () => {
    expect(parseMaxAge("public, max-age=19302, must-revalidate, no-transform")).toBe(19302);
    expect(parseMaxAge("max-age=0")).toBe(0);
    expect(parseMaxAge("no-cache")).toBeNull();
    expect(parseMaxAge(null)).toBeNull();
    expect(parseMaxAge("s-maxage=10")).toBeNull();
  });

  it("keeps keys for max-age, then refetches", async () => {
    const k1 = await makeKey("k1");
    let now = 1_000_000;
    let served: JwksResult = { keys: [k1.publicJwk], maxAgeSeconds: 600 };
    const cache = new JwksCache(async () => served, () => now);

    expect(await cache.lookup("k1")).not.toBeNull();
    expect(await cache.lookup("k1")).not.toBeNull();
    expect(cache.fetchCount).toBe(1);

    now += 599_000;
    await cache.lookup("k1");
    expect(cache.fetchCount).toBe(1);

    const k2 = await makeKey("k2");
    served = { keys: [k2.publicJwk], maxAgeSeconds: 600 };
    now += 2_000; // past max-age
    expect(await cache.lookup("k2")).not.toBeNull();
    expect(await cache.lookup("k1")).toBeNull(); // rotated out
    expect(cache.fetchCount).toBe(2);
  });

  it("refetches early for an unknown kid, but at most every 30 s", async () => {
    const k1 = await makeKey("k1");
    const k2 = await makeKey("k2");
    let now = 0;
    let served: JwksResult = { keys: [k1.publicJwk], maxAgeSeconds: 3600 };
    const cache = new JwksCache(async () => served, () => now);
    await cache.lookup("k1");

    served = { keys: [k1.publicJwk, k2.publicJwk], maxAgeSeconds: 3600 };
    now += 31_000;
    expect(await cache.lookup("k2")).not.toBeNull();
    expect(cache.fetchCount).toBe(2);

    now += 1_000;
    expect(await cache.lookup("nope")).toBeNull();
    expect(await cache.lookup("nope")).toBeNull();
    expect(cache.fetchCount).toBe(2);
  });

  it("serves old keys when a refresh fails, and fails only with none", async () => {
    const k1 = await makeKey("k1");
    let now = 0;
    let fail = false;
    const cache = new JwksCache(async () => {
      if (fail) throw new Error("network down");
      return { keys: [k1.publicJwk], maxAgeSeconds: 60 };
    }, () => now);
    await cache.lookup("k1");
    fail = true;
    now += 120_000;
    expect(await cache.lookup("k1")).not.toBeNull();

    const empty = new JwksCache(async () => {
      throw new Error("network down");
    });
    await expect(empty.lookup("k1")).rejects.toMatchObject({ reason: "keys_unavailable" });
  });

  it("shares one fetch between concurrent lookups", async () => {
    const k1 = await makeKey("k1");
    const cache = new JwksCache(async () => {
      await new Promise((r) => setTimeout(r, 5));
      return { keys: [k1.publicJwk], maxAgeSeconds: 600 };
    });
    const keys = await Promise.all([cache.lookup("k1"), cache.lookup("k1"), cache.lookup("k1")]);
    expect(keys.every((k) => k !== null)).toBe(true);
    expect(cache.fetchCount).toBe(1);
  });

  it("ignores keys that aren't RS256 signing keys", async () => {
    const k1 = await makeKey("k1");
    const cache = new JwksCache(async () => ({
      keys: [{ ...k1.publicJwk, kid: "enc", use: "enc" }, { kty: "EC", kid: "ec" }, k1.publicJwk],
      maxAgeSeconds: 600,
    }));
    expect(await cache.lookup("k1")).not.toBeNull();
    expect(await cache.lookup("enc")).toBeNull();
    expect(await cache.lookup("ec")).toBeNull();
  });
});

describe("token in the WebSocket subprotocol", () => {
  it("is read from Sec-WebSocket-Protocol and wordsmith.v1 is echoed", async () => {
    // Needs a set-up account; a fresh one gets 403, which still proves the token was accepted.
    const uid = uniqueUid();
    const token = await signToken(uid);
    const res = await request("/v1/ws/hub", { headers: { upgrade: "websocket", "sec-websocket-protocol": `wordsmith.v1, ${token}` } });
    expect(res.status).toBe(403);
    expect(await res.json()).toMatchObject({ error: "setup_required" });
  });

  it("401s without a token", async () => {
    const res = await request("/v1/ws/hub", { headers: { upgrade: "websocket", "sec-websocket-protocol": "wordsmith.v1" } });
    await expect401(res, "missing_token");
  });

  it("426s without an upgrade", async () => {
    const res = await request("/v1/ws/hub");
    expect(res.status).toBe(426);
    expect(await res.json()).toMatchObject({ error: "upgrade_required" });
  });
});
