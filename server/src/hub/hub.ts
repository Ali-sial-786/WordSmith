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
 * A player can have several sockets (two phones, or a reconnect that beats
 * the old socket's close). They're online while any is open; their status
 * is the one set most recently on any of them.
 */

import { DurableObject } from "cloudflare:workers";
import type { Env } from "../env";
import {
  parseClientMessage,
  PING,
  PONG,
  RateLimiter,
  type ClientMessage,
  type HubErrorCode,
  type PresenceStatus,
  type ServerMessage,
} from "./protocol";

/** Headers the Worker sets when it forwards an upgrade to the hub. */
export const HUB_USER_HEADER = "x-wordsmith-user";
export const HUB_USERNAME_HEADER = "x-wordsmith-username";
export const HUB_PROTOCOL_HEADER = "x-wordsmith-protocol";

/** Close code when the account behind a socket is deleted. */
export const CLOSE_ACCOUNT_DELETED = 4001;

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
    send(server, { op: "OPEN_ROOMS", rooms: [] });

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
    this.handle(ws, me, parsed.message);
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

  private handle(ws: WebSocket, me: Attachment, message: ClientMessage): void {
    switch (message.op) {
      case "SET_STATUS": {
        const before = this.statusOf(me.u);
        ws.serializeAttachment({ ...me, s: message.status, t: Date.now() } satisfies Attachment);
        const now = this.statusOf(me.u);
        if (now !== before) this.broadcast(me.u, now);
        return;
      }
      case "INVITE": {
        // Only between accepted friends, and without revealing anything
        // about anyone else.
        if (message.to === me.u || !this.friendsOf(me.u).includes(message.to)) return this.error(ws, "not_friends");
        const targets = this.socketsOf(message.to);
        if (targets.length === 0) return this.error(ws, "friend_offline");
        for (const target of targets) {
          send(target, { op: "INVITE", from: me.u, fromUsername: me.n, code: message.code, mode: message.mode });
        }
        return;
      }
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
      const otherStatus = this.statusOf(other);
      if (accepted && otherStatus === "offline") continue;
      for (const ws of this.socketsOf(self)) {
        send(ws, { op: "PRESENCE", userId: other, status: accepted ? otherStatus : "offline" });
      }
    }
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
