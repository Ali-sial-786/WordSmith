/**
 * The contact form (shared/contact.md): `POST /v1/contact
 * {topic, message, email?, username?, website?}` → 201 {ok: true}.
 *
 * No sign-in needed, since people write in when they can't get into their
 * account. The message is stored, then forwarded to the developer's inbox
 * after the answer (src/contact/mail.ts), so the sender never waits on email.
 */

import { forwardContactMessage } from "../contact/upkeep";
import { mailConfig } from "../contact/mail";
import {
  insertContactMessage,
  isContactTopic,
  MAX_EMAIL,
  MAX_MESSAGE,
  MAX_USERNAME,
  type NewContactMessage,
} from "../db/contact";
import { ApiError, json, readJsonObject } from "../http";
import type { RequestContext } from "./context";

/** Room for a 2000-character message even with every character escaped in the JSON. */
const MAX_CONTACT_BODY_BYTES = 32 * 1024;

/** A loose check: one @, something on each side, a dot in the domain, nothing that breaks a header. */
const EMAIL_RE = /^[^\s@<>()[\]\\,;:"]+@[^\s@<>()[\]\\,;:"]+\.[^\s@<>()[\]\\,;:".]+$/;

/** Control characters other than a tab or line break. */
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g;

const codePoints = (s: string) => [...s].length;

export async function postContact(c: RequestContext): Promise<Response> {
  let body: Record<string, unknown>;
  try {
    body = await readJsonObject(c.request, MAX_CONTACT_BODY_BYTES);
  } catch (err) {
    // The contract has one error for every malformed body.
    if (err instanceof ApiError) throw new ApiError(400, "bad_request", err.detail ?? err.code);
    throw err;
  }
  // The form's hidden field: people never see it, so anything in it means a
  // bot filled the form in. It's told the message went, and nothing is kept.
  const trap = body.website ?? "";
  if (trap !== "") return json({ ok: true }, 201);

  const input = parseContact(body);
  if (typeof input === "string") throw new ApiError(400, "bad_request", input);

  const ipHash = await hashIp(c.request.headers.get("cf-connecting-ip") ?? "unknown");
  const result = await insertContactMessage(c.env.DB, input, ipHash, c.now);
  if (!result.ok) {
    throw result.reason === "ip"
      ? new ApiError(429, "too_many_messages", "That's a lot of messages; please try again in an hour")
      : new ApiError(429, "contact_busy", "The inbox is full for today; please try again tomorrow");
  }

  const config = mailConfig(c.env);
  if (config !== null) {
    c.ctx.waitUntil(forwardContactMessage(c.env.DB, config, { id: result.id, ...input, createdAt: c.now }).catch((err: unknown) => {
      console.error(`contact #${result.id}: forwarding failed`, err);
    }));
  }
  return json({ ok: true }, 201);
}

/** A message, or what's wrong with the body. Missing, `null` and blank optional fields are the same. */
function parseContact(body: Record<string, unknown>): NewContactMessage | string {
  const { topic } = body;
  if (!isContactTopic(topic)) return "Pick what your message is about";

  if (typeof body.message !== "string") return "Write a message";
  const message = body.message.replace(/\r\n?/g, "\n").replace(CONTROL, "").trim();
  if (message === "") return "Write a message";
  if (codePoints(message) > MAX_MESSAGE) return `Messages can be at most ${MAX_MESSAGE} characters`;

  const email = optional(body.email);
  if (email === undefined) return "Email must be text";
  if (email !== null && (email.length > MAX_EMAIL || !EMAIL_RE.test(email))) return "That email address doesn't look right";

  const username = optional(body.username);
  if (username === undefined) return "Username must be text";
  if (username !== null && codePoints(username) > MAX_USERNAME) return `Usernames are at most ${MAX_USERNAME} characters`;

  return { topic, message, email, username };
}

/** A trimmed one-line field: `null` when it's missing or blank, `undefined` when it isn't text. */
function optional(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") return undefined;
  const text = value.replace(/\s+/g, " ").replace(CONTROL, "").trim();
  return text === "" ? null : text;
}

/** The sender's IP as a SHA-256 hex digest: enough to count their messages, never shown. */
async function hashIp(ip: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`wordsmith-contact:${ip}`));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
