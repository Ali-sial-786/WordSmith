# Contact form (shared contract)

The web pages (`/contact`, linked from `/privacy`, `/terms`,
`/delete-account` and the app's Settings) let anyone write to the developer
without the developer's email address appearing anywhere. Messages are
stored in D1 and forwarded to the developer's inbox by email
(server/src/contact/mail.ts); a reply, if the sender left an address, comes
from the developer's own email.

## `POST /v1/contact`

No sign-in needed: people write in when they can't get into their account.

```json
{
  "topic": "deletion",
  "message": "Please delete my account.",
  "email": "optional@example.com",
  "username": "optional",
  "website": ""
}
```

- `topic`: `account` · `deletion` · `bug` · `player` · `privacy` · `feedback`
  · `other`.
- `message`: required; line breaks kept, other control characters dropped,
  trimmed; 1 to 2000 characters (code points).
- `email`: optional, where to reply; at most 254 characters, and it must look
  like an address (one `@`, a dot in the domain, no spaces or brackets).
- `username`: optional, the sender's Wordsmith username as they typed it;
  whitespace collapsed; at most 40 characters.
- `website`: the form's hidden field, which people never see. Anything in it
  means a bot filled the form in: the answer is still `201`, and nothing is
  kept.
- Missing, `null` and blank optional fields are the same.
- → `201 {ok: true}`. `400 bad_request` (anything malformed; `message` says
  what), `429 too_many_messages` (more than 5 from one IP address in an
  hour), `429 contact_busy` (more than 80 from everyone in 24 hours).

## What's kept

- D1 `contact_messages`: the fields above, a SHA-256 hash of the sender's IP
  address (for the hourly limit), when it was sent, and when it was emailed.
- The hourly cron forgets each IP hash after a day and deletes messages after
  a year. Messages aren't tied to an account, so deleting one leaves them.

## Forwarding

- Turned on by the Worker secrets `RESEND_API_KEY` and `CONTACT_EMAIL` (the
  inbox), which the deploy workflow copies from GitHub secrets of the same
  names. The inbox address is never in the repo or on a page.
- Each message is sent once, right after it's stored, through Resend
  (`POST https://api.resend.com/emails`, plain text, `Reply-To` set to the
  sender's address when they left one). The sender is Resend's shared
  `onboarding@resend.dev` unless the var `CONTACT_FROM` names another.
- One that fails is retried by the hourly cron from 10 minutes after it was
  sent, at most 5 tries in all and for a week. While forwarding is off,
  messages are only stored; once it's on, the cron sends the last week's.
