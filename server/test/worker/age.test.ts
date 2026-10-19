/**
 * Ages (shared/age.md): the birth month and year at setup or once later,
 * under-13s refused with their account deleted, and the `minor` flag.
 */

import { createExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../../src/index";
import { BASE, body, client, setUpClient, uniqueName, type Client } from "./helpers";

interface Profile {
  username: string | null;
  needsSetup: boolean;
  needsAge: boolean;
  minor: boolean;
}

/** Born `years` (and a month) ago, today: safely past that birthday. */
function bornYearsAgo(years: number): { birthYear: number; birthMonth: number } {
  const d = new Date();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() - 1);
  return { birthYear: d.getUTCFullYear() - years, birthMonth: d.getUTCMonth() + 1 };
}

const setup = (c: Client, extra: Record<string, unknown> = {}) =>
  c.post("/v1/me/setup", { username: uniqueName(), avatar: "avatar_01", ...extra });
const userRow = (uid: string) => env.DB.prepare("SELECT birth_year, birth_month FROM users WHERE id = ?1").bind(uid).first();

afterEach(() => {
  vi.useRealTimers();
});

describe("age at setup", () => {
  it("keeps an adult's birth month and year, and says they're grown up", async () => {
    const c = await client();
    const born = bornYearsAgo(30);
    const res = await setup(c, born);
    expect(res.status).toBe(200);
    expect(await body<Profile>(res)).toMatchObject({ needsSetup: false, needsAge: false, minor: false });
    expect(await userRow(c.uid)).toEqual({ birth_year: born.birthYear, birth_month: born.birthMonth });
  });

  it("marks 13 to 17 as minors", async () => {
    for (const years of [13, 17]) {
      const res = await setup(await client(), bornYearsAgo(years));
      expect(res.status).toBe(200);
      expect(await body<Profile>(res)).toMatchObject({ needsAge: false, minor: true });
    }
    const adult = await setup(await client(), bornYearsAgo(18));
    expect(await body<Profile>(adult)).toMatchObject({ minor: false });
  });

  it("refuses an under-13 and keeps nothing", async () => {
    const c = await client();
    expect((await c.get("/v1/me")).status).toBe(200);
    const res = await setup(c, bornYearsAgo(12));
    expect(res.status).toBe(403);
    expect(await body(res)).toMatchObject({ error: "under_13" });
    expect(await userRow(c.uid)).toBeNull();
    expect(await env.DB.prepare("SELECT 1 FROM profiles WHERE user_id = ?1").bind(c.uid).first()).toBeNull();
  });

  it("counts the birthday only after its month: born this month 13 years ago is still 12", async () => {
    const now = new Date();
    const res = await setup(await client(), { birthYear: now.getUTCFullYear() - 13, birthMonth: now.getUTCMonth() + 1 });
    expect(res.status).toBe(403);
  });

  it("still sets up an account from an app that doesn't ask (before 0.7), which then needs its age", async () => {
    const c = await setUpClient();
    expect(await body<Profile>(await c.get("/v1/me"))).toMatchObject({ needsSetup: false, needsAge: true, minor: false });
  });

  it("refuses an impossible birth date", async () => {
    for (const bad of [{ birthYear: 2000 }, { birthMonth: 4 }, { birthYear: 2000, birthMonth: 13 }, { birthYear: 3000, birthMonth: 1 }, { birthYear: "2000", birthMonth: 1 }]) {
      const res = await setup(await client(), bad);
      expect(res.status, JSON.stringify(bad)).toBe(400);
      expect(await body(res)).toMatchObject({ error: "invalid_birth" });
    }
  });
});

