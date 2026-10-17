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
  /** Where the Android app downloads `latest` to update itself; null when not set up. */
  apk: string | null;
}

/** Body of `GET /v1/version`. */
export function versionInfo(env: Env): VersionInfo {
  return {
    latest: env.LATEST_VERSION,
    minSupported: env.MIN_SUPPORTED_VERSION,
    protocol: PROTOCOL_VERSION,
    apk: env.APK_URL ? env.APK_URL.replaceAll("{version}", env.LATEST_VERSION) : null,
  };
}
