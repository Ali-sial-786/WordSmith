# Blocking and reporting (shared contract)

Players can block anyone and report anyone, from room chat, the lobby and the
friends list. This keeps chat in line with app-store rules on user content:
report and block tools in the app, terms players can read (`/terms` on the
web version), and someone looking at what's reported (docs/DISTRIBUTION.md,
"Reports").

All routes need the usual Firebase token. User ids are the server's user ids
(as in `LOBBY` players and the friends list).

## Blocks

Blocking is the blocker's own choice; the blocked player isn't told.

| Route | Body / answer | Notes |
|---|---|---|
| `GET /v1/me/blocks` | → `200 {blocks: [{id, username, avatar, at}]}`, newest first | `at`: when, epoch ms. |
| `PUT /v1/me/blocks/:id` | → `200 {ok: true}` | Idempotent. `400 cannot_block_self`, `404 user_not_found`. Ends any friendship and pending friend request between the two, either way, as `DELETE /v1/friends/:id` would (with the same hub updates). |
| `DELETE /v1/me/blocks/:id` | → `200 {ok: true}` | Idempotent; unblocking doesn't restore the friendship. |

While either player has blocked the other:

- A friend request between them is refused: the blocked player gets
  `404 user_not_found` (as if the name were wrong); the blocker gets
  `409 blocked` ("unblock them first").
- Nothing else changes on the server: they aren't friends any more, so no
  invites, gifts or open rooms pass between them. They can still end up in
  the same room by its code.

On the phone, a blocked player's chat lines (and emotes) are hidden in every
room, they're not counted or popped up, and their name in the lobby shows a
"Blocked" tag. Unblock from Settings > Blocked smiths.

## Reports

`POST /v1/reports`

```json
{
  "userId": "…",
  "reason": "harassment",
  "details": "optional, up to 500 characters",
  "room": "K7Q2AB",
  "lines": [{"id": 12, "text": "…", "at": 1760000000000}]
}
```

- `reason`: `harassment` · `hate` · `sexual` · `name` (an offensive username)
  · `cheating` · `spam` · `other`.
- `details`: optional, trimmed, at most 500 characters.
- `room`: optional, the room code it happened in.
- `lines`: optional, at most 20 of the reported player's chat lines as the
  reporter saw them (`text` at most 200 characters).
- → `201 {ok: true}`. `400 bad_request` (anything malformed),
  `400 cannot_report_self`, `404 user_not_found`, `429 too_many_reports`
  (more than 10 from one player in 24 hours).
- Stored in D1 `reports` with the reported player's username at the time and
  `status` `open`. Nothing tells the reported player.

## Account deletion

Deleting an account (`DELETE /v1/me`) also deletes its blocks (both ways) and
every report it made or that was made about it.
