# Invite notifications (shared contract, M5)

Room invites reach friends as phone notifications through Firebase Cloud
Messaging (FCM), even when the app is closed. It's off until the server has
an FCM service account; until then everything below quietly does nothing.

## Registering a phone

- `POST /v1/me/push-token` with `{token}` (the FCM registration token) →
  `{ok: true}`. Stores it for the caller. A token belongs to one account, so
  registering a token that another account had moves it here. At most 5 per
  account; the oldest is dropped.
- `DELETE /v1/me/push-token` with `{token}` → `{ok: true}` (sign-out, or
  notifications turned off). Unknown tokens are fine.
- Both need a set-up account. Deleting an account deletes its tokens.

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

Tokens FCM reports as unregistered or invalid (404, or 400
`INVALID_ARGUMENT` about the token) are deleted. Other failures are logged
and ignored, so an invite never fails because a notification did.

## Server setup

The Worker secret `FCM_SERVICE_ACCOUNT` holds the JSON key of a service
account allowed to send FCM messages, for example Firebase console → Project
settings → Service accounts → Generate new private key. The deploy workflow
copies it from the GitHub secret of the same name. The server signs a
Google OAuth JWT (RS256) with it and caches the access token until shortly
before it expires.
