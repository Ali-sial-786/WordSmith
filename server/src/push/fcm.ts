/**
 * Firebase Cloud Messaging with the HTTP v1 API (shared/push.md), using
 * WebCrypto and no Admin SDK.
 *
 * The Worker secret `FCM_SERVICE_ACCOUNT` holds a service account's JSON key
 * (`client_email`, `private_key`, `project_id`). To send, the server signs a
 * JWT with the key (RS256), trades it at Google's OAuth endpoint for an
 * access token, and keeps that token per isolate until
 * {@link ACCESS_TOKEN_MARGIN_MS} before it expires. While the secret is
 * missing or malformed, {@link fcmSender} returns `null` and nothing is sent.
 *
 * Tests swap the network with {@link setFcmFetcher} and the secret with
 * {@link setFcmServiceAccount}.
 */

import { isRecord } from "../http";

export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
export const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const JWT_BEARER_GRANT = "urn:ietf:params:oauth:grant-type:jwt-bearer";

export function fcmSendUrl(projectId: string): string {
  return `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/messages:send`;
}

/** Lifetime of the signed JWT we trade for an access token (Google allows at most an hour). */
export const ASSERTION_TTL_SECONDS = 3600;

/** An access token is replaced this long before it expires. */
export const ACCESS_TOKEN_MARGIN_MS = 5 * 60_000;

/** Google's access tokens last an hour; assumed when a response doesn't say. */
const DEFAULT_ACCESS_TOKEN_TTL_SECONDS = 3600;

// ---------------------------------------------------------------------------
// The service account
// ---------------------------------------------------------------------------

export interface ServiceAccount {
  readonly clientEmail: string;
  /** PKCS#8 PEM (`-----BEGIN PRIVATE KEY-----`). */
  readonly privateKey: string;
  readonly projectId: string;
  /** Sent as the JWT's `kid` when the key file has one. */
  readonly privateKeyId: string | null;
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== "";
}

/** The DER bytes inside a PKCS#8 PEM, or `null` if it isn't one. */
function pemBytes(pem: string): Uint8Array<ArrayBuffer> | null {
  // A key pasted with its JSON escapes still in it has literal "\n"s.
  const text = pem.replace(/\\n/g, "\n");
  const match = /-----BEGIN PRIVATE KEY-----([^-]*)-----END PRIVATE KEY-----/.exec(text);
  if (match === null) return null;
  const base64 = match[1]!.replace(/\s+/g, "");
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(base64)) return null;
  try {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

/** The service account in a JSON key file, or `null` if it's missing or malformed. */
export function parseServiceAccount(raw: string | null | undefined): ServiceAccount | null {
  if (typeof raw !== "string" || raw.trim() === "") return null;
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isRecord(value)) return null;
  const { client_email, private_key, project_id, private_key_id } = value;
  if (!nonEmpty(client_email) || !nonEmpty(project_id) || typeof private_key !== "string" || pemBytes(private_key) === null) {
    return null;
  }
  return {
    clientEmail: client_email.trim(),
    privateKey: private_key,
    projectId: project_id.trim(),
    privateKeyId: nonEmpty(private_key_id) ? private_key_id.trim() : null,
  };
}

const RS256 = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };

/** Imports a PKCS#8 PEM RSA key for RS256 signing. */
export async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const der = pemBytes(pem);
  if (der === null) throw new Error("not a PKCS#8 PEM private key");
  return crypto.subtle.importKey("pkcs8", der, RS256, false, ["sign"]);
}

// ---------------------------------------------------------------------------
// The OAuth assertion
// ---------------------------------------------------------------------------

const utf8 = new TextEncoder();

