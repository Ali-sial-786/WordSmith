/**
 * Wordsmith API Worker: the router for the REST routes in docs/TECH.md §4.
 */

import type { Env } from "./env";
import { versionInfo } from "./version";

type Handler = (request: Request, env: Env, ctx: ExecutionContext) => Response | Promise<Response>;

/** Routes by exact path, then by method. */
const routes = new Map<string, Map<string, Handler>>([
  ["/v1/version", new Map([["GET", (_req, env) => json(versionInfo(env))]])],
  ["/v1/health", new Map([["GET", () => json({ ok: true })]])],
]);

function json(body: unknown, status = 200, headers?: HeadersInit): Response {
  return Response.json(body, { status, headers });
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const { pathname } = new URL(request.url);
    const byMethod = routes.get(pathname);
    if (byMethod === undefined) return json({ error: "not_found" }, 404);

    const handler = byMethod.get(request.method);
    if (handler === undefined) {
      return json({ error: "method_not_allowed" }, 405, { Allow: [...byMethod.keys()].join(", ") });
    }

    try {
      return await handler(request, env, ctx);
    } catch (err) {
      console.error(`${request.method} ${pathname} failed`, err);
      return json({ error: "internal" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;
