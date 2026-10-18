/**
 * Forwards contact form messages to the developer's inbox (shared/contact.md)
 * with Resend's email API.
 *
 * Two Worker secrets, set by the deploy workflow, turn it on:
 * `RESEND_API_KEY` and `CONTACT_EMAIL` (the inbox; with Resend's shared
 * sending address it must be the Resend account's own email). The optional
 * var `CONTACT_FROM` replaces that sender once there's a verified domain.
 * While either secret is missing, messages are only stored in D1, and the
 * hourly cron forwards the last week's once they're set (src/contact/upkeep.ts).
 *
 * Tests swap the network with {@link setContactFetcher} and the secrets with
 * {@link setContactMailConfig}.
 */

import { TOPIC_LABELS, type ContactMessage } from "../db/contact";

export const RESEND_URL = "https://api.resend.com/emails";
/** Resend's shared sender, which needs no domain but only sends to the account's own address. */
export const DEFAULT_FROM = "Wordsmith contact form <onboarding@resend.dev>";
/** A try that takes longer than this counts as failed; the cron tries again. */
const SEND_TIMEOUT_MS = 10_000;

export interface MailEnv {
  RESEND_API_KEY?: string;
  CONTACT_EMAIL?: string;
  CONTACT_FROM?: string;
}

export interface MailConfig {
  readonly apiKey: string;
  readonly to: string;
  readonly from: string;
}

let fetcher: typeof fetch = (input, init) => fetch(input, init);
let configOverride: MailConfig | null = null;

/** Where messages go, or `null` while forwarding is off. */
export function mailConfig(env: MailEnv): MailConfig | null {
  if (configOverride !== null) return configOverride;
  const apiKey = env.RESEND_API_KEY?.trim() ?? "";
  const to = env.CONTACT_EMAIL?.trim() ?? "";
  if (apiKey === "" || to === "") return null;
  return { apiKey, to, from: env.CONTACT_FROM?.trim() || DEFAULT_FROM };
}

/** For tests: where requests to Resend go instead of `fetch` (`null` restores it). */
export function setContactFetcher(fn: typeof fetch | null): void {
  fetcher = fn ?? ((input, init) => fetch(input, init));
}

/** For tests: forwarding settings to use instead of the env's (`null` goes back to the env). */
export function setContactMailConfig(config: MailConfig | null): void {
  configOverride = config;
}

/** The body Resend's `POST /emails` takes for one message. */
export interface OutgoingEmail {
  readonly from: string;
  readonly to: string[];
  readonly subject: string;
  readonly text: string;
  readonly reply_to?: string;
}

/** Line breaks and other control characters, which have no place in a subject. */
const CONTROL = /[\u0000-\u001f\u007f]+/g;

const utcTime = (ms: number) => new Date(ms).toISOString().slice(0, 16).replace("T", " ") + " UTC";

/** The email for a message: plain text, with Reply-To set to the sender when they gave an address. */
export function contactEmail(config: MailConfig, m: ContactMessage): OutgoingEmail {
  const topic = TOPIC_LABELS[m.topic];
  const subject = `[Wordsmith] ${topic}${m.username === null ? "" : `, from ${m.username}`}`.replace(CONTROL, " ");
  const rule = "-".repeat(40);
  const text = [
    `Wordsmith contact form, message #${m.id}`,
    "",
    `Topic: ${topic}`,
    `Username: ${m.username ?? "(not given)"}`,
    `Email: ${m.email ?? "(not given, so there's no way to reply)"}`,
    `Sent: ${utcTime(m.createdAt)}`,
    "",
    rule,
    m.message,
    rule,
    "",
    m.email === null ? "They didn't leave an email address." : "Reply to this email to answer them.",
  ].join("\n");
  return { from: config.from, to: [config.to], subject, text, ...(m.email === null ? {} : { reply_to: m.email }) };
}

/** Sends one message to the inbox. False if Resend refused it or couldn't be reached (logged). */
export async function sendContactEmail(config: MailConfig, m: ContactMessage): Promise<boolean> {
  try {
    const res = await fetcher(RESEND_URL, {
      method: "POST",
      headers: {
        authorization: `Bearer ${config.apiKey}`,
        "content-type": "application/json",
        // A retry of the same message within a day isn't sent twice.
        "idempotency-key": `wordsmith-contact-${m.id}`,
      },
      body: JSON.stringify(contactEmail(config, m)),
      signal: AbortSignal.timeout(SEND_TIMEOUT_MS),
    });
    if (res.ok) return true;
    console.error(`contact #${m.id}: Resend answered ${res.status}`, (await res.text()).slice(0, 500));
    return false;
  } catch (err) {
    console.error(`contact #${m.id}: Resend couldn't be reached`, err);
    return false;
  }
}
