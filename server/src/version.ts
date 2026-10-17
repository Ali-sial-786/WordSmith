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
}

/** Body of `GET /v1/version`. */
export function versionInfo(env: Env): VersionInfo {
  return {
    latest: env.LATEST_VERSION,
    minSupported: env.MIN_SUPPORTED_VERSION,
    protocol: PROTOCOL_VERSION,
  };
}
