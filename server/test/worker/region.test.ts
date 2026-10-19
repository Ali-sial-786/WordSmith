/**
 * Online play isn't offered in Quebec (shared/region.md): routes that need a
 * token refuse requests from there, unless the player has said they live
 * elsewhere, and still let them delete their account.
 */

import { createExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../../src/index";
import { NOT_IN_QUEBEC_HEADER } from "../../src/region";
import { BASE, body, client, setUpClient, uniqueName, type Client } from "./helpers";

const QUEBEC = { country: "CA", regionCode: "QC" };
const ONTARIO = { country: "CA", regionCode: "ON" };
const NEW_YORK = { country: "US", regionCode: "NY" };

interface Where {
  readonly country: string;
  readonly regionCode: string;
}

/** A request as Cloudflare delivers it from `where`, with `headers` added. */
function from(
  where: Where,
  method: string,
  path: string,
  c: Client | null,
  payload?: unknown,
  headers: Record<string, string> = {},
): Promise<Response> {
  const init: RequestInit<IncomingRequestCfProperties> = {
    method,
    headers: {
      ...(c === null ? {} : { authorization: `Bearer ${c.token}` }),
      ...(payload === undefined ? {} : { "content-type": "application/json" }),
      ...headers,
    },
    cf: where as IncomingRequestCfProperties,
    ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
  };
  return worker.fetch(new Request(`${BASE}${path}`, init), env, createExecutionContext());
}

const notInQuebec = { [NOT_IN_QUEBEC_HEADER]: "1" };
const userRow = (uid: string) => env.DB.prepare("SELECT id FROM users WHERE id = ?1").bind(uid).first();
const adult = { birthYear: new Date().getUTCFullYear() - 30, birthMonth: 1 };

describe("online play from Quebec", () => {
  it("is refused before an account is made", async () => {
    const c = await client();
    const res = await from(QUEBEC, "GET", "/v1/me", c);
    expect(res.status).toBe(403);
    expect(await body(res)).toMatchObject({ error: "quebec_not_offered", message: "Online play isn't offered in Quebec" });
    expect(await userRow(c.uid)).toBeNull();

    const setup = await from(QUEBEC, "POST", "/v1/me/setup", c, { username: uniqueName(), avatar: "avatar_01", ...adult });
    expect(await body(setup)).toMatchObject({ error: "quebec_not_offered" });
    expect(await userRow(c.uid)).toBeNull();
  });

  it("is refused for an existing account, which is kept", async () => {
    const c = await setUpClient();
    for (const [method, path] of [
      ["GET", "/v1/me"],
      ["GET", "/v1/friends"],
      ["GET", "/v1/daily"],
      ["POST", "/v1/rooms"],
    ] as const) {
      const res = await from(QUEBEC, method, path, c, method === "POST" ? {} : undefined);
      expect(res.status, `${method} ${path}`).toBe(403);
      expect(await body(res)).toMatchObject({ error: "quebec_not_offered" });
    }
    expect(await userRow(c.uid)).not.toBeNull();
  });

  it("still lets a player delete their account or turn off notifications", async () => {
    const c = await setUpClient();
    const off = await from(QUEBEC, "DELETE", "/v1/me/push-token", c, { token: "fcm-token-for-a-test-phone-0123456789" });
    expect(off.status).toBe(200);
    const res = await from(QUEBEC, "DELETE", "/v1/me", c);
    expect(res.status).toBe(200);
    expect(await userRow(c.uid)).toBeNull();
  });

  it("is open once the player says they don't live in Quebec", async () => {
    const c = await client();
    const res = await from(QUEBEC, "POST", "/v1/me/setup", c, { username: uniqueName(), avatar: "avatar_01", ...adult }, notInQuebec);
    expect(res.status).toBe(200);
    expect((await from(QUEBEC, "GET", "/v1/me", c, undefined, notInQuebec)).status).toBe(200);
    // The header has one meaning; anything else is no answer.
    const unclear = await from(QUEBEC, "GET", "/v1/me", c, undefined, { [NOT_IN_QUEBEC_HEADER]: "true" });
    expect(unclear.status).toBe(403);
  });

  it("leaves the rest of Canada and the US alone", async () => {
    for (const where of [ONTARIO, NEW_YORK]) {
      const c = await client();
      expect((await from(where, "GET", "/v1/me", c)).status).toBe(200);
    }
  });

  it("checks Quebec before the token, so nothing from there is read", async () => {
    const res = await from(QUEBEC, "GET", "/v1/me", null);
    expect(await body(res)).toMatchObject({ error: "quebec_not_offered" });
  });

  it("keeps the routes that need no account open", async () => {
    expect((await from(QUEBEC, "GET", "/v1/health", null)).status).toBe(200);
    const version = await from(QUEBEC, "GET", "/v1/version", null);
    expect(await body(version)).toMatchObject({ quebec: true });
    expect(await body(await from(ONTARIO, "GET", "/v1/version", null))).toMatchObject({ quebec: false });
  });

  it("lets the browser version send the header", async () => {
    const res = await from(QUEBEC, "OPTIONS", "/v1/me", null, undefined, {
      origin: "http://localhost:8080",
      "access-control-request-method": "GET",
      "access-control-request-headers": `authorization,${NOT_IN_QUEBEC_HEADER.toLowerCase()}`,
    });
    expect(res.headers.get("access-control-allow-headers")).toContain(NOT_IN_QUEBEC_HEADER);
  });
});
