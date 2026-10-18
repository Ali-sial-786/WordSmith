/**
 * HubDO: the one global Durable Object for presence and invites
 * (docs/TECH.md §2 and §5). Reached only through the Worker, which has
 * already verified the player's token.
 *
 * Built to cost nothing while idle (docs/TECH.md §12):
 * - Sockets use the WebSocket Hibernation API, so the hub can be evicted
 *   from memory between messages while sockets stay open.
 * - Nothing that matters lives only in memory. Each socket's attachment
 *   holds its user ID, username and status; each connected player's
 *   friend IDs are kept in the DO's own SQLite storage (`links`).
 * - No alarms or timers. `{"op":"PING"}` keep-alives are answered by the
 *   runtime without waking the hub.
 *
 * It also keeps the open-rooms directory: each RoomDO reports its listing
 * (or its closing) through {@link HubDO.roomListing}, and every connected
 * friend of the host gets a fresh `OPEN_ROOMS`. Listings live in the
 * hub's storage (`rooms`).
 *
 * A player can have several sockets (two phones, or a reconnect that beats
 * the old socket's close). They're online while any is open; their status
 * is the one set most recently on any of them.
 *
 * Once `FCM_SERVICE_ACCOUNT` is set, an invite also goes to the friend's
 * phones as a notification (shared/push.md, src/push/).
 */

import { DurableObject } from "cloudflare:workers";
import { pushTargetOf } from "../db/push";
import type { Env } from "../env";
import { fcmSender } from "../push/fcm";
import { pushInvite, type InviteNotice } from "../push/invite";
import {
  parseClientMessage,
  PING,
  PONG,
  RateLimiter,
  type ClientMessage,
  type HubErrorCode,
  type OpenRoom,
  type PresenceStatus,
  type RoomListing,
  type ServerMessage,
} from "./protocol";

/** Headers the Worker sets when it forwards an upgrade to the hub. */
export const HUB_USER_HEADER = "x-wordsmith-user";
export const HUB_USERNAME_HEADER = "x-wordsmith-username";
export const HUB_PROTOCOL_HEADER = "x-wordsmith-protocol";

/** Close code when the account behind a socket is deleted. */
export const CLOSE_ACCOUNT_DELETED = 4001;

/**
 * A listing not refreshed for this long is ignored. Rooms remove their own
 * listing when they start or close; this only guards against a room that
 * never got to.
 */
const STALE_LISTING_MS = 6 * 3600_000;

type RoomRow = {
  code: string;
  mode: OpenRoom["mode"];
  host_id: string;
  host_username: string;
  players: number;
  max: number;
};

type InviteMessage = Extract<ClientMessage, { op: "INVITE" }>;

/** Messages a socket may send: a burst of 20, then 1 per second. */
const RATE_BURST = 20;
const RATE_PER_SECOND = 1;

/** What each socket carries through hibernation (well under the 2 KB limit). */
interface Attachment {
  /** User ID. */
  readonly u: string;
  /** Username, for invites. */
  readonly n: string;
  /** Status set on this socket. */
  readonly s: PresenceStatus;
  /** When `s` was set (epoch ms). */
  readonly t: number;
}

function attachmentOf(ws: WebSocket): Attachment | null {
  try {
    return ws.deserializeAttachment() as Attachment | null;
  } catch {
    return null;
  }
}

/** The status set most recently on any of these sockets; offline if none. */
function latestStatus(attachments: readonly Attachment[]): PresenceStatus {
  let latest: Attachment | null = null;
  for (const a of attachments) if (latest === null || a.t >= latest.t) latest = a;
  return latest?.s ?? "offline";
}

function send(ws: WebSocket, message: ServerMessage): void {
  try {
    ws.send(JSON.stringify(message));
  } catch {
    // Already closing; its close handler tidies up.
  }
}

