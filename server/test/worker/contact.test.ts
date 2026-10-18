/**
 * The contact form (shared/contact.md), with migrations/0009_contact.sql.
 *
 * The test env has no RESEND_API_KEY or CONTACT_EMAIL, so forwarding is off
 * unless a test installs settings with setContactMailConfig() and routes the
 * Worker's requests to Resend into `fakeResend` with setContactFetcher().
 */

import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DEFAULT_FROM, RESEND_URL, setContactFetcher, setContactMailConfig, type MailConfig } from "../../src/contact/mail";
import {
  CONTACT_TOPICS,
  DAY_MS,
  insertContactMessage,
  MAX_EMAIL_ATTEMPTS,
  MAX_MESSAGE,
  MAX_PER_DAY,
  MAX_PER_IP,
  RETRY_AFTER_MS,
} from "../../src/db/contact";
import worker from "../../src/index";
import { BASE, body } from "./helpers";

const PLAY = "https://play.wordsmith-forge.workers.dev";
const CONFIG: MailConfig = { apiKey: "re_test_key", to: "inbox@example.com", from: DEFAULT_FROM };

interface Row {
  id: number;
  topic: string;
  message: string;
  email: string | null;
  username: string | null;
  ip_hash: string | null;
  created_at: number;
  emailed_at: number | null;
  email_attempts: number;
  status: string;
}

const rows = async () => (await env.DB.prepare("SELECT * FROM contact_messages ORDER BY id").all<Row>()).results;

let ipCounter = 0;
/** A fresh IP address, so each test has its own hourly allowance. */
const freshIp = () => `203.0.113.${++ipCounter}`;

