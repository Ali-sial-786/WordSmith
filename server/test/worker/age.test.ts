/**
 * Ages (shared/age.md): the birth month and year at setup or once later,
 * under-13s refused with their account deleted, and the `minor` flag.
 */

import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { body, client, setUpClient, uniqueName, type Client } from "./helpers";

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