describe("POST /v1/me/age", () => {
  it("sets the age of an account that hasn't given one, once", async () => {
    const c = await setUpClient();
    const res = await c.post("/v1/me/age", bornYearsAgo(15));
    expect(res.status).toBe(200);
    expect(await body<Profile>(res)).toMatchObject({ needsAge: false, minor: true });
    const again = await c.post("/v1/me/age", bornYearsAgo(40));
    expect(again.status).toBe(409);
    expect(await body(again)).toMatchObject({ error: "age_already_set" });
    expect(await body<Profile>(await c.get("/v1/me"))).toMatchObject({ minor: true });
  });

  it("deletes the whole account of someone under 13", async () => {
    const c = await setUpClient();
    const res = await c.post("/v1/me/age", bornYearsAgo(10));
    expect(res.status).toBe(403);
    expect(await body(res)).toMatchObject({ error: "under_13" });
    expect(await userRow(c.uid)).toBeNull();
    // Asking again starts a new, empty account.
    expect(await body<Profile>(await c.get("/v1/me"))).toMatchObject({ needsSetup: true, needsAge: true });
  });

  it("refuses an impossible birth date", async () => {
    const c = await setUpClient();
    const res = await c.post("/v1/me/age", { birthYear: 2000, birthMonth: 0 });
    expect(res.status).toBe(400);
  });

  it("works out minors from today's date, so a 17-year-old grows up", async () => {
    const c = await setUpClient();
    const born = bornYearsAgo(17);
    expect(await body<Profile>(await c.post("/v1/me/age", born))).toMatchObject({ minor: true });
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(Date.UTC(born.birthYear + 18, born.birthMonth, 2)));
    const later = await client(c.uid);
    expect(await body<Profile>(await later.get("/v1/me"))).toMatchObject({ minor: false });
  });
});

/** A request as Cloudflare delivers it from `country`/`regionCode`. */
function from(path: string, c: Client, where: { country: string; regionCode: string }, payload?: unknown): Promise<Response> {
  const init: RequestInit<IncomingRequestCfProperties> = {
    method: payload === undefined ? "GET" : "POST",
    headers: { authorization: `Bearer ${c.token}`, "content-type": "application/json" },
    cf: where as IncomingRequestCfProperties,
    ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
  };
  return worker.fetch(new Request(`${BASE}${path}`, init), env, createExecutionContext());
}

const QUEBEC = { country: "CA", regionCode: "QC" };
const ONTARIO = { country: "CA", regionCode: "ON" };

describe("Quebec (Law 25: a parent's consent under 14)", () => {
  it("starts online play at 14 from Quebec, and deletes a 13-year-old's account", async () => {
    const c = await client();
    const res = await from("/v1/me/setup", c, QUEBEC, { username: uniqueName(), avatar: "avatar_01", ...bornYearsAgo(13) });
    expect(res.status).toBe(403);
    expect(await body(res)).toMatchObject({ error: "under_14_quebec" });
    expect(await userRow(c.uid)).toBeNull();

    const fourteen = await from("/v1/me/setup", await client(), QUEBEC, { username: uniqueName(), avatar: "avatar_01", ...bornYearsAgo(14) });
    expect(fourteen.status).toBe(200);
    const younger = await from("/v1/me/setup", await client(), QUEBEC, { username: uniqueName(), avatar: "avatar_01", ...bornYearsAgo(12) });
    expect(await body(younger)).toMatchObject({ error: "under_13" });
  });

  it("keeps 13 as the minimum elsewhere in Canada", async () => {
    const res = await from("/v1/me/setup", await client(), ONTARIO, { username: uniqueName(), avatar: "avatar_01", ...bornYearsAgo(13) });
    expect(res.status).toBe(200);
  });

  it("applies to an older account giving its age from Quebec", async () => {
    const c = await setUpClient();
    const res = await from("/v1/me/age", c, QUEBEC, bornYearsAgo(13));
    expect(await body(res)).toMatchObject({ error: "under_14_quebec" });
    expect(await userRow(c.uid)).toBeNull();
  });

  it("tells the app, in /v1/version, to start rooms muted in Quebec", async () => {
    const c = await client();
    expect(await body(await from("/v1/version", c, QUEBEC))).toMatchObject({ quebec: true });
    expect(await body(await from("/v1/version", c, ONTARIO))).toMatchObject({ quebec: false });
  });
});