/** POSTs to /v1/contact and waits for anything it left running (the forwarding). */
async function send(payload: unknown, ip = freshIp(), headers: Record<string, string> = {}) {
  const ctx = createExecutionContext();
  const res = await worker.fetch(
    new Request(`${BASE}/v1/contact`, {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": ip, ...headers },
      body: typeof payload === "string" ? payload : JSON.stringify(payload),
    }),
    env,
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return { status: res.status, body: await body(res), headers: res.headers };
}

/** The hourly Cron Trigger, as if it fired at `at` (epoch ms). */
async function cron(at: number): Promise<void> {
  const ctx = createExecutionContext();
  await worker.scheduled(createScheduledController({ scheduledTime: at, cron: "0 * * * *" }), env, ctx);
  await waitOnExecutionContext(ctx);
}

interface Sent {
  readonly url: string;
  readonly headers: Headers;
  readonly body: Record<string, unknown>;
}

/** Stands in for Resend: records each email and answers with `status()`. */
function fakeResend(status: () => number = () => 200) {
  const sent: Sent[] = [];
  const fetch: typeof globalThis.fetch = async (input, init) => {
    const req = new Request(input, init);
    sent.push({ url: req.url, headers: req.headers, body: (await req.json()) as Record<string, unknown> });
    const code = status();
    return Response.json(code === 200 ? { id: `email-${sent.length}` } : { message: "nope" }, { status: code });
  };
  return { sent, fetch };
}

const valid = { topic: "account", message: "I can't sign in on my new phone." };

beforeEach(async () => {
  await env.DB.prepare("DELETE FROM contact_messages").run();
});

afterEach(() => {
  setContactFetcher(null);
  setContactMailConfig(null);
});

describe("POST /v1/contact", () => {
  it("keeps a message from anyone, no sign-in needed", async () => {
    const before = Date.now();
    const res = await send({ topic: "deletion", message: "Please delete my account.", email: "kit@example.com", username: "Kit_the_Smith" });
    expect(res).toMatchObject({ status: 201, body: { ok: true } });
    const [row, ...rest] = await rows();
    expect(rest).toHaveLength(0);
    expect(row).toMatchObject({
      topic: "deletion",
      message: "Please delete my account.",
      email: "kit@example.com",
      username: "Kit_the_Smith",
      emailed_at: null,
      email_attempts: 0,
      status: "open",
    });
    expect(row!.created_at).toBeGreaterThanOrEqual(before);
    // The IP is only kept as a hash.
    expect(row!.ip_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("takes every topic, and the optional fields can be left out, null or blank", async () => {
    for (const topic of CONTACT_TOPICS) expect((await send({ topic, message: `About ${topic}` })).status).toBe(201);
    expect((await send({ ...valid, email: null, username: null })).status).toBe(201);
    expect((await send({ ...valid, email: "  ", username: "" })).status).toBe(201);
    const all = await rows();
    expect(all.map((r) => r.topic)).toEqual([...CONTACT_TOPICS, "account", "account"]);
    for (const r of all) expect(r).toMatchObject({ email: null, username: null });
  });

  it("tidies what it keeps", async () => {
    const res = await send({
      topic: "bug",
      message: "  The anvil froze.\r\n\r\nAfter level 12.\u0007  ",
      email: "  kit@example.com ",
      username: "  Kit   the\tSmith ",
    });
    expect(res.status).toBe(201);
    expect((await rows())[0]).toMatchObject({ message: "The anvil froze.\n\nAfter level 12.", email: "kit@example.com", username: "Kit the Smith" });
  });

  it("allows 2000 characters, emoji counted as one", async () => {
    expect((await send({ ...valid, message: "🔥".repeat(MAX_MESSAGE) })).status).toBe(201);
    expect((await send({ ...valid, message: "a".repeat(MAX_MESSAGE + 1) })).body).toMatchObject({ error: "bad_request" });
  });

  it("refuses anything malformed", async () => {
    const bad: unknown[] = [
      {},
      { message: "hi" },
      { topic: "billing", message: "hi" },
      { topic: "account" },
      { topic: "account", message: "   \n " },
      { topic: "account", message: 42 },
      { ...valid, email: "not-an-email" },
      { ...valid, email: "kit@localhost" },
      { ...valid, email: "kit@example.com\r\nBcc: x@example.com" },
      { ...valid, email: `${"k".repeat(250)}@example.com` },
      { ...valid, email: 7 },
      { ...valid, username: "x".repeat(41) },
      { ...valid, username: ["Kit"] },
      [valid],
      "{not json",
    ];
    for (const payload of bad) {
      const res = await send(payload);
      expect(res.status, JSON.stringify(payload)).toBe(400);
      expect(res.body.error).toBe("bad_request");
    }
    expect(await rows()).toHaveLength(0);
  });

  it("tells a bot that filled in the hidden field it worked, and keeps nothing", async () => {
    expect(await send({ ...valid, website: "http://spam.example" })).toMatchObject({ status: 201, body: { ok: true } });
    expect(await rows()).toHaveLength(0);
    // Left empty, as people leave it, it's fine.
    expect((await send({ ...valid, website: "" })).status).toBe(201);
    expect(await rows()).toHaveLength(1);
  });

  it(`takes ${MAX_PER_IP} an hour from one address`, async () => {
    const ip = freshIp();
    for (let i = 0; i < MAX_PER_IP; i++) expect((await send(valid, ip)).status).toBe(201);
    expect(await send(valid, ip)).toMatchObject({ status: 429, body: { error: "too_many_messages" } });
    expect((await send(valid)).status).toBe(201);
    // An hour on, that address may write again.
    await env.DB.prepare("UPDATE contact_messages SET created_at = created_at - 3600001").run();
    expect((await send(valid, ip)).status).toBe(201);
  });

  it(`takes ${MAX_PER_DAY} a day from everyone`, async () => {
    const now = Date.now();
    for (let i = 0; i < MAX_PER_DAY; i++) {
      expect(await insertContactMessage(env.DB, { topic: "other", message: "m", email: null, username: null }, `ip-${i}`, now - i)).toMatchObject({ ok: true });
    }
    expect(await send(valid)).toMatchObject({ status: 429, body: { error: "contact_busy" } });
    await env.DB.prepare("UPDATE contact_messages SET created_at = created_at - ?1").bind(DAY_MS).run();
    expect((await send(valid)).status).toBe(201);
  });

  it("answers the web pages' origin", async () => {
    const preflight = await worker.fetch(
      new Request(`${BASE}/v1/contact`, {
        method: "OPTIONS",
        headers: { Origin: PLAY, "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type" },
      }),
      env,
      createExecutionContext(),
    );
    expect(preflight.status).toBe(204);
    expect(preflight.headers.get("access-control-allow-origin")).toBe(PLAY);
    expect((await send(valid, freshIp(), { Origin: PLAY })).headers.get("access-control-allow-origin")).toBe(PLAY);
  });

  it("only takes POST", async () => {
    const res = await worker.fetch(new Request(`${BASE}/v1/contact`), env, createExecutionContext());
    expect(res.status).toBe(405);
  });
});

describe("forwarding to the inbox", () => {
  it("emails each message to the inbox, replying to the sender", async () => {
    const resend = fakeResend();
    setContactFetcher(resend.fetch);
    setContactMailConfig(CONFIG);
    expect((await send({ topic: "account", message: "Locked out.\nHelp!", email: "kit@example.com", username: "Kit" })).status).toBe(201);
    const [row] = await rows();
    expect(resend.sent).toHaveLength(1);
    const [mail] = resend.sent;
    expect(mail!.url).toBe(RESEND_URL);
    expect(mail!.headers.get("authorization")).toBe("Bearer re_test_key");
    expect(mail!.headers.get("idempotency-key")).toBe(`wordsmith-contact-${row!.id}`);
    expect(mail!.body).toMatchObject({
      from: DEFAULT_FROM,
      to: ["inbox@example.com"],
      subject: "[Wordsmith] Help with an account, from Kit",
      reply_to: "kit@example.com",
    });
    expect(mail!.body.text).toContain("Locked out.\nHelp!");
    expect(mail!.body.text).toContain(`message #${row!.id}`);
    expect(row).toMatchObject({ email_attempts: 1 });
    expect(row!.emailed_at).not.toBeNull();
  });

  it("without an address to reply to, there's no Reply-To", async () => {
    const resend = fakeResend();
    setContactFetcher(resend.fetch);
    setContactMailConfig(CONFIG);
    await send({ topic: "feedback", message: "More fonts please" });
    expect(resend.sent[0]!.body.subject).toBe("[Wordsmith] Ideas and feedback");
    expect(resend.sent[0]!.body).not.toHaveProperty("reply_to");
  });

  it("keeps the message when Resend fails, and the cron tries again", async () => {
    let status = 500;
    const resend = fakeResend(() => status);
    setContactFetcher(resend.fetch);
    setContactMailConfig(CONFIG);
    expect((await send(valid)).status).toBe(201);
    expect(await rows()).toMatchObject([{ emailed_at: null, email_attempts: 1 }]);

    const sentAt = (await rows())[0]!.created_at;
    // Too soon: the first try might still be running.
    await cron(sentAt + RETRY_AFTER_MS - 1);
    expect(resend.sent).toHaveLength(1);
    // Still failing: counted.
    await cron(sentAt + RETRY_AFTER_MS);
    expect(resend.sent).toHaveLength(2);
    status = 200;
    await cron(sentAt + 2 * RETRY_AFTER_MS);
    expect(resend.sent).toHaveLength(3);
    expect(await rows()).toMatchObject([{ email_attempts: 3 }]);
    expect((await rows())[0]!.emailed_at).not.toBeNull();
    // Sent: never again.
    await cron(sentAt + 3 * RETRY_AFTER_MS);
    expect(resend.sent).toHaveLength(3);
  });

  it(`gives up after ${MAX_EMAIL_ATTEMPTS} tries, or a week`, async () => {
    const resend = fakeResend(() => 422);
    setContactFetcher(resend.fetch);
    setContactMailConfig(CONFIG);
    await send(valid);
    await send(valid);
    const [first, second] = await rows();
    // The second has been waiting more than a week.
    await env.DB.prepare("UPDATE contact_messages SET created_at = created_at - ?1 WHERE id = ?2").bind(8 * DAY_MS, second!.id).run();
    const at = first!.created_at + RETRY_AFTER_MS;
    for (let i = 0; i < MAX_EMAIL_ATTEMPTS + 2; i++) await cron(at + i * 3_600_000);
    const triesAt = (id: number) => resend.sent.filter((m) => m.headers.get("idempotency-key") === `wordsmith-contact-${id}`).length;
    expect(triesAt(first!.id)).toBe(MAX_EMAIL_ATTEMPTS);
    // Only the try when it was sent.
    expect(triesAt(second!.id)).toBe(1);
  });

  it("while forwarding is off, only keeps messages; once it's on, the cron sends the last week's", async () => {
    const resend = fakeResend();
    setContactFetcher(resend.fetch);
    expect((await send(valid)).status).toBe(201);
    await send({ ...valid, message: "older" });
    const [, older] = await rows();
    await env.DB.prepare("UPDATE contact_messages SET created_at = created_at - ?1 WHERE id = ?2").bind(8 * DAY_MS, older!.id).run();
    await cron(Date.now() + RETRY_AFTER_MS);
    expect(resend.sent).toHaveLength(0);
    expect(await rows()).toMatchObject([{ email_attempts: 0 }, { email_attempts: 0 }]);

    setContactMailConfig(CONFIG);
    await cron(Date.now() + RETRY_AFTER_MS);
    expect(resend.sent).toHaveLength(1);
    expect(resend.sent[0]!.body.text).toContain(valid.message);
  });
});

describe("upkeep", () => {
  it("forgets IP hashes after a day and messages after a year", async () => {
    await send(valid);
    await send({ ...valid, message: "old" });
    const [recent, old] = await rows();
    await env.DB.prepare("UPDATE contact_messages SET created_at = created_at - ?1 WHERE id = ?2").bind(366 * DAY_MS, old!.id).run();
    await cron(recent!.created_at + DAY_MS - 1);
    expect((await rows()).map((r) => r.id)).toEqual([recent!.id]);
    expect((await rows())[0]!.ip_hash).not.toBeNull();
    await cron(recent!.created_at + DAY_MS);
    expect((await rows())[0]!.ip_hash).toBeNull();
  });
});
