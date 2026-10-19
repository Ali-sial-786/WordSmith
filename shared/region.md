# Quebec (shared contract)

Online play isn't offered in Quebec. Wordsmith is offered in every US state
and every Canadian province and territory except Quebec (not in the EU or
the UK). Solo play needs no account and collects nothing, so it stays open
everywhere, Quebec included.

"From Quebec" means Cloudflare places the request's IP address in Quebec
(`request.cf`: country `CA`, region `QC`; `server/src/region.ts`). It's
worked out per request and never stored.

## Server

Every route that needs a token answers a request from Quebec with
**`403 quebec_not_offered`** ("Online play isn't offered in Quebec"),
before the token is read. Nothing is created or changed, and an existing
account is kept: an IP address can place someone in the wrong province.

Two routes stay open, so players there can leave:

- `DELETE /v1/me` (delete the account);
- `DELETE /v1/me/push-token` (stop notifications to this phone).

Routes that need no token (`/v1/version`, `/v1/define`, `/v1/contact`, the
APK download) work from Quebec too, as do the two WebSockets (the app only
opens them after `GET /v1/me` has worked).

`GET /v1/version` says `quebec: true` when the request comes from Quebec.

### "I don't live in Quebec"

A request with the header **`X-Not-In-Quebec: 1`** is treated like any
other. The app sends it on every request once its player has said they
don't live in Quebec. The answer is kept on the device only; the server
never stores it. The terms say that saying so when you do live in Quebec
breaks them.

## What the app does

- When `/v1/version` says `quebec` (or any request answers
  `quebec_not_offered`), the sign-in screen says online play isn't offered
  in Quebec, that solo play and progress on this device are still theirs,
  and offers **"I don't live in Quebec"**. Signed-in players are signed
  out; their account is kept.
- "I don't live in Quebec" asks them to confirm, then remembers the answer
  on this device and sends the header from then on.
- Settings' **Delete account** still works from Quebec.
