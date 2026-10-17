/**
 * Firebase ID token verification with WebCrypto, without the Admin SDK
 * (docs/TECH.md §3).
 *
 * A token is accepted only if:
 * - it is a three-part JWT whose header says `alg: RS256` and names a `kid`;
 * - that `kid` is one of Google's current `securetoken` signing keys, and the
 *   RS256 signature checks out against it;
 * - `aud` is our Firebase project ID and `iss` is
 *   `https://securetoken.google.com/<project-id>`;
 * - `exp` is in the future and `iat` and `auth_time` are not, allowing
 *   {@link CLOCK_SKEW_SECONDS} either way;
 * - `sub` (the Firebase uid, our user ID) is a non-empty string of at most 128 characters.
 *
 * Google's keys are cached per isolate for as long as their `Cache-Control:
 * max-age` says. Tests swap the key source with {@link setJwksFetcher}.
 */

export const GOOGLE_JWKS_URL =
  "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";

/** Leeway for clocks that disagree a little. */
export const CLOCK_SKEW_SECONDS = 60;

/** Firebase uids are at most 128 characters. */
export const MAX_UID_LENGTH = 128;

/** Tokens longer than this aren't Firebase ID tokens (they're about 1 KB). */
export const MAX_TOKEN_LENGTH = 8192;

/** Key-set lifetime when Google's response has no usable `max-age`. */
export const DEFAULT_JWKS_MAX_AGE_SECONDS = 3600;

/** Shortest key-set lifetime we honour, so a `max-age=0` can't cause a fetch per request. */
export const MIN_JWKS_MAX_AGE_SECONDS = 60;

/**
 * Least time between key-set fetches when one fails or a token names an
 * unknown `kid`, so garbage tokens can't make us hammer Google.
 */
export const MIN_REFETCH_INTERVAL_MS = 30_000;

export type TokenErrorReason =
  | "malformed"
  | "bad_alg"
  | "unknown_kid"
  | "bad_signature"
  | "expired"
  | "issued_in_future"
  | "bad_audience"
  | "bad_issuer"
  | "bad_subject"
  | "bad_auth_time"
  | "keys_unavailable";

export class TokenError extends Error {
  constructor(readonly reason: TokenErrorReason) {
    super(`Firebase ID token rejected: ${reason}`);
    this.name = "TokenError";
  }
}

/** The parts of a verified token the server uses. */
export interface FirebaseIdentity {
  /** Firebase uid; our user ID. */
  readonly uid: string;
  readonly email: string | null;
  /** Epoch seconds. */
  readonly authTime: number;
  readonly issuedAt: number;
  readonly expiresAt: number;
}

// ---------------------------------------------------------------------------
// Key set
// ---------------------------------------------------------------------------

/** One entry of a JWK set (RFC 7517). Only RSA keys are used. */
export interface Jwk {
  readonly kty?: string;
  readonly kid?: string;
  readonly alg?: string;
  readonly use?: string;
  readonly n?: string;
  readonly e?: string;
}

export interface JwksResult {
  readonly keys: readonly Jwk[];
  /** From the response's `Cache-Control: max-age`, or `null` if it had none. */
  readonly maxAgeSeconds: number | null;
}

export type JwksFetcher = () => Promise<JwksResult>;

/** Looks up the verification key for a `kid`; `null` if there's no such key. */
export type KeyLookup = (kid: string) => Promise<CryptoKey | null>;

/** `max-age` from a Cache-Control header, in seconds, or `null`. */
export function parseMaxAge(cacheControl: string | null): number | null {
  if (cacheControl === null) return null;
  const match = /(?:^|[,\s])max-age\s*=\s*"?(\d+)"?/i.exec(cacheControl);
  if (match === null) return null;
  const seconds = Number(match[1]);
  return Number.isSafeInteger(seconds) ? seconds : null;
}

/** Fetches Google's `securetoken` JWK set. */
export async function fetchGoogleJwks(fetchFn: typeof fetch = fetch): Promise<JwksResult> {
  const res = await fetchFn(GOOGLE_JWKS_URL, { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`JWKS fetch failed: HTTP ${res.status}`);
  const body: unknown = await res.json();
  const keys = (body as { keys?: unknown } | null)?.keys;
  if (!Array.isArray(keys)) throw new Error("JWKS response has no keys array");
  return { keys: keys as Jwk[], maxAgeSeconds: parseMaxAge(res.headers.get("cache-control")) };
}

const RS256_IMPORT = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };

async function importRsaKey(jwk: Jwk): Promise<CryptoKey | null> {
  if (jwk.kty !== "RSA" || typeof jwk.n !== "string" || typeof jwk.e !== "string") return null;
  if (jwk.alg !== undefined && jwk.alg !== "RS256") return null;
  if (jwk.use !== undefined && jwk.use !== "sig") return null;
  try {
    return await crypto.subtle.importKey("jwk", { kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS256", ext: true }, RS256_IMPORT, false, [
      "verify",
    ]);
  } catch {
    return null;
  }
}

/**
 * Google's signing keys, imported once and kept until their `max-age` runs
 * out. A token with an unknown `kid` triggers an early refresh (Google may
 * have rotated), at most once per {@link MIN_REFETCH_INTERVAL_MS}. If a
 * refresh fails, the old keys keep being used until one succeeds.
 */
export class JwksCache {
  private keys = new Map<string, CryptoKey>();
  private expiresAt = 0;
  private lastAttempt = Number.NEGATIVE_INFINITY;
  private inflight: Promise<void> | null = null;

