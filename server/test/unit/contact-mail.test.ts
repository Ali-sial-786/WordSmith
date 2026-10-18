import { afterEach, describe, expect, it } from "vitest";
import { contactEmail, DEFAULT_FROM, mailConfig, setContactMailConfig, type MailConfig } from "../../src/contact/mail";
import { CONTACT_TOPICS, TOPIC_LABELS, type ContactMessage } from "../../src/db/contact";

const config: MailConfig = { apiKey: "re_key", to: "inbox@example.com", from: DEFAULT_FROM };

const message = (fields: Partial<ContactMessage> = {}): ContactMessage => ({
  id: 7,
  topic: "bug",
  message: "The anvil froze.\n\nAfter level 12.",
  email: "kit@example.com",
  username: "Kit",
  createdAt: Date.UTC(2026, 9, 18, 21, 5, 30),
  ...fields,
});

describe("mailConfig", () => {
  afterEach(() => setContactMailConfig(null));

  it("is on only with both secrets", () => {
    expect(mailConfig({})).toBeNull();
    expect(mailConfig({ RESEND_API_KEY: "re_key" })).toBeNull();
    expect(mailConfig({ CONTACT_EMAIL: "inbox@example.com" })).toBeNull();
    expect(mailConfig({ RESEND_API_KEY: " ", CONTACT_EMAIL: "inbox@example.com" })).toBeNull();
    expect(mailConfig({ RESEND_API_KEY: " re_key\n", CONTACT_EMAIL: " inbox@example.com " })).toEqual(config);
  });

  it("sends from CONTACT_FROM when it's set", () => {
    const from = "Wordsmith <contact@wordsmith.example>";
    expect(mailConfig({ RESEND_API_KEY: "re_key", CONTACT_EMAIL: "inbox@example.com", CONTACT_FROM: from })?.from).toBe(from);
    expect(mailConfig({ RESEND_API_KEY: "re_key", CONTACT_EMAIL: "inbox@example.com", CONTACT_FROM: "" })?.from).toBe(DEFAULT_FROM);
  });

  it("can be swapped for tests", () => {
    setContactMailConfig(config);
    expect(mailConfig({})).toBe(config);
  });
});

describe("contactEmail", () => {
  it("is a plain-text email to the inbox, replying to the sender", () => {
    expect(contactEmail(config, message())).toEqual({
      from: DEFAULT_FROM,
      to: ["inbox@example.com"],
      subject: "[Wordsmith] A bug or problem, from Kit",
      reply_to: "kit@example.com",
      text: [
        "Wordsmith contact form, message #7",
        "",
        "Topic: A bug or problem",
        "Username: Kit",
        "Email: kit@example.com",
        "Sent: 2026-10-18 21:05 UTC",
        "",
        "-".repeat(40),
        "The anvil froze.",
        "",
        "After level 12.",
        "-".repeat(40),
        "",
        "Reply to this email to answer them.",
      ].join("\n"),
    });
  });

  it("says what's missing, with no Reply-To", () => {
    const mail = contactEmail(config, message({ email: null, username: null }));
    expect(mail.subject).toBe("[Wordsmith] A bug or problem");
    expect(mail).not.toHaveProperty("reply_to");
    expect(mail.text).toContain("Username: (not given)");
    expect(mail.text).toContain("Email: (not given, so there's no way to reply)");
    expect(mail.text).toContain("They didn't leave an email address.");
  });

  it("names every topic", () => {
    for (const topic of CONTACT_TOPICS) expect(contactEmail(config, message({ topic })).subject).toContain(TOPIC_LABELS[topic]);
  });

  it("keeps line breaks out of the subject", () => {
    expect(contactEmail(config, message({ username: "Kit\r\nBcc: x@example.com" })).subject).toBe("[Wordsmith] A bug or problem, from Kit Bcc: x@example.com");
  });
});
