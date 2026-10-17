import { describe, expect, it } from "vitest";
import { liveKitConfig, liveKitToken, VIDEO_TOKEN_TTL_MS } from "../../src/video/livekit";

const config = { url: "wss://wordsmith-test.livekit.cloud", apiKey: "APIabc123", apiSecret: "s3cret-s3cret-s3cret-s3cret-s3cret" };

function decode(part: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(part, "base64url").toString("utf8")) as Record<string, unknown>;
}

describe("liveKitConfig", () => {
  it("needs all three settings", () => {
    expect(liveKitConfig({})).toBeNull();
    expect(liveKitConfig({ LIVEKIT_URL: config.url, LIVEKIT_API_KEY: config.apiKey })).toBeNull();
    expect(liveKitConfig({ LIVEKIT_URL: config.url, LIVEKIT_API_KEY: config.apiKey, LIVEKIT_API_SECRET: "  " })).toBeNull();
    expect(
      liveKitConfig({ LIVEKIT_URL: ` ${config.url}\n`, LIVEKIT_API_KEY: config.apiKey, LIVEKIT_API_SECRET: config.apiSecret }),
    ).toEqual(config);
  });
});

describe("liveKitToken", () => {
  it("lets one player into one room with camera and mic only", async () => {
    const now = Date.UTC(2026, 9, 17, 12, 0, 0);
    const token = await liveKitToken(config, { identity: "uid-1", name: "Ada", room: "wordsmith-K7Q2AB-x", now });
    const [header, payload, signature] = token.split(".");
    expect(decode(header!)).toEqual({ alg: "HS256", typ: "JWT" });
    expect(decode(payload!)).toEqual({
      iss: "APIabc123",
      sub: "uid-1",
      name: "Ada",
      nbf: now / 1000 - 10,
      exp: now / 1000 + VIDEO_TOKEN_TTL_MS / 1000,
      video: {
        room: "wordsmith-K7Q2AB-x",
        roomJoin: true,
        canPublish: true,
        canSubscribe: true,
        canPublishData: false,
        canPublishSources: ["camera", "microphone"],
        canUpdateOwnMetadata: false,
      },
    });

    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(config.apiSecret), { name: "HMAC", hash: "SHA-256" }, false, [
      "verify",
    ]);
    const valid = await crypto.subtle.verify(
      "HMAC",
      key,
      Buffer.from(signature!, "base64url"),
      new TextEncoder().encode(`${header}.${payload}`),
    );
    expect(valid).toBe(true);
  });
});
