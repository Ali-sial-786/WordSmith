import type { Env } from "./env";

/**
 * Real-time protocol version. Rooms refuse clients on a different major
 * version (docs/TECH.md §13).
 */
export const PROTOCOL_VERSION = 1;

export interface VersionInfo {
  latest: string;
  minSupported: string;
  protocol: number;
  /**
   * Where the Android app downloads `latest` to update itself: this server's
   * `/v1/apk/<latest>` (src/routes/apk.ts); null when there's no APK source.
   */
  apk: string | null;
  /**
   * Whether this request comes from Quebec (src/region.ts): the app then
   * starts every room with the microphone muted, Quebec's privacy law asking
   * for the most private settings by default (shared/age.md).
   */
  quebec: boolean;
}

/** Body of `GET /v1/version`; `origin` is this server's, as the request reached it. */
export function versionInfo(
  env: Pick<Env, "LATEST_VERSION" | "MIN_SUPPORTED_VERSION" | "APK_SOURCE_URL">,
  origin: string,
  quebec = false,
): VersionInfo {
  return {
    latest: env.LATEST_VERSION,
    minSupported: env.MIN_SUPPORTED_VERSION,
    protocol: PROTOCOL_VERSION,
    apk: env.APK_SOURCE_URL ? `${origin}/v1/apk/${env.LATEST_VERSION}` : null,
    quebec,
  };
}