export class HubDO extends DurableObject<Env> {
  /** Per-socket rate limits. In memory only, so they reset on hibernation, which is fine. */
  private readonly limits = new WeakMap<WebSocket, RateLimiter>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS links (
         user_id   TEXT NOT NULL,
         friend_id TEXT NOT NULL,
         PRIMARY KEY (user_id, friend_id)
       ) WITHOUT ROWID`,
    );
    ctx.storage.sql.exec("CREATE INDEX IF NOT EXISTS links_by_friend ON links (friend_id)");
    ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS rooms (
         code          TEXT PRIMARY KEY,
         mode          TEXT NOT NULL,
         host_id       TEXT NOT NULL,
         host_username TEXT NOT NULL,
         players       INTEGER NOT NULL,
         max           INTEGER NOT NULL,
         updated_at    INTEGER NOT NULL
       ) WITHOUT ROWID`,
    );
    ctx.storage.sql.exec("CREATE INDEX IF NOT EXISTS rooms_by_host ON rooms (host_id)");
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
  }

  // -------------------------------------------------------------------------
  // Connecting
  // -------------------------------------------------------------------------

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/connect" || request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return Response.json({ error: "not_found" }, { status: 404 });
    }
    const uid = request.headers.get(HUB_USER_HEADER);
    const username = request.headers.get(HUB_USERNAME_HEADER);
    if (uid === null || uid === "" || username === null || username === "") {
      return Response.json({ error: "bad_request" }, { status: 400 });
    }

    // The one await: everything after it runs without other events in between.
    const { results } = await this.env.DB.prepare(
      "SELECT friend_id FROM friends WHERE user_id = ?1 AND status = 'accepted'",
    )
      .bind(uid)
      .all<{ friend_id: string }>();

    const before = this.statusOf(uid);
    const pair = new WebSocketPair();
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [uid]);
    const attachment: Attachment = { u: uid, n: username, s: "online", t: Date.now() };
    server.serializeAttachment(attachment);

    this.replaceLinks(
      uid,
      results.map((r) => r.friend_id),
    );
    const now = this.statusOf(uid);
    if (now !== before) this.broadcast(uid, now);

    // The newcomer's snapshot: every online friend, then the open rooms.
    for (const friend of this.friendsOf(uid)) {
      const status = this.statusOf(friend);
      if (status !== "offline") send(server, { op: "PRESENCE", userId: friend, status });
    }
    send(server, { op: "OPEN_ROOMS", rooms: this.openRoomsFor(uid) });

    const protocol = request.headers.get(HUB_PROTOCOL_HEADER);
    const headers = protocol ? { "Sec-WebSocket-Protocol": protocol } : undefined;
    return new Response(null, { status: 101, webSocket: pair[0], headers });
  }

  // -------------------------------------------------------------------------
  // Socket events
  // -------------------------------------------------------------------------

  override async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const me = attachmentOf(ws);
    if (me === null) return;

    let limiter = this.limits.get(ws);
    if (limiter === undefined) {
      limiter = new RateLimiter(RATE_BURST, RATE_PER_SECOND, Date.now());
      this.limits.set(ws, limiter);
    }
    if (!limiter.take(Date.now())) return this.error(ws, "rate_limited");

    const parsed = parseClientMessage(raw);
    if (!parsed.ok) return this.error(ws, parsed.code);
    await this.handle(ws, me, parsed.message);
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    this.gone(ws);
    try {
      // Completes the closing handshake (newer runtimes do this themselves).
      ws.close(1000, "bye");
    } catch {
      // Already closed.
    }
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    this.gone(ws);
  }

  private async handle(ws: WebSocket, me: Attachment, message: ClientMessage): Promise<void> {
    switch (message.op) {
      case "SET_STATUS": {
        const before = this.statusOf(me.u);
        ws.serializeAttachment({ ...me, s: message.status, t: Date.now() } satisfies Attachment);
        const now = this.statusOf(me.u);
        if (now !== before) this.broadcast(me.u, now);
        return;
      }
      case "INVITE":
        return this.invite(ws, me, message);
    }
  }

  /**
   * Relays an invite to the friend's open sockets and, once push is set up
   * (shared/push.md), to each of their phones as well, online or not.
   * `friend_offline` only when it can reach them neither way. Without push
   * there's no D1 read; with it, one (the friend's tokens, and the nickname
   * they gave the inviter for the title), which only holds up the answer
   * when they have no open socket.
   */
  private async invite(ws: WebSocket, me: Attachment, message: InviteMessage): Promise<void> {
    // Only between accepted friends, and without revealing anything
    // about anyone else.
    const to = message.to;
    if (to === me.u || !this.friendsOf(me.u).includes(to)) return this.error(ws, "not_friends");
    const relay: ServerMessage = { op: "INVITE", from: me.u, fromUsername: me.n, code: message.code, mode: message.mode };
    const relayed = this.relay(to, relay);

    const push = fcmSender(this.env);
    if (push === null) {
      if (relayed === 0) this.error(ws, "friend_offline");
      return;
    }
    const notice: InviteNotice = { from: me.u, fromUsername: me.n, code: message.code, mode: message.mode };
    if (relayed > 0) {
      this.ctx.waitUntil(
        this.targetOf(to, me.u).then(({ tokens, nickname }) => pushInvite(push, this.env.DB, tokens, { ...notice, nickname })),
      );
      return;
    }
    const { tokens, nickname } = await this.targetOf(to, me.u);
    // They may have connected while the tokens were being read.
    if (this.relay(to, relay) === 0 && tokens.length === 0) return this.error(ws, "friend_offline");
    if (tokens.length > 0) this.ctx.waitUntil(pushInvite(push, this.env.DB, tokens, { ...notice, nickname }));
  }

  /** Sends to each of a player's open sockets; returns how many there were. */
  private relay(uid: string, message: ServerMessage): number {
    const sockets = this.socketsOf(uid);
    for (const ws of sockets) send(ws, message);
    return sockets.length;
  }

  /**
   * A player's FCM tokens, and the nickname they gave `from`; none if D1
   * can't be read (a notification is best-effort).
   */
  private async targetOf(uid: string, from: string): Promise<{ tokens: string[]; nickname: string | null }> {
    try {
      return await pushTargetOf(this.env.DB, uid, from);
    } catch (err) {
      console.error("reading push tokens failed", err);
      return { tokens: [], nickname: null };
    }
  }

  /** A socket closed or failed: tell friends if that changed the player's presence. */
  private gone(ws: WebSocket): void {
    const me = attachmentOf(ws);
    if (me === null) return;
    // By now the runtime may already have dropped `ws` from getWebSockets(),
    // so "before" is worked out from its attachment plus the others.
    const others = this.attachmentsOf(me.u, ws);
    const before = latestStatus([...others, me]);
    const after = latestStatus(others);
    if (after === "offline") {
      // Tell friends before forgetting who they are.
      this.broadcast(me.u, "offline", ws);
      this.ctx.storage.sql.exec("DELETE FROM links WHERE user_id = ?", me.u);
    } else if (after !== before) {
      this.broadcast(me.u, after, ws);
    }
  }

  // -------------------------------------------------------------------------
  // Called by the Worker (RPC)
  // -------------------------------------------------------------------------

  /**
   * Two players became friends (`accepted`), or stopped being friends.
   * Updates the stored friend lists of whichever of them is connected, and
   * shows each to the other (or shows them going offline).
   */
  async friendshipChanged(a: string, b: string, accepted: boolean): Promise<void> {
    for (const [self, other] of [
      [a, b],
      [b, a],
    ] as const) {
      if (this.socketsOf(self).length === 0) continue;
      if (accepted) {
        this.ctx.storage.sql.exec("INSERT OR IGNORE INTO links (user_id, friend_id) VALUES (?, ?)", self, other);
      } else {
        this.ctx.storage.sql.exec("DELETE FROM links WHERE user_id = ? AND friend_id = ?", self, other);
      }
      // The other's rooms now show (or stop showing) in my list.
      if (this.hostsRooms(other)) this.sendOpenRooms(self);
      const otherStatus = this.statusOf(other);
      if (accepted && otherStatus === "offline") continue;
      for (const ws of this.socketsOf(self)) {
        send(ws, { op: "PRESENCE", userId: other, status: accepted ? otherStatus : "offline" });
      }
    }
  }

  /**
   * A room's entry in the open-rooms directory changed: `listing` while it
   * is joinable, `null` once it starts, fills up or closes. Every connected
   * friend of its host (and of its previous host) gets a fresh OPEN_ROOMS.
   */
  async roomListing(code: string, listing: RoomListing | null): Promise<void> {
    const before = this.ctx.storage.sql
      .exec<{ host_id: string }>("SELECT host_id FROM rooms WHERE code = ?", code)
      .toArray()[0]?.host_id;
    if (listing === null) {
      this.ctx.storage.sql.exec("DELETE FROM rooms WHERE code = ?", code);
    } else {
      this.ctx.storage.sql.exec(
        `INSERT INTO rooms (code, mode, host_id, host_username, players, max, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (code) DO UPDATE SET mode = excluded.mode, host_id = excluded.host_id,
           host_username = excluded.host_username, players = excluded.players, max = excluded.max,
           updated_at = excluded.updated_at`,
        code,
        listing.mode,
        listing.hostId,
        listing.hostUsername,
        listing.players,
        listing.max,
        Date.now(),
      );
    }
    this.ctx.storage.sql.exec("DELETE FROM rooms WHERE updated_at < ?", Date.now() - STALE_LISTING_MS);

    const audience = new Set<string>();
    for (const host of new Set([before, listing?.hostId])) {
      if (host === undefined) continue;
      for (const r of this.ctx.storage.sql.exec<{ user_id: string }>("SELECT user_id FROM links WHERE friend_id = ?", host)) {
        audience.add(r.user_id);
      }
    }
    for (const uid of audience) this.sendOpenRooms(uid);
  }

  /** The open rooms `uid` sees (for tests). */
  async openRooms(uid: string): Promise<OpenRoom[]> {
    return this.openRoomsFor(uid);
  }

  /**
   * A player deleted their account: their friends see them go offline,
   * forget them, and the player's own sockets are closed.
   */
  async userRemoved(uid: string, formerFriends: readonly string[]): Promise<void> {
    const wasOnline = this.statusOf(uid) !== "offline";
    for (const friend of formerFriends) {
      this.ctx.storage.sql.exec("DELETE FROM links WHERE user_id = ? AND friend_id = ?", friend, uid);
      if (!wasOnline) continue;
      for (const ws of this.socketsOf(friend)) send(ws, { op: "PRESENCE", userId: uid, status: "offline" });
    }
    this.ctx.storage.sql.exec("DELETE FROM links WHERE user_id = ?", uid);
    for (const ws of this.socketsOf(uid)) {
      try {
        ws.close(CLOSE_ACCOUNT_DELETED, "account_deleted");
      } catch {
        // Already closed.
      }
    }
  }

  /**
   * A player changed their username (`POST /v1/me/username`). Their open
   * sockets send invites under the new name from now on, and the rooms they
   * host are listed under it: their connected friends get a fresh
   * OPEN_ROOMS. Returns the codes of the rooms they're in (by their status)
   * or host, so the Worker can tell those rooms too.
   */
  async usernameChanged(uid: string, username: string): Promise<string[]> {
    const codes = new Set<string>();
    for (const ws of this.socketsOf(uid)) {
      const me = attachmentOf(ws);
      if (me === null) continue;
      ws.serializeAttachment({ ...me, n: username } satisfies Attachment);
      if (me.s.startsWith("in_room:")) codes.add(me.s.slice("in_room:".length));
    }
    const hosted = this.ctx.storage.sql.exec<{ code: string }>("SELECT code FROM rooms WHERE host_id = ?", uid).toArray();
    if (hosted.length > 0) {
      this.ctx.storage.sql.exec("UPDATE rooms SET host_username = ? WHERE host_id = ?", username, uid);
      for (const r of this.ctx.storage.sql.exec<{ user_id: string }>("SELECT user_id FROM links WHERE friend_id = ?", uid)) {
        this.sendOpenRooms(r.user_id);
      }
    }
    for (const r of hosted) codes.add(r.code);
    return [...codes];
  }

  /** A player's current presence (for tests and, later, rooms). */
  async presenceOf(uid: string): Promise<PresenceStatus> {
    return this.statusOf(uid);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /** Open sockets for a player, leaving out `except`. */
  private socketsOf(uid: string, except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(uid).filter((ws) => ws !== except && ws.readyState === WebSocket.OPEN);
  }

  private attachmentsOf(uid: string, except?: WebSocket): Attachment[] {
    return this.socketsOf(uid, except).flatMap((ws) => attachmentOf(ws) ?? []);
  }

  /** The most recently set status across a player's open sockets, or offline. */
  private statusOf(uid: string, except?: WebSocket): PresenceStatus {
    return latestStatus(this.attachmentsOf(uid, except));
  }

  /** Joinable rooms hosted by `uid`'s friends, newest first. Needs `uid` connected (it reads `links`). */
  private openRoomsFor(uid: string): OpenRoom[] {
    return this.ctx.storage.sql
      .exec<RoomRow>(
        `SELECT r.code, r.mode, r.host_id, r.host_username, r.players, r.max FROM rooms r
           JOIN links l ON l.friend_id = r.host_id
          WHERE l.user_id = ? AND r.updated_at >= ?
          ORDER BY r.updated_at DESC`,
        uid,
        Date.now() - STALE_LISTING_MS,
      )
      .toArray()
      .map((r) => ({ code: r.code, mode: r.mode, hostId: r.host_id, hostUsername: r.host_username, players: r.players, max: r.max }));
  }

  private sendOpenRooms(uid: string): void {
    const sockets = this.socketsOf(uid);
    if (sockets.length === 0) return;
    const rooms = this.openRoomsFor(uid);
    for (const ws of sockets) send(ws, { op: "OPEN_ROOMS", rooms });
  }

  private hostsRooms(uid: string): boolean {
    return this.ctx.storage.sql.exec("SELECT 1 FROM rooms WHERE host_id = ? LIMIT 1", uid).toArray().length > 0;
  }

  private friendsOf(uid: string): string[] {
    return this.ctx.storage.sql
      .exec<{ friend_id: string }>("SELECT friend_id FROM links WHERE user_id = ?", uid)
      .toArray()
      .map((r) => r.friend_id);
  }

  private replaceLinks(uid: string, friends: readonly string[]): void {
    this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec("DELETE FROM links WHERE user_id = ?", uid);
      for (const friend of friends) {
        this.ctx.storage.sql.exec("INSERT OR IGNORE INTO links (user_id, friend_id) VALUES (?, ?)", uid, friend);
      }
    });
  }

  /** Sends a player's presence to each of their friends who's connected. */
  private broadcast(uid: string, status: PresenceStatus, except?: WebSocket): void {
    for (const friend of this.friendsOf(uid)) {
      for (const ws of this.socketsOf(friend, except)) send(ws, { op: "PRESENCE", userId: uid, status });
    }
  }

  private error(ws: WebSocket, code: HubErrorCode): void {
    send(ws, { op: "ERROR", code });
  }
}
