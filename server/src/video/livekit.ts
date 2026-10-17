/**
 * LiveKit access tokens for in-room video chat (docs/TECH.md §6b).
 *
 * A token is a JWT signed with the LiveKit project's API secret (HS256). It
 * lets one player (`sub` = their user ID) join one LiveKit room, publishing
 * only their camera and microphone. The server never touches media; the app
 * talks to LiveKit Cloud directly with this token.
 */

/** The LiveKit project, from Worker secrets. */
export interface LiveKitConfig {
  /** `wss://<project>.livekit.cloud` */
  readonly url: string;
  readonly apiKey: string;
  readonly apiSecret: string;
}

export interface LiveKitEnv {
  LIVEKIT_URL?: string;
  LIVEKIT_API_KEY?: string;
  LIVEKIT_API_SECRET?: string;
}

/** The project settings, or `null` while video chat isn't set up. */
export function liveKitConfig(env: LiveKitEnv): LiveKitConfig | null {
  const url = env.LIVEKIT_URL?.trim() ?? "";
  const apiKey = env.LIVEKIT_API_KEY?.trim() ?? "";
  const apiSecret = env.LIVEKIT_API_SECRET?.trim() ?? "";
  if (url === "" || apiKey === "" || apiSecret === "") return null;
  return { url, apiKey, apiSecret };
}

/** How long a token can be used to join. Once connected, LiveKit refreshes it itself. */
export const VIDEO_TOKEN_TTL_MS = 2 * 3600_000;

export interface TokenRequest {
  /** The player's user ID. */
  readonly identity: string;
  /** Shown to other participants. */
  readonly name: string;
  /** The LiveKit room. */
  readonly room: string;
  readonly now?: number;
  readonly ttlMs?: number;
}

const utf8 = new TextEncoder();

function base64Url(bytes: Uint8Array | string): string {
  const raw = typeof bytes === "string" ? utf8.encode(bytes) : bytes;
  let binary = "";
  for (const b of raw) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The claims LiveKit reads: who, which room, and what they may do there. */
export function tokenClaims(config: LiveKitConfig, req: TokenRequest): Record<string, unknown> {
  const now = Math.floor((req.now ?? Date.now()) / 1000);
  return {
    iss: config.apiKey,
    sub: req.identity,
    name: req.name,
    nbf: now - 10,
    exp: now + Math.floor((req.ttlMs ?? VIDEO_TOKEN_TTL_MS) / 1000),
    video: {
      room: req.room,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: false,
      canPublishSources: ["camera", "microphone"],
      canUpdateOwnMetadata: false,
    },
  };
}

export async function liveKitToken(config: LiveKitConfig, req: TokenRequest): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const signingInput = `${base64Url(JSON.stringify(header))}.${base64Url(JSON.stringify(tokenClaims(config, req)))}`;
  const key = await crypto.subtle.importKey("raw", utf8.encode(config.apiSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, utf8.encode(signingInput));
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}
