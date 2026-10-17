/**
 * A tiny path router: exact segments plus `:param` segments, then method.
 * Pure, so it's unit-tested in Node (test/unit/router.test.ts).
 */

export interface Route<H> {
  readonly method: string;
  /** e.g. `/v1/users/:username`. Matched segment by segment; no trailing slash. */
  readonly path: string;
  readonly handler: H;
}

export type Match<H> =
  | { readonly kind: "found"; readonly handler: H; readonly params: Readonly<Record<string, string>> }
  | { readonly kind: "method_not_allowed"; readonly allow: readonly string[] }
  | { readonly kind: "not_found" };

interface Compiled<H> {
  readonly route: Route<H>;
  readonly segments: readonly string[];
}

export class Router<H> {
  private readonly compiled: Compiled<H>[];

  constructor(routes: readonly Route<H>[]) {
    this.compiled = routes.map((route) => ({ route, segments: route.path.split("/") }));
  }

  match(method: string, pathname: string): Match<H> {
    const parts = pathname.split("/");
    const allow: string[] = [];
    for (const { route, segments } of this.compiled) {
      const params = matchSegments(segments, parts);
      if (params === null) continue;
      if (route.method === method) return { kind: "found", handler: route.handler, params };
      if (!allow.includes(route.method)) allow.push(route.method);
    }
    return allow.length > 0 ? { kind: "method_not_allowed", allow } : { kind: "not_found" };
  }
}

function matchSegments(pattern: readonly string[], parts: readonly string[]): Record<string, string> | null {
  if (pattern.length !== parts.length) return null;
  const params: Record<string, string> = Object.create(null) as Record<string, string>;
  for (let i = 0; i < pattern.length; i++) {
    const want = pattern[i]!;
    const got = parts[i]!;
    if (want.startsWith(":")) {
      if (got === "") return null;
      let decoded: string;
      try {
        decoded = decodeURIComponent(got);
      } catch {
        return null;
      }
      params[want.slice(1)] = decoded;
    } else if (want !== got) {
      return null;
    }
  }
  return params;
}
