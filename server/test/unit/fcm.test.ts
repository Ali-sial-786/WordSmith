import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { isPushToken, MAX_PUSH_TOKEN_LENGTH } from "../../src/db/push";
import {
  ACCESS_TOKEN_MARGIN_MS,
  FCM_SCOPE,
  fcmSender,
  fcmSendUrl,
  FcmSender,
  GOOGLE_TOKEN_URL,
  importPrivateKey,
  parseServiceAccount,
  sendOutcome,
  setFcmFetcher,
  setFcmServiceAccount,
  signAssertion,
  type ServiceAccount,
} from "../../src/push/fcm";
import { inviteMessage } from "../../src/push/invite";

const RS256 = { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" };

function toPem(der: ArrayBuffer): string {
  const lines = Buffer.from(der).toString("base64").match(/.{1,64}/g)!;
  return `-----BEGIN PRIVATE KEY-----\n${lines.join("\n")}\n-----END PRIVATE KEY-----\n`;
}

function decode(part: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(part, "base64url").toString("utf8")) as Record<string, unknown>;
}

let publicKey: CryptoKey;
let pem: string;
let keyJson: Record<string, string>;

beforeAll(async () => {
  const pair = (await crypto.subtle.generateKey(
    { ...RS256, modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]) },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  publicKey = pair.publicKey;
  pem = toPem((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  // The shape of a key file from Firebase console → Service accounts.
  keyJson = {
    type: "service_account",
    project_id: "wordsmith-test",
    private_key_id: "0123abcd",
    private_key: pem,
    client_email: "firebase-adminsdk-x@wordsmith-test.iam.gserviceaccount.com",
    client_id: "1234567890",
    token_uri: "https://oauth2.googleapis.com/token",
  };
});

afterEach(() => {
  vi.restoreAllMocks();
  setFcmFetcher(null);
  setFcmServiceAccount(null);
});

async function verifyJwt(jwt: string): Promise<boolean> {
  const [header, payload, signature] = jwt.split(".");
  return crypto.subtle.verify(RS256, publicKey, Buffer.from(signature!, "base64url"), new TextEncoder().encode(`${header}.${payload}`));
}

describe("parseServiceAccount", () => {
  it("reads a service account key file", () => {
    expect(parseServiceAccount(JSON.stringify(keyJson))).toEqual({
      clientEmail: keyJson.client_email,
      privateKey: pem,
      projectId: "wordsmith-test",
      privateKeyId: "0123abcd",
    });
    const { private_key_id: _, ...withoutKid } = keyJson;
    expect(parseServiceAccount(JSON.stringify(withoutKid))?.privateKeyId).toBeNull();
  });

  it("is null when the secret is missing or malformed", () => {
    const without = (field: string) => JSON.stringify({ ...keyJson, [field]: undefined });
    for (const raw of [
      undefined,
      null,
      "",
      "  ",
      "{not json",
      "[]",
      '"a string"',
      without("client_email"),
      without("private_key"),
      without("project_id"),
      JSON.stringify({ ...keyJson, project_id: " " }),
      JSON.stringify({ ...keyJson, client_email: 42 }),
      JSON.stringify({ ...keyJson, private_key: "not a key" }),
      JSON.stringify({ ...keyJson, private_key: "-----BEGIN PRIVATE KEY-----\n!!!\n-----END PRIVATE KEY-----" }),
      JSON.stringify({ ...keyJson, private_key: pem.replace("PRIVATE KEY", "RSA PRIVATE KEY") }),
    ]) {
      expect(parseServiceAccount(raw), String(raw)).toBeNull();
    }
  });
});

describe("the OAuth assertion", () => {
  it("is an RS256 JWT for the FCM scope, signed with the PKCS#8 key", async () => {
    const account = parseServiceAccount(JSON.stringify(keyJson))!;
    const key = await importPrivateKey(account.privateKey);
    const now = 1_792_200_000;
    const jwt = await signAssertion(account, key, now);
    const [header, payload] = jwt.split(".");
    expect(decode(header!)).toEqual({ alg: "RS256", typ: "JWT", kid: "0123abcd" });
    expect(decode(payload!)).toEqual({
      iss: keyJson.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    });
    expect(await verifyJwt(jwt)).toBe(true);
    // A different signing input doesn't verify.
    expect(await verifyJwt(jwt.replace(/\.[^.]+\./, `.${Buffer.from("{}").toString("base64url")}.`))).toBe(false);
  });

  it("leaves out kid without a private_key_id, and copes with escaped newlines", async () => {
    const account: ServiceAccount = {
      ...parseServiceAccount(JSON.stringify(keyJson))!,
      privateKey: pem.replace(/\n/g, "\\n"),
      privateKeyId: null,
    };
    const jwt = await signAssertion(account, await importPrivateKey(account.privateKey), 1000);
    expect(decode(jwt.split(".")[0]!)).toEqual({ alg: "RS256", typ: "JWT" });
    expect(await verifyJwt(jwt)).toBe(true);
  });

  it("refuses a key that isn't PKCS#8", async () => {
    await expect(importPrivateKey("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----")).rejects.toThrow();
    await expect(importPrivateKey("nope")).rejects.toThrow();
  });
});

describe("inviteMessage", () => {
  it("follows shared/push.md", () => {
    expect(inviteMessage("tok-1", { from: "uid-ali", fromUsername: "Ali", code: "K7Q2AB", mode: "vs" })).toEqual({
      token: "tok-1",
      notification: { title: "Ali invited you to Versus", body: "Tap to join room K7Q2AB" },
      data: { type: "invite", code: "K7Q2AB", mode: "vs", from: "uid-ali" },
      android: { priority: "high", ttl: "300s", collapse_key: "invite-K7Q2AB" },
    });
    expect(inviteMessage("tok-2", { from: "uid-sam", fromUsername: "Sam_9", code: "ZZ22QQ", mode: "coop" })).toMatchObject({
      notification: { title: "Sam_9 invited you to Co-op", body: "Tap to join room ZZ22QQ" },
      data: { type: "invite", code: "ZZ22QQ", mode: "coop", from: "uid-sam" },
      android: { collapse_key: "invite-ZZ22QQ" },
    });
  });
});

/** An FCM v1 error body. */
function fcmError(code: number, status: string, message: string, details: unknown[] = []) {
  return { error: { code, message, status, details } };
}
const fcmCode = (errorCode: string) => ({ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode });
const badField = (field: string) => ({
  "@type": "type.googleapis.com/google.rpc.BadRequest",
  fieldViolations: [{ field, description: "Invalid value" }],
});

describe("sendOutcome (which tokens to forget)", () => {
  it.each([
    ["a success", 200, { name: "projects/p/messages/1" }, "sent"],
    ["404 UNREGISTERED", 404, fcmError(404, "NOT_FOUND", "Requested entity was not found.", [fcmCode("UNREGISTERED")]), "drop_token"],
    ["a bare 404", 404, "Not Found", "drop_token"],
    [
      "400 about a bad token",
      400,
      fcmError(400, "INVALID_ARGUMENT", "The registration token is not a valid FCM registration token", [fcmCode("INVALID_ARGUMENT")]),
      "drop_token",
    ],
    [
      "400 naming message.token",
      400,
      fcmError(400, "INVALID_ARGUMENT", "Request contains an invalid argument.", [fcmCode("INVALID_ARGUMENT"), badField("message.token")]),
      "drop_token",
    ],
    [
      "400 about the rest of the message",
      400,
      fcmError(400, "INVALID_ARGUMENT", "Invalid value at 'message.android.ttl'", [fcmCode("INVALID_ARGUMENT"), badField("message.android.ttl")]),
      "failed",
    ],
    ["400 that isn't JSON", 400, "Bad Request", "failed"],
    ["401 (our access token)", 401, fcmError(401, "UNAUTHENTICATED", "Request had invalid authentication credentials."), "failed"],
    ["403 SENDER_ID_MISMATCH", 403, fcmError(403, "PERMISSION_DENIED", "SenderId mismatch", [fcmCode("SENDER_ID_MISMATCH")]), "failed"],
    ["429 QUOTA_EXCEEDED", 429, fcmError(429, "RESOURCE_EXHAUSTED", "Quota exceeded", [fcmCode("QUOTA_EXCEEDED")]), "failed"],
    ["500", 500, fcmError(500, "INTERNAL", "Internal error", [fcmCode("INTERNAL")]), "failed"],
    ["503", 503, fcmError(503, "UNAVAILABLE", "Unavailable", [fcmCode("UNAVAILABLE")]), "failed"],
  ] as const)("%s → %s", (_, status, body, outcome) => {
    expect(sendOutcome(status, body)).toBe(outcome);
  });
});

interface Seen {
  readonly url: string;
  readonly headers: Headers;
  readonly body: string;
}

/** A stand-in for Google: the OAuth endpoint and FCM, recording every request. */
function fakeGoogle(sendStatus: (token: string) => { status: number; body: unknown } = () => ({ status: 200, body: { name: "m/1" } })) {
  const seen: Seen[] = [];
  let tokenStatus = 200;
  let issued = 0;
  const fetchFn: typeof fetch = async (input, init) => {
    const req = new Request(input, init);
    const body = await req.text();
    seen.push({ url: req.url, headers: req.headers, body });
    if (req.url === GOOGLE_TOKEN_URL) {
      if (tokenStatus !== 200) return Response.json({ error: "invalid_grant", error_description: "Invalid JWT" }, { status: tokenStatus });
      return Response.json({ access_token: `access-${++issued}`, expires_in: 3599, token_type: "Bearer" });
    }
    const { message } = JSON.parse(body) as { message: { token: string } };
    const res = sendStatus(message.token);
    return Response.json(res.body, { status: res.status });
  };
  return {
    fetch: fetchFn,
    seen,
    oauth: () => seen.filter((s) => s.url === GOOGLE_TOKEN_URL),
    sends: () => seen.filter((s) => s.url !== GOOGLE_TOKEN_URL),
    failTokens(status: number) {
      tokenStatus = status;
    },
  };
}

describe("FcmSender", () => {
  const message = (token: string) => inviteMessage(token, { from: "u1", fromUsername: "Ali", code: "K7Q2AB", mode: "vs" });

  it("trades a signed assertion for an access token, then sends the message", async () => {
    const google = fakeGoogle();
    const sender = new FcmSender(parseServiceAccount(JSON.stringify(keyJson))!, { fetch: google.fetch, clock: () => 1_792_200_000_000 });
    expect(await sender.send(message("tok-1"))).toBe("sent");

    const [oauth] = google.oauth();
    expect(oauth!.headers.get("content-type")).toBe("application/x-www-form-urlencoded");
    const form = new URLSearchParams(oauth!.body);
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    const assertion = form.get("assertion")!;
    expect(await verifyJwt(assertion)).toBe(true);
    expect(decode(assertion.split(".")[1]!)).toMatchObject({ iss: keyJson.client_email, scope: FCM_SCOPE, aud: GOOGLE_TOKEN_URL, iat: 1_792_200_000 });

    const [send] = google.sends();
    expect(send!.url).toBe("https://fcm.googleapis.com/v1/projects/wordsmith-test/messages:send");
    expect(send!.url).toBe(fcmSendUrl("wordsmith-test"));
    expect(send!.headers.get("authorization")).toBe("Bearer access-1");
    expect(send!.headers.get("content-type")).toBe("application/json");
    expect(JSON.parse(send!.body)).toEqual({ message: message("tok-1") });
  });

  it("keeps the access token until 5 minutes before it expires", async () => {
    const google = fakeGoogle();
    let now = 1_000_000;
    const sender = new FcmSender(parseServiceAccount(JSON.stringify(keyJson))!, { fetch: google.fetch, clock: () => now });
    expect(await sender.accessToken()).toBe("access-1");
    const expiresAt = 1_000_000 + 3599 * 1000;
    now = expiresAt - ACCESS_TOKEN_MARGIN_MS - 1;
    expect(await sender.accessToken()).toBe("access-1");
    await sender.send(message("tok-1"));
    expect(google.oauth()).toHaveLength(1);
    now = expiresAt - ACCESS_TOKEN_MARGIN_MS;
    expect(await sender.accessToken()).toBe("access-2");
    expect(google.oauth()).toHaveLength(2);
  });

  it("fetches one access token for sends that start together", async () => {
    const google = fakeGoogle();
    const sender = new FcmSender(parseServiceAccount(JSON.stringify(keyJson))!, { fetch: google.fetch });
    expect(await Promise.all(["a", "b", "c"].map((t) => sender.send(message(t))))).toEqual(["sent", "sent", "sent"]);
    expect(google.oauth()).toHaveLength(1);
    expect(google.sends().map((s) => s.headers.get("authorization"))).toEqual(["Bearer access-1", "Bearer access-1", "Bearer access-1"]);
  });

  it("reports failures without throwing, and tries again next time", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const google = fakeGoogle((token) =>
      token === "gone"
        ? { status: 404, body: fcmError(404, "NOT_FOUND", "Requested entity was not found.", [fcmCode("UNREGISTERED")]) }
        : token === "stale-auth"
          ? { status: 401, body: fcmError(401, "UNAUTHENTICATED", "Request had invalid authentication credentials.") }
          : { status: 200, body: {} },
    );
    const sender = new FcmSender(parseServiceAccount(JSON.stringify(keyJson))!, { fetch: google.fetch });

    google.failTokens(400);
    expect(await sender.send(message("ok"))).toBe("failed");
    expect(google.sends()).toHaveLength(0);
    expect(warn).toHaveBeenCalled();

    google.failTokens(200);
    expect(await sender.send(message("ok"))).toBe("sent");
    expect(await sender.send(message("gone"))).toBe("drop_token");
    expect(google.oauth()).toHaveLength(2);

    // A refused access token is dropped, so the next send gets a new one.
    expect(await sender.send(message("stale-auth"))).toBe("failed");
    expect(await sender.send(message("ok"))).toBe("sent");
    expect(google.oauth()).toHaveLength(3);
    expect(google.sends().at(-1)!.headers.get("authorization")).toBe("Bearer access-2");

    // A network failure is a failure too.
    const broken = new FcmSender(parseServiceAccount(JSON.stringify(keyJson))!, {
      fetch: async () => {
        throw new Error("network down");
      },
    });
    expect(await broken.send(message("ok"))).toBe("failed");
  });
});

describe("fcmSender", () => {
  it("is null until FCM_SERVICE_ACCOUNT holds a usable key", () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(fcmSender({})).toBeNull();
    expect(fcmSender({ FCM_SERVICE_ACCOUNT: "" })).toBeNull();
    expect(fcmSender({ FCM_SERVICE_ACCOUNT: "{oops" })).toBeNull();
    expect(fcmSender({ FCM_SERVICE_ACCOUNT: JSON.stringify({ ...keyJson, private_key: "x" }) })).toBeNull();
    const sender = fcmSender({ FCM_SERVICE_ACCOUNT: JSON.stringify(keyJson) });
    expect(sender?.account.projectId).toBe("wordsmith-test");
    // One per isolate, so the access token is shared.
    expect(fcmSender({ FCM_SERVICE_ACCOUNT: JSON.stringify(keyJson) })).toBe(sender);
  });

  it("can be pointed elsewhere by tests", async () => {
    const google = fakeGoogle();
    setFcmFetcher(google.fetch);
    setFcmServiceAccount(JSON.stringify({ ...keyJson, project_id: "other-project" }));
    const sender = fcmSender({})!;
    expect(sender.account.projectId).toBe("other-project");
    expect(await sender.send(inviteMessage("t", { from: "u", fromUsername: "A_b", code: "ABC234", mode: "coop" }))).toBe("sent");
    expect(google.sends()[0]!.url).toBe(fcmSendUrl("other-project"));

    setFcmServiceAccount(null);
    expect(fcmSender({})).toBeNull();
  });
});

describe("isPushToken", () => {
  it("takes a non-empty, printable token of a sane length", () => {
    const real = "cY3j1mQ9RkOa7b-xYz_0:APA91bH" + "a".repeat(130);
    expect(isPushToken(real)).toBe(true);
    expect(isPushToken("x".repeat(MAX_PUSH_TOKEN_LENGTH))).toBe(true);
    for (const bad of ["", " ", "has space", "tab\there", "line\nbreak", "émile", "x".repeat(MAX_PUSH_TOKEN_LENGTH + 1), 42, null, undefined, {}]) {
      expect(isPushToken(bad), JSON.stringify(bad)).toBe(false);
    }
  });
});
