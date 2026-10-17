# Push notifications (shared contract, M5)

Room invites, gifts and daily reminders reach friends as phone notifications
through Firebase Cloud Messaging (FCM), even when the app is closed. It's off until the server has
an FCM service account; until then everything below quietly does nothing.

## Registering a phone

- `POST /v1/me/push-token` with `{token}` (the FCM registration token) →
  `{ok: true}`. Stores it for the caller. A token belongs to one account, so
  registering a token that another account had moves it here. At most 5 per
  account; the oldest is dropped.
- `DELETE /v1/me/push-token` with `{token}` → `{ok: true}` (sign-out, or
  notifications turned off). Unknown tokens are fine.
- Both need a set-up account (`403 setup_required`). A token must be 1–4096
  printable ASCII characters without spaces (`400 invalid_push_token`). DELETE
  only removes the caller's own token. Tokens are stored even while the server
  has no FCM key, so they work as soon as it's added. Deleting an account
  deletes its tokens.

## Sending

When the hub relays an `INVITE`, the server also sends a notification to each
of the invited friend's tokens, whether or not they're online. Android only
shows it when the app isn't in the foreground; in the foreground the app
shows its own banner as before. An invite to a friend with no open hub socket
and no tokens still gets `ERROR friend_offline`.

FCM HTTP v1 message:

```json
{
  "message": {
    "token": "<token>",
    "notification": { "title": "Ali invited you to Versus", "body": "Tap to join room K7Q2AB" },
    "data": { "type": "invite", "code": "K7Q2AB", "mode": "vs", "from": "<user id>" },
    "android": { "priority": "high", "ttl": "300s", "collapse_key": "invite-K7Q2AB" }
  }
}
```

An invite that only reached the friend's phones gets no reply, like a relayed
one. Invites for the same room share a `collapse_key`, so they replace each
other on the phone.

Tokens FCM reports as unregistered or invalid (404, or 400
`INVALID_ARGUMENT` about the token) are deleted. Other failures are logged
and ignored, so an invite never fails because a notification did.

## Gift notifications

When a friend sends a gift (`POST /v1/friends/:id/gift`,
`shared/forge-board.md`), the server sends a notification to each of the
receiver's tokens, after answering the sender. Only a gift that was actually
recorded is announced (not an `already_sent` one). Failures are handled as
for invites, and never fail the gift.

```json
{
  "message": {
    "token": "<token>",
    "notification": { "title": "Ali sent you a gift", "body": "A free Hammer Strike is waiting in the Forge Hall" },
    "data": { "type": "gift", "from": "<user id>" },
    "android": { "priority": "normal", "ttl": "86400s", "collapse_key": "gift-<user id>" }
  }
}
```

The app opens the Forge Hall when it's tapped. Gifts from the same friend
share a `collapse_key`.

## Server setup

The Worker secret `FCM_SERVICE_ACCOUNT` holds the JSON key of a service
account allowed to send FCM messages, for example Firebase console → Project
settings → Service accounts → Generate new private key. The deploy workflow
copies it from the GitHub secret of the same name. The server signs a
Google OAuth JWT (RS256) with it and caches the access token until shortly
before it expires.

## Daily reminders

A player can ask for one reminder a day when the Daily Commission is still
waiting. The app converts the hour they pick from local time to UTC.

- `PUT /v1/me/reminder` with `{hour}` (an integer 0–23, a UTC hour) or
  `{hour: null}` (off) → `{ok: true, hour}`. `400 invalid_body` otherwise
  (`hour` missing included). It needs a set-up account. The profile gains
  `reminderHour` (the UTC hour, or `null`; `null` for new accounts).
- A Cron Trigger runs at the start of every hour. For each account whose
  `reminderHour` is the current UTC hour, that has push tokens, hasn't
  completed today's Daily Commission and hasn't been reminded today, it sends
  one notification to each token and records today's date:

  ```json
  {
    "notification": { "title": "Today's Daily Commission is waiting",
                      "body": "Keep your 5-day streak going!" },
    "data": { "type": "daily" },
    "android": { "priority": "normal", "ttl": "3600s", "collapse_key": "daily" }
  }
  ```

  The body is "Keep your N-day streak going!" when the player's streak
  (ending yesterday, on-time days only, as in `shared/daily.md`) is at least
  1, otherwise "A new puzzle is on the anvil."
- The day is recorded just before the notification is sent, so two runs that
  overlap can't remind anyone twice; a send that fails isn't retried that
  day. Dead tokens are forgotten as for invites.
- Up to 500 accounts per run, oldest reminder first. Without an FCM key it
  does nothing.
