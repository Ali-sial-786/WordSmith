# Ages (shared contract)

Online play (an account) is for players **13 and over**, in every US state
and in Canada, except **14 and over in Quebec**. Quebec's private-sector
privacy law (Law 25, s. 4.1) needs a parent's consent to collect a child's
personal information under 14, and Wordsmith doesn't collect that consent.
Players under 18 are minors, and get safer defaults. Solo play needs no
account, so anyone can still play it.

"From Quebec" means Cloudflare places the request's IP address in Quebec
(`request.cf`: country `CA`, region `QC`; `server/src/region.ts`). It's
worked out per request and never stored.

## What's asked

The month and year someone was born, never the day. It is asked:

- **at setup**, alongside the username and emblem; and
- **once, later**, for accounts made before ages were asked (before 0.7).

The question is neutral: it doesn't say what answer lets you in.

An age counts a birthday only once its month is over (UTC). So someone born
in October 2013 is 12 for all of October 2026. That errs young, which is the
safe side for both rules.

## Routes

| Route | Body → answer | Notes |
|---|---|---|
| `POST /v1/me/setup` | `{username, avatar, birthYear, birthMonth}` → profile | Both birth fields may be left out (apps before 0.7); the profile then has `needsAge: true`. |
| `POST /v1/me/age` | `{birthYear, birthMonth}` → profile | For an account with no age yet; any account, set up or not. `409 age_already_set` once it's known (write to us through the contact form to fix a mistake). |

Both routes check the birth date the same way:

- `birthMonth` must be 1–12, and `birthYear` from 120 years ago to now.
- The date can't be in the future. Otherwise the answer is `400 invalid_birth`.
- **Under 13 → `403 under_13`; 13 from Quebec → `403 under_14_quebec`.**
  The account and everything it holds are deleted on the spot, as
  `DELETE /v1/me` would. The birth date is never stored.

The profile (`GET /v1/me` and every route that returns it) gains:

- `needsAge`: true until the birth month and year are known.
- `minor`: under 18 today; false while the age isn't known.

`GET /v1/version` also says `quebec: true` when the request comes from
Quebec.

## What the app does

- **Under 13 (or 14 in Quebec).** It tells the player online play is for 13 and over (14 in Quebec), and that
  they can still play solo. It deletes the Firebase sign-in, as account
  deletion does, and signs out. On that device, signing in stays closed: the
  sign-in screen says why, and asking again with another year isn't offered.
- **Minors (`minor`), and everyone in Quebec (`quebec` from `/v1/version`).**
  The microphone starts muted every time they join a room, and they can
  unmute themselves. In Quebec this is Law 25's "most private settings by
  default" (s. 9.1). The camera starts off for everyone.
- **`needsAge`.** A signed-in player whose age isn't known is asked before
  any online play, the same way setup is.