  constructor(
    private readonly fetchJwks: JwksFetcher,
    private readonly clock: () => number = Date.now,
  ) {}

  /** Number of times the key set has been fetched (for tests). */
  fetchCount = 0;

  readonly lookup: KeyLookup = async (kid) => {
    const now = this.clock();
    const stale = now >= this.expiresAt;
    const unknown = !this.keys.has(kid);
    if (this.inflight !== null) {
      // Someone else is already fetching; wait for that instead of a second fetch.
      await this.inflight;
    } else if ((stale || unknown) && now - this.lastAttempt >= MIN_REFETCH_INTERVAL_MS) {
      await this.refresh();
    }
    if (this.keys.size === 0) throw new TokenError("keys_unavailable");
    return this.keys.get(kid) ?? null;
  };

  /** Starts a fetch (or joins the one in flight). Never rejects; failures keep the old keys. */
  private refresh(): Promise<void> {
    this.inflight ??= this.doRefresh()
      .catch((err: unknown) => {
        console.warn("Firebase key refresh failed", err);
      })
      .finally(() => {
        this.inflight = null;
      });
    return this.inflight;
  }

  private async doRefresh(): Promise<void> {
    this.lastAttempt = this.clock();
    this.fetchCount++;
    const { keys, maxAgeSeconds } = await this.fetchJwks();
    const next = new Map<string, CryptoKey>();
    for (const jwk of keys) {
      if (typeof jwk.kid !== "string" || jwk.kid === "") continue;
      const key = await importRsaKey(jwk);
      if (key !== null) next.set(jwk.kid, key);
    }
    if (next.size === 0) throw new Error("JWKS response has no usable RS256 keys");
    const maxAge = Math.max(maxAgeSeconds ?? DEFAULT_JWKS_MAX_AGE_SECONDS, MIN_JWKS_MAX_AGE_SECONDS);
    this.keys = next;
    this.expiresAt = this.clock() + maxAge * 1000;
  }
}

let defaultCache = new JwksCache(() => fetchGoogleJwks());

/**
 * Replaces where the default key set comes from, with a fresh cache.
 * For tests, which sign tokens with their own key pair. `null` restores
 * Google's endpoint.
 */
export function setJwksFetcher(fetcher: JwksFetcher | null): JwksCache {
  defaultCache = new JwksCache(fetcher ?? (() => fetchGoogleJwks()));
  return defaultCache;
}

// ---------------------------------------------------------------------------
// Verification
// ---------------------------------------------------------------------------

export interface VerifyOptions {
  readonly projectId: string;
  /** Defaults to the per-isolate cache of Google's keys. */
  readonly keys?: KeyLookup;
  /** Current time in epoch seconds; defaults to the clock. */
  readonly nowSeconds?: number;
}

const BASE64URL = /^[A-Za-z0-9_-]+$/;
const utf8 = new TextEncoder();
const utf8Decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });

function base64UrlDecode(segment: string): Uint8Array<ArrayBuffer> {
  const base64 = segment.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function decodeJsonSegment(segment: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(utf8Decoder.decode(base64UrlDecode(segment)));
  } catch {
    throw new TokenError("malformed");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new TokenError("malformed");
  return value as Record<string, unknown>;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

/**
 * Verifies a Firebase ID token and returns who it belongs to.
 * Throws {@link TokenError} if it isn't valid.
 */
export async function verifyFirebaseToken(token: string, options: VerifyOptions): Promise<FirebaseIdentity> {
  if (typeof token !== "string" || token.length === 0 || token.length > MAX_TOKEN_LENGTH) {
    throw new TokenError("malformed");
  }
  const parts = token.split(".");
  if (parts.length !== 3 || !parts.every((p) => BASE64URL.test(p))) throw new TokenError("malformed");
  const [headerPart, payloadPart, signaturePart] = parts as [string, string, string];

  const header = decodeJsonSegment(headerPart);
  if (header.alg !== "RS256") throw new TokenError("bad_alg");
  const kid = header.kid;
  if (typeof kid !== "string" || kid === "") throw new TokenError("unknown_kid");
  const payload = decodeJsonSegment(payloadPart);

  const key = await (options.keys ?? defaultCache.lookup)(kid);
  if (key === null) throw new TokenError("unknown_kid");
  const signature = base64UrlDecode(signaturePart);
  const signed = utf8.encode(`${headerPart}.${payloadPart}`);
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed);
  if (!valid) throw new TokenError("bad_signature");

  const now = options.nowSeconds ?? Math.floor(Date.now() / 1000);
  const { exp, iat, aud, iss, sub } = payload;
  const authTime = payload.auth_time;
  if (!isFiniteNumber(exp) || now >= exp + CLOCK_SKEW_SECONDS) throw new TokenError("expired");
  if (!isFiniteNumber(iat) || iat > now + CLOCK_SKEW_SECONDS) throw new TokenError("issued_in_future");
  if (aud !== options.projectId) throw new TokenError("bad_audience");
  if (iss !== `https://securetoken.google.com/${options.projectId}`) throw new TokenError("bad_issuer");
  if (typeof sub !== "string" || sub.length === 0 || sub.length > MAX_UID_LENGTH) throw new TokenError("bad_subject");
  if (!isFiniteNumber(authTime) || authTime > now + CLOCK_SKEW_SECONDS) throw new TokenError("bad_auth_time");

  return {
    uid: sub,
    email: typeof payload.email === "string" ? payload.email : null,
    authTime,
    issuedAt: iat,
    expiresAt: exp,
  };
}
