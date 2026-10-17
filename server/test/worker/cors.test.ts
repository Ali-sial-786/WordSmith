import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const BASE = "https://api.test";
const PLAY = "https://play.wordsmith-forge.workers.dev";

function call(path: string, init: RequestInit = {}): Promise<Response> {
  return exports.default.fetch(new Request(BASE + path, init));
}

describe("CORS for the browser version", () => {
  it("answers a preflight from the game's origin", async () => {
    const res = await call("/v1/me", {
      method: "OPTIONS",
      headers: { Origin: PLAY, "Access-Control-Request-Method": "GET", "Access-Control-Request-Headers": "authorization" },
    });
    expect(res.status).toBe(204);
    expect(res.headers.get("access-control-allow-origin")).toBe(PLAY);
    expect(res.headers.get("access-control-allow-headers")).toMatch(/Authorization/);
    expect(res.headers.get("access-control-allow-methods")).toMatch(/POST/);
  });

  it("lets the game's origin read responses, errors included", async () => {
    const ok = await call("/v1/version", { headers: { Origin: PLAY } });
    expect(ok.status).toBe(200);
    expect(ok.headers.get("access-control-allow-origin")).toBe(PLAY);
    expect(ok.headers.get("vary")).toMatch(/Origin/);
    const unauthorized = await call("/v1/me", { headers: { Origin: PLAY } });
    expect(unauthorized.status).toBe(401);
    expect(unauthorized.headers.get("access-control-allow-origin")).toBe(PLAY);
  });

  it("allows local dev servers", async () => {
    const res = await call("/v1/version", { headers: { Origin: "http://localhost:5173" } });
    expect(res.headers.get("access-control-allow-origin")).toBe("http://localhost:5173");
  });

  it("gives other origins nothing", async () => {
    for (const origin of ["https://evil.example", "http://localhost.evil.example", "https://play.wordsmith-forge.workers.dev.evil"]) {
      const res = await call("/v1/version", { headers: { Origin: origin } });
      expect(res.status).toBe(200);
      expect(res.headers.get("access-control-allow-origin")).toBeNull();
      const pre = await call("/v1/version", { method: "OPTIONS", headers: { Origin: origin } });
      expect(pre.headers.get("access-control-allow-origin")).toBeNull();
    }
  });

  it("leaves the phone app's requests as they were", async () => {
    const res = await call("/v1/version");
    expect(res.headers.get("access-control-allow-origin")).toBeNull();
    expect(await res.json()).toMatchObject({ latest: expect.any(String) });
  });
});