function base64Url(bytes: Uint8Array | string): string {
  const raw = typeof bytes === "string" ? utf8.encode(bytes) : bytes;
  let binary = "";
  for (const b of raw) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The claims of the JWT Google trades for an FCM access token. */
export function assertionClaims(account: ServiceAccount, nowSeconds: number): Record<string, unknown> {
  return {
    iss: account.clientEmail,
    scope: FCM_SCOPE,
    aud: GOOGLE_TOKEN_URL,
    iat: nowSeconds,
    exp: nowSeconds + ASSERTION_TTL_SECONDS,
  };
}

/** Signs the assertion (RS256) with the service account's key. */
export async function signAssertion(account: ServiceAccount, key: CryptoKey, nowSeconds: number): Promise<string> {
  const header: Record<string, string> = { alg: "RS256", typ: "JWT" };
  if (account.privateKeyId !== null) header.kid = account.privateKeyId;
  const signingInput = `${base64Url(JSON.stringify(header))}.${base64Url(JSON.stringify(assertionClaims(account, nowSeconds)))}`;
  const signature = await crypto.subtle.sign(RS256, key, utf8.encode(signingInput));
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}

// ---------------------------------------------------------------------------
// Messages and what FCM says about them
// ---------------------------------------------------------------------------

/** The parts of an HTTP v1 `message` we use. */
export interface FcmMessage {
  readonly token: string;
  readonly notification?: { readonly title: string; readonly body: string };
  /** Values must be strings. */
  readonly data?: Readonly<Record<string, string>>;
  readonly android?: {
    readonly priority?: "high" | "normal";
    /** Seconds with an `s`, such as `"300s"`. */
    readonly ttl?: string;
    readonly collapse_key?: string;
  };
}

/**
 * What a send's response means for the token it went to:
 * - `sent`: delivered to FCM.
 * - `drop_token`: the token is dead (404 or `UNREGISTERED`, or 400
 *   `INVALID_ARGUMENT` about the token), so we should forget it.
 * - `failed`: anything else (our credentials, quota, FCM being down, a bad
 *   message). Logged and otherwise ignored; the token is kept.
 */
export type SendOutcome = "sent" | "drop_token" | "failed";

export function sendOutcome(status: number, body: unknown): SendOutcome {
  if (status >= 200 && status < 300) return "sent";
  if (status === 404) return "drop_token";
  const error = isRecord(body) && isRecord(body.error) ? body.error : null;
  if (error === null) return "failed";
  const details = Array.isArray(error.details) ? error.details.filter(isRecord) : [];
  const codes = details.map((d) => d.errorCode);
  if (codes.includes("UNREGISTERED")) return "drop_token";
  const invalidArgument = error.status === "INVALID_ARGUMENT" || codes.includes("INVALID_ARGUMENT");
  if (status === 400 && invalidArgument && aboutToken(error, details)) return "drop_token";
  return "failed";
}

/** Whether a 400 is about `message.token` rather than the rest of the message. */
function aboutToken(error: Record<string, unknown>, details: readonly Record<string, unknown>[]): boolean {
  for (const d of details) {
    const violations = Array.isArray(d.fieldViolations) ? d.fieldViolations.filter(isRecord) : [];
    if (violations.some((v) => v.field === "message.token")) return true;
  }
  return typeof error.message === "string" && /registration token/i.test(error.message);
}

async function readBody(res: Response): Promise<unknown> {
  const text = await res.text();
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return text;
  }
}

/** A short description of an error body, for logs. */
function describe(body: unknown): string {
  if (isRecord(body) && isRecord(body.error)) return `${String(body.error.status ?? "")} ${String(body.error.message ?? "")}`.trim();
  if (isRecord(body) && typeof body.error === "string") return body.error;
  return typeof body === "string" ? body.slice(0, 200) : "";
}

// ---------------------------------------------------------------------------
// The sender
// ---------------------------------------------------------------------------

const defaultFetch: typeof fetch = (input, init) => fetch(input, init);

export interface FcmSenderOptions {
  /** Defaults to the global `fetch`. */
  readonly fetch?: typeof fetch;
  /** Epoch ms; defaults to `Date.now`. */
  readonly clock?: () => number;
}

/** Sends messages for one service account, keeping its access token. */
export class FcmSender {
  private readonly fetchFn: typeof fetch;
  private readonly clock: () => number;
  private key: Promise<CryptoKey> | null = null;
  private cached: { readonly token: string; readonly expiresAt: number } | null = null;
  private inflight: Promise<string> | null = null;

