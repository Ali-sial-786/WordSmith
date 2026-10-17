/**
 * Test helpers for the Worker: an RSA key pair standing in for Google's
 * `securetoken` keys, Firebase-shaped ID tokens signed with it, and small
 * API clients.
 */

import { env, exports } from "cloudflare:workers";
import { setJwksFetcher, type Jwk } from "../../src/auth/firebase";

export const BASE = "https://api.test";
export const PROJECT_ID = env.FIREBASE_PROJECT_ID;

export interface TestKey {
  readonly kid: string;
  readonly privateKey: CryptoKey;
  readonly publicJwk: Jwk;
}

export async function makeKey(kid: string): Promise<TestKey> {
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const exported = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
  return {
    kid,
    privateKey: pair.privateKey,
    publicJwk: { kty: "RSA", kid, alg: "RS256", use: "sig", n: exported.n!, e: exported.e! },
  };
}

let installed: Promise<TestKey> | null = null;

/** The key the Worker trusts in tests (installed once per test file). */
export function trustedKey(): Promise<TestKey> {
  installed ??= makeKey("test-key-1").then((key) => {
    setJwksFetcher(async () => ({ keys: [key.publicJwk], maxAgeSeconds: 3600 }));
    return key;
  });
  return installed;
}

const utf8 = new TextEncoder();

export function base64Url(bytes: Uint8Array | string): string {
  const raw = typeof bytes === "string" ? utf8.encode(bytes) : bytes;
  let binary = "";
  for (const b of raw) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export interface SignOptions {
  readonly key?: TestKey;
  /** Overrides or adds header fields. */
  readonly header?: Record<string, unknown>;
}

/** A Firebase-shaped ID token for `uid`. `claims` override the defaults. */
export async function signToken(uid: string, claims: Record<string, unknown> = {}, options: SignOptions = {}): Promise<string> {
  const key = options.key ?? (await trustedKey());
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", kid: key.kid, typ: "JWT", ...options.header };
  const payload = {
    iss: `https://securetoken.google.com/${PROJECT_ID}`,
    aud: PROJECT_ID,
    auth_time: now - 60,
    user_id: uid,
    sub: uid,
    iat: now - 10,
    exp: now + 3600,
    firebase: { sign_in_provider: "password" },
    ...claims,
  };
  const signingInput = `${base64Url(JSON.stringify(header))}.${base64Url(JSON.stringify(payload))}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key.privateKey, utf8.encode(signingInput));
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}

export function request(path: string, init: RequestInit = {}): Promise<Response> {
  return exports.default.fetch(new Request(BASE + path, init));
}

let counter = 0;
/** A user ID nobody else in this run has. */
export function uniqueUid(prefix = "uid"): string {
  return `${prefix}-${Date.now().toString(36)}-${(counter++).toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

/** A username nobody else in this run has (3–16 chars). */
export function uniqueName(prefix = "smith"): string {
  return `${prefix.slice(0, 6)}_${(counter++).toString(36)}${Math.random().toString(36).slice(2, 6)}`.slice(0, 16);
}

export interface Client {
  readonly uid: string;
  readonly token: string;
  get(path: string): Promise<Response>;
  post(path: string, body: unknown): Promise<Response>;
  /** A DELETE, with a JSON body if `body` is given. */
  del(path: string, body?: unknown): Promise<Response>;
}

export async function client(uid = uniqueUid()): Promise<Client> {
  const token = await signToken(uid);
  const auth = { authorization: `Bearer ${token}` };
  return {
    uid,
    token,
    get: (path) => request(path, { headers: auth }),
    post: (path, body) =>
      request(path, { method: "POST", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify(body) }),
    del: (path, body) =>
      body === undefined
        ? request(path, { method: "DELETE", headers: auth })
        : request(path, { method: "DELETE", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify(body) }),
  };
}

/**
 * A client whose account has a username and avatar. A generated name that
 * happens to trip the profanity filter is replaced by another.
 */
export async function setUpClient(username?: string, avatar = "avatar_01", uid = uniqueUid()): Promise<Client & { username: string }> {
  const c = await client(uid);
  for (let attempt = 0; ; attempt++) {
    const name = username ?? uniqueName();
    const res = await c.post("/v1/me/setup", { username: name, avatar });
    if (res.status === 200) return { ...c, username: name };
    const text = await res.text();
    if (username !== undefined || attempt >= 5 || !text.includes("username_not_allowed")) {
      throw new Error(`setup failed: ${res.status} ${text}`);
    }
  }
}

/** Makes two set-up clients friends. */
export async function befriend(a: Client & { username: string }, b: Client & { username: string }): Promise<void> {
  const r1 = await a.post("/v1/friends/request", { username: b.username });
  if (r1.status !== 200) throw new Error(`request failed: ${r1.status} ${await r1.text()}`);
  const r2 = await b.post("/v1/friends/respond", { userId: a.uid, accept: true });
  if (r2.status !== 200) throw new Error(`respond failed: ${r2.status} ${await r2.text()}`);
}

export async function body<T = Record<string, unknown>>(res: Response): Promise<T> {
  return (await res.json()) as T;
}