  constructor(
    readonly account: ServiceAccount,
    options: FcmSenderOptions = {},
  ) {
    this.fetchFn = options.fetch ?? defaultFetch;
    this.clock = options.clock ?? Date.now;
  }

  /**
   * A current access token: the cached one, or a fresh one from Google (one
   * request at a time). Throws if Google refuses.
   */
  accessToken(): Promise<string> {
    const cached = this.cached;
    if (cached !== null && this.clock() < cached.expiresAt - ACCESS_TOKEN_MARGIN_MS) return Promise.resolve(cached.token);
    this.inflight ??= this.fetchAccessToken().finally(() => {
      this.inflight = null;
    });
    return this.inflight;
  }

  private async fetchAccessToken(): Promise<string> {
    this.key ??= importPrivateKey(this.account.privateKey);
    const key = await this.key.catch((err: unknown) => {
      this.key = null;
      throw err;
    });
    const now = this.clock();
    const assertion = await signAssertion(this.account, key, Math.floor(now / 1000));
    const res = await this.fetchFn(GOOGLE_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: JWT_BEARER_GRANT, assertion }).toString(),
    });
    const body = await readBody(res);
    if (!res.ok || !isRecord(body) || !nonEmpty(body.access_token)) {
      throw new Error(`Google OAuth token request failed: HTTP ${res.status} ${describe(body)}`.trim());
    }
    const ttl = typeof body.expires_in === "number" && body.expires_in > 0 ? body.expires_in : DEFAULT_ACCESS_TOKEN_TTL_SECONDS;
    this.cached = { token: body.access_token, expiresAt: now + ttl * 1000 };
    return body.access_token;
  }

  /** Sends one message. Never rejects: anything that goes wrong is logged and comes back as `failed`. */
  async send(message: FcmMessage): Promise<SendOutcome> {
    try {
      const accessToken = await this.accessToken();
      const res = await this.fetchFn(fcmSendUrl(this.account.projectId), {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ message }),
      });
      const body = await readBody(res);
      // Google no longer takes the access token; the next send fetches another.
      if (res.status === 401) this.cached = null;
      const outcome = sendOutcome(res.status, body);
      if (outcome === "failed") console.warn(`FCM send failed: HTTP ${res.status} ${describe(body)}`.trim());
      return outcome;
    } catch (err) {
      console.warn("FCM send failed", err);
      return "failed";
    }
  }
}

// ---------------------------------------------------------------------------
// One sender per isolate
// ---------------------------------------------------------------------------

export interface FcmEnv {
  FCM_SERVICE_ACCOUNT?: string;
}

let fetcher: typeof fetch = defaultFetch;
let serviceAccountOverride: string | null = null;
let current: { readonly raw: string; readonly sender: FcmSender | null } | null = null;

/**
 * The sender for the configured service account, or `null` while
 * `FCM_SERVICE_ACCOUNT` is missing or malformed (push is off). Kept per
 * isolate, so its access token is reused.
 */
export function fcmSender(env: FcmEnv): FcmSender | null {
  const raw = serviceAccountOverride ?? env.FCM_SERVICE_ACCOUNT ?? "";
  if (current === null || current.raw !== raw) {
    const account = parseServiceAccount(raw);
    if (account === null && raw.trim() !== "") {
      console.warn("FCM_SERVICE_ACCOUNT isn't a service account key (client_email, private_key, project_id); invite notifications are off");
    }
    current = { raw, sender: account === null ? null : new FcmSender(account, { fetch: fetcher }) };
  }
  return current.sender;
}

/**
 * For tests: where requests to Google go instead of `fetch` (`null`
 * restores it). Drops the current sender and its access token.
 */
export function setFcmFetcher(fn: typeof fetch | null): void {
  fetcher = fn ?? defaultFetch;
  current = null;
}

/**
 * For tests: a service account key to use instead of
 * `env.FCM_SERVICE_ACCOUNT` (`null` goes back to the env). Drops the
 * current sender and its access token.
 */
export function setFcmServiceAccount(raw: string | null): void {
  serviceAccountOverride = raw;
  current = null;
}
