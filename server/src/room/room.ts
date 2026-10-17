/**
 * RoomDO: one Durable Object per room code, the referee for its games
 * (shared/room-protocol.md, docs/TECH.md §6). Reached only through the
 * Worker, which verifies tokens and passes the player's identity.
 *
 * - **One thing at a time.** A Durable Object handles events one by one in
 *   arrival order, so the first SUBMIT of a word wins. The only waits are
 *   D1 calls; whatever might have changed during one is checked again after.
 * - **Survives hibernation.** Sockets use the Hibernation API, and every
 *   piece of state that matters is in the DO's own SQLite storage (the
 *   synchronous KV API, cached in memory): the room and its players
 *   (`room`), the round with its answers (`round`), the last results
 *   (`results`), results still to be written to D1 (`award`) and the
 *   planned alarm (`alarm`). Only rate limits live in memory.
 * - **One alarm**, always set to the nearest deadline: the end of the
 *   countdown, the end of the round, a dropped player's rejoin time, the
 *   empty-room and idle closes, and retrying a failed results write. Each
 *   event first catches up on any deadline that has passed, so a late
 *   alarm changes nothing.
 * - **Cheap while idle** (docs/TECH.md §12): no timers, `{"op":"PING"}` is
 *   answered by the runtime, and a quiet room hibernates.
 *
 * The game rules are pure functions in src/rules/ (room.ts, mold.ts,
 * coop-round.ts); this class wires them to sockets, storage, alarms and D1.
 * Versus (M4) adds a mode: its round state and rules next to co-op's, with
 * the lobby, seats, host, timers and lifecycle here shared.
 */

import { DurableObject } from "cloudflare:workers";
import { grantHint, pickPuzzle, recordSeen, spendHint, writeCoopRound, type CoopRoundRecord } from "../db/rooms";
import type { Env } from "../env";
import { RateLimiter, type RoomListing } from "../hub/protocol";
import {
  applyEmberCollected,
  applyHint,
  applySubmit,
  coopResults,
  hintProblem,
  newCoopRound,
  roundSnapshot,
  roundStartFields,
  scoresOf,
  type CoopRound,
  type RoundEndReason,
} from "../rules/coop-round";
import { heatForLevel, type HeatTier } from "../rules/heat";
import { emberKind, type MpPuzzle } from "../rules/mold";
import { isHintUnlocked, type HintKind } from "../rules/progression";
import {
  COUNTDOWN_MS,
  EMPTY_CLOSE_MS,
  freeColor,
  IDLE_CLOSE_MS,
  MAX_PLAYERS,
  MIN_PLAYERS,
  OTHER_BURST,
  OTHER_PER_SECOND,
  pickHost,
  PUZZLE_REPEAT_WINDOW_MS,
  puzzleSizeFor,
  REJOIN_GRACE_MS,
  SubmitLimiter,
  type RoomMode,
  type RoomPhase,
  type Seat,
} from "../rules/room";
import { normalizeWord } from "../rules/words";
import { PROTOCOL_VERSION } from "../version";
import {
  parseClientMessage,
  parseIdentity,
  PING,
  PONG,
  type ClientMessage,
  type HintRequest,
  type LobbyFields,
  type ResultsFields,
  type RoomErrorCode,
  type RoomIdentity,
  type RoomSummary,
  type ServerMessage,
  type WordResultKind,
  type XpBody,
} from "./protocol";

/** Headers the Worker sets when it forwards an upgrade to a room. */
export const ROOM_IDENTITY_HEADER = "x-wordsmith-identity";
export const ROOM_PROTOCOL_HEADER = "x-wordsmith-protocol";

/** Close codes (4000–4099 tell the app not to reconnect). */
export const CLOSE_ROOM_CLOSED = 4000;
export const CLOSE_LEFT = 4002;

/** `lastActivity` is only rewritten when it's at least this old, to save storage writes. */
const ACTIVITY_GRANULARITY_MS = 60_000;
/** Attempts at writing a round's results to D1, and the wait between them (× attempt). */
const MAX_AWARD_ATTEMPTS = 5;
const AWARD_RETRY_MS = 15_000;

// Storage keys.
const ROOM = "room";
const ROUND = "round";
const RESULTS = "results";
const AWARD = "award";
const ALARM = "alarm";

interface Player {
  readonly id: string;
  username: string;
  avatar: string;
  level: number;
  color: number;
  ready: boolean;
  /** Join order: lower joined earlier. */
  joinedAt: number;
  /** While the player has no socket open: when their seat goes. */
  graceUntil: number | null;
  /** Left during a round (LEAVE, or rejoin time ran out): still listed until the round ends. */
  left: boolean;
}

interface Room {
  code: string;
  mode: RoomMode;
  createdAt: number;
  phase: RoomPhase;
  /** `null` only while nobody is in the room. */
  hostId: string | null;
  players: Player[];
  /** Joins so far, for `joinedAt`. */
  joins: number;
  /** Rounds started. */
  rounds: number;
  lastActivity: number;
  /** When the last socket closed, while none is open. */
  emptySince: number | null;
  /** The open-rooms listing last sent to the hub (JSON), or `null` if not listed. */
  listed: string | null;
}

/** A finished round whose results haven't reached D1 (or the players) yet. */
interface PendingAward {
  readonly record: CoopRoundRecord;
  readonly usernames: Readonly<Record<string, string>>;
  attempts: number;
  retryAt: number;
  /** ROUND_END has been sent (with XP, or without it after a failed write). */
  announced: boolean;
}

/** What each socket carries through hibernation. */
interface Attachment {
  /** User ID. */
  readonly u: string;
}

function attachmentOf(ws: WebSocket): Attachment | null {
  try {
    return ws.deserializeAttachment() as Attachment | null;
  } catch {
    return null;
  }
}

function send(ws: WebSocket, message: ServerMessage): void {
  try {
    ws.send(JSON.stringify(message));
  } catch {
    // Already closing; its close handler tidies up.
  }
}

function closeSocket(ws: WebSocket, code: number, reason: string): void {
  try {
    ws.close(code, reason);
  } catch {
    // Already closed.
  }
}

function httpError(status: number, error: string): Response {
  return Response.json({ error }, { status });
}

function seats(room: Room): Seat[] {
  return room.players.map((p) => ({ id: p.id, joinedAt: p.joinedAt, present: !p.left }));
}

export class RoomDO extends DurableObject<Env> {
  /** Storage values by key, as last read or written. */
  private readonly cache = new Map<string, unknown>();
  /** Per-player SUBMIT limits and per-socket limits for everything else. In memory only. */
  private readonly submitLimits = new Map<string, SubmitLimiter>();
  private readonly otherLimits = new WeakMap<WebSocket, RateLimiter>();
  /** Per-player queue of hint-stock writes, so a collected ember is in D1 before the next spend. */
  private readonly stockQueue = new Map<string, Promise<unknown>>();
  /** A START or AGAIN is waiting on D1 for a puzzle. */
  private starting = false;
  /** A results write in flight. */
  private awarding: Promise<void> | null = null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
  }

  // -------------------------------------------------------------------------
  // Storage
  // -------------------------------------------------------------------------

  private read<T>(key: string): T | null {
    if (!this.cache.has(key)) this.cache.set(key, this.ctx.storage.kv.get<T>(key) ?? null);
    return this.cache.get(key) as T | null;
  }

  private write(key: string, value: unknown): void {
    this.cache.set(key, value);
    if (value === null) this.ctx.storage.kv.delete(key);
    else this.ctx.storage.kv.put(key, value);
  }

  private room(): Room | null {
    return this.read<Room>(ROOM);
  }

  private round(): CoopRound | null {
    return this.read<CoopRound>(ROUND);
  }

  // -------------------------------------------------------------------------
  // Called by the Worker (RPC)
  // -------------------------------------------------------------------------

  /**
   * Opens a new room with `creator` as host. Returns false if this code is
   * already in use (the Worker then tries another code).
   *
   * The creator gets their seat straight away, as if they had just
   * dropped: they have the rejoin time to connect.
   */
  async create(code: string, mode: RoomMode, creator: RoomIdentity): Promise<boolean> {
    if (this.room() !== null) return false;
    const now = Date.now();
    const room: Room = {
      code,
      mode,
      createdAt: now,
      phase: "lobby",
      hostId: creator.id,
      players: [
        {
          id: creator.id,
          username: creator.username,
          avatar: creator.avatar,
          level: creator.level,
          color: 0,
          ready: false,
          joinedAt: 0,
          graceUntil: now + REJOIN_GRACE_MS,
          left: false,
        },
      ],
      joins: 1,
      rounds: 0,
      lastActivity: now,
      emptySince: now,
      listed: null,
    };
    this.write(ROOM, room);
    await this.settle();
    return true;
  }

  /** `GET /v1/rooms/:code`, or `null` if there's no such room. */
  async summary(): Promise<RoomSummary | null> {
    await this.catchUp(Date.now());
    await this.settle();
    const room = this.room();
    if (room === null) return null;
    const host = room.players.find((p) => p.id === room.hostId);
    return {
      code: room.code,
      mode: room.mode,
      phase: room.phase,
      host: host === undefined ? null : { id: host.id, username: host.username },
      players: room.players.filter((p) => !p.left).length,
      maxPlayers: MAX_PLAYERS[room.mode],
    };
  }

  // -------------------------------------------------------------------------
  // Joining
  // -------------------------------------------------------------------------

  /**
   * The Worker's forwarded upgrade. Refuses with 404 `room_not_found`,
   * 409 `room_full` or 409 `round_in_progress` (a player already in the
   * room may always come back); otherwise sends WELCOME and SNAPSHOT.
   */
  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/connect" || request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return httpError(404, "not_found");
    }
    const me = parseIdentity(request.headers.get(ROOM_IDENTITY_HEADER));
    if (me === null) return httpError(400, "bad_request");

    const now = Date.now();
    await this.catchUp(now);
    const room = this.room();
    if (room === null) return httpError(404, "room_not_found");

    let player = room.players.find((p) => p.id === me.id);
    if (player === undefined) {
      if (room.players.length >= MAX_PLAYERS[room.mode]) return httpError(409, "room_full");
      if (room.phase === "countdown" || room.phase === "round") return httpError(409, "round_in_progress");
      player = {
        ...me,
        color: freeColor(room.players.map((p) => p.color))!,
        ready: false,
        joinedAt: room.joins++,
        graceUntil: null,
        left: false,
      };
      room.players.push(player);
    } else {
      Object.assign(player, { username: me.username, avatar: me.avatar, level: me.level, graceUntil: null, left: false });
    }
    room.hostId = pickHost(room.hostId, seats(room));
    room.lastActivity = now;
    room.emptySince = null;
    this.write(ROOM, room);

    const pair = new WebSocketPair();
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [me.id]);
    server.serializeAttachment({ u: me.id } satisfies Attachment);
    send(server, { op: "WELCOME", you: me.id, protocol: PROTOCOL_VERSION, serverNow: now });
    send(server, this.snapshot(room, now));
    this.broadcast(this.lobbyMessage(room), server);

    await this.schedule();
    this.ctx.waitUntil(this.syncListing());
    const protocol = request.headers.get(ROOM_PROTOCOL_HEADER);
    return new Response(null, { status: 101, webSocket: pair[0], headers: protocol ? { "Sec-WebSocket-Protocol": protocol } : undefined });
  }

  // -------------------------------------------------------------------------
  // Socket events
  // -------------------------------------------------------------------------

  override async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const me = attachmentOf(ws);
    if (me === null) return;
    const now = Date.now();
    await this.catchUp(now);
    const room = this.room();
    const player = room?.players.find((p) => p.id === me.u);
    if (room === null || player === undefined || player.left) {
      closeSocket(ws, room === null ? CLOSE_ROOM_CLOSED : CLOSE_LEFT, room === null ? "room_closed" : "left");
      return;
    }

    const parsed = parseClientMessage(raw);
    if (!parsed.ok) {
      if (this.allowOther(ws, now)) this.error(ws, "bad_message");
      return;
    }
    const message = parsed.message;
    // SUBMIT has its own limit, with its own answer.
    if (message.op !== "SUBMIT" && !this.allowOther(ws, now)) return;
    if (now - room.lastActivity >= ACTIVITY_GRANULARITY_MS) {
      room.lastActivity = now;
      this.write(ROOM, room);
    }
    await this.handle(ws, room, player, message, now);
    await this.settle();
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    // Reads the socket's attachment before anything waits.
    const gone = this.socketGone(ws);
    // Completes the closing handshake (newer runtimes do this themselves).
    closeSocket(ws, 1000, "bye");
    await gone;
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.socketGone(ws);
  }

  /** A socket closed: if it was the player's last, their rejoin time starts. */
  private async socketGone(ws: WebSocket): Promise<void> {
    const me = attachmentOf(ws);
    const room = this.room();
    if (me === null || room === null) return;
    const now = Date.now();
    const player = room.players.find((p) => p.id === me.u);
    if (player === undefined) return;
    // By now the runtime may already have dropped `ws` from getWebSockets(), or not.
    if (!player.left && this.socketsOf(player.id, ws).length === 0) player.graceUntil = now + REJOIN_GRACE_MS;
    if (this.openSockets(ws).length === 0) room.emptySince ??= now;
    this.write(ROOM, room);
    this.broadcast(this.lobbyMessage(room, ws), ws);
    await this.settle();
  }

  override async alarm(): Promise<void> {
    // The planned time, not the clock, says what's due: an alarm never
    // fires early in production, and tests can run one ahead of time.
    const planned = this.read<number>(ALARM) ?? 0;
    this.write(ALARM, null);
    try {
      await this.catchUp(Math.max(Date.now(), planned));
    } finally {
      await this.settle();
    }
  }

  // -------------------------------------------------------------------------
  // Client messages
  // -------------------------------------------------------------------------

  private async handle(ws: WebSocket, room: Room, player: Player, message: ClientMessage, now: number): Promise<void> {
    switch (message.op) {
      case "READY":
        if (room.phase !== "lobby") return this.error(ws, "wrong_phase");
        if (player.ready !== message.ready) {
          player.ready = message.ready;
          this.write(ROOM, room);
          this.broadcast(this.lobbyMessage(room));
        }
        return;

      case "START":
      case "AGAIN": {
        const from: RoomPhase = message.op === "START" ? "lobby" : "results";
        const award = this.read<PendingAward>(AWARD);
        // AGAIN waits until everyone has the results.
        if (room.phase !== from || (from === "results" && award !== null && !award.announced)) return this.error(ws, "wrong_phase");
        if (room.hostId !== player.id) return this.error(ws, "not_host");
        if (this.connectedPlayers(room).length < MIN_PLAYERS[room.mode]) return this.error(ws, "not_enough_players");
        return this.startRound(ws, from);
      }

      case "SUBMIT":
        return this.submit(ws, room, player, message.word, message.seq, now);

      case "HINT":
        return this.hint(ws, room, player, message.hint, now);

      case "LEAVE":
        this.removePlayer(room, player, now);
        return;

      case "EMOTE":
        this.broadcast({ op: "EMOTE", from: player.id, emote: message.emote });
        return;
    }
  }

  /** START from the lobby, or AGAIN from results: a new puzzle and a countdown. */
  private async startRound(ws: WebSocket, from: RoomPhase): Promise<void> {
    if (this.starting) return; // the host double-tapped; the first one is on its way
    this.starting = true;
    try {
      const room = this.room()!;
      const host = room.players.find((p) => p.id === room.hostId);
      const heat = heatForLevel(host?.level ?? 1);
      const ids = room.players.filter((p) => !p.left).map((p) => p.id);
      let puzzle: MpPuzzle | null = null;
      try {
        puzzle = await pickPuzzle(this.env.DB, {
          heat,
          size: puzzleSizeFor(ids.length),
          playerIds: ids,
          seenSince: Date.now() - PUZZLE_REPEAT_WINDOW_MS,
        });
      } catch (err) {
        console.error("room: choosing a puzzle failed", err);
      }

      // Anything could have happened while D1 answered.
      const now = Date.now();
      const fresh = this.room();
      if (fresh === null || fresh.phase !== from) return;
      if (puzzle === null) return this.error(ws, "no_puzzle");
      const players = fresh.players.filter((p) => !p.left);
      const round = newCoopRound({
        round: fresh.rounds + 1,
        heat,
        matchId: crypto.randomUUID(),
        puzzle,
        playerIds: players.map((p) => p.id),
        startsAt: now + COUNTDOWN_MS,
        rand: Math.random,
      });
      fresh.rounds = round.round;
      fresh.phase = "countdown";
      for (const p of fresh.players) p.ready = false;
      this.write(ROUND, round);
      this.write(RESULTS, null);
      this.write(ROOM, fresh);
      this.broadcast({ op: "ROUND_START", ...roundStartFields(round, now) });
      this.broadcast(this.lobbyMessage(fresh));
      await this.schedule();

      try {
        await recordSeen(this.env.DB, puzzle.id, round.playerIds, now);
      } catch (err) {
        console.error("room: recording puzzle_seen failed", err);
      }
    } finally {
      this.starting = false;
    }
  }

  private async submit(ws: WebSocket, room: Room, player: Player, raw: string, seq: number, now: number): Promise<void> {
    const shown = normalizeWord(raw) ?? raw.trim().toUpperCase().slice(0, 16);
    const reply = (result: WordResultKind, extra: { word?: string; by?: string | null; points?: number } = {}) =>
      send(ws, { op: "WORD_RESULT", seq, word: shown, result, ...extra });

    let limiter = this.submitLimits.get(player.id);
    if (limiter === undefined) {
      limiter = new SubmitLimiter(now);
      this.submitLimits.set(player.id, limiter);
    }
    if (!limiter.take(now)) return reply("rate_limited");
    if (room.phase === "results") return reply("too_late");
    const round = this.round();
    if (room.phase !== "round" || round === null || !round.playerIds.includes(player.id)) return this.error(ws, "wrong_phase");

    const outcome = applySubmit(round, player.id, raw);
    switch (outcome.result) {
      case "invalid":
        limiter.recordInvalid(now);
        return reply("invalid");
      case "already":
        return reply("already", { word: outcome.word, by: outcome.by });
      case "bonus":
        this.write(ROUND, round);
        reply("bonus", { word: outcome.word, points: outcome.points });
        this.broadcast({ op: "BONUS", word: outcome.word, by: player.id, points: outcome.points, scores: scoresOf(round) });
        return;
      case "claimed": {
        let pickup: HintKind | null = null;
        if (outcome.ember !== null) {
          pickup = emberKind(Math.random, player.level);
          applyEmberCollected(round, outcome.ember, player.id, pickup);
        }
        this.write(ROUND, round);
        reply("claimed", { word: outcome.word, points: outcome.points });
        this.broadcast({
          op: "CLAIMED",
          slot: outcome.slot,
          word: outcome.word,
          by: player.id,
          points: outcome.points,
          scores: scoresOf(round),
          auto: outcome.auto,
          ...(pickup === null ? {} : { pickup }),
        });
        // Close the round before waiting on anything, so nothing more counts.
        if (outcome.complete) this.finishRound("complete", now);
        if (pickup !== null) {
          const kind = pickup;
          try {
            await this.stock(player.id, () => grantHint(this.env.DB, player.id, kind, now));
          } catch (err) {
            console.error("room: granting an ember failed", err);
          }
        }
        if (outcome.complete) await this.announceResults();
        return;
      }
    }
  }

  private async hint(ws: WebSocket, room: Room, player: Player, target: HintRequest, now: number): Promise<void> {
    const round = this.round();
    if (room.phase !== "round" || round === null || !round.playerIds.includes(player.id)) return this.error(ws, "wrong_phase");
    if (!isHintUnlocked(target.kind, player.level)) return this.error(ws, "hint_locked");
    if (hintProblem(round, target) !== null) return this.error(ws, "bad_cell");

    let spent = false;
    try {
      spent = await this.stock(player.id, () => spendHint(this.env.DB, player.id, target.kind, now));
    } catch (err) {
      console.error("room: spending a hint failed", err);
    }
    if (!spent) return this.error(ws, "no_hint");

    // The round may have moved on (or the cell filled) while D1 answered: give it back.
    const fresh = this.room();
    const current = this.round();
    if (fresh?.phase !== "round" || current === null || current.matchId !== round.matchId || hintProblem(current, target) !== null) {
      try {
        await this.stock(player.id, () => grantHint(this.env.DB, player.id, target.kind, Date.now()));
      } catch (err) {
        console.error("room: refunding a hint failed", err);
      }
      return this.error(ws, fresh?.phase === "round" ? "bad_cell" : "wrong_phase");
    }

    const outcome = applyHint(current, player.id, target, Math.random);
    if (!outcome.ok) return this.error(ws, outcome.code); // can't happen: checked just above
    this.write(ROUND, current);
    this.broadcast({ op: "REVEAL", by: player.id, kind: target.kind, cells: outcome.cells, auto: outcome.auto });
    if (outcome.complete) {
      this.finishRound("complete", Date.now());
      await this.announceResults();
    }
  }

  /**
   * LEAVE, or a dropped player's rejoin time ran out. In the lobby or
   * results their seat goes at once; during a round they stay listed (not
   * connected) until it ends, keeping their points and XP. The host role
   * moves to whoever joined earliest.
   */
  private removePlayer(room: Room, player: Player, now: number): void {
    if (room.phase === "countdown" || room.phase === "round") {
      player.left = true;
      player.ready = false;
      player.graceUntil = null;
    } else {
      room.players = room.players.filter((p) => p !== player);
    }
    room.hostId = pickHost(room.hostId, seats(room));
    for (const ws of this.socketsOf(player.id)) closeSocket(ws, CLOSE_LEFT, "left");
    if (this.openSockets().length === 0) room.emptySince ??= now;
    this.submitLimits.delete(player.id);
    this.write(ROOM, room);
    this.broadcast(this.lobbyMessage(room));
  }

  // -------------------------------------------------------------------------
  // Deadlines
  // -------------------------------------------------------------------------

  /** Handles every deadline that has passed by `now`, in order. */
  private async catchUp(now: number): Promise<void> {
    for (let guard = 0; guard < 64; guard++) {
      const room = this.room();
      if (room === null) return;
      this.reconcile(room, now);
      const round = this.round();

      if (room.phase === "countdown" && round !== null && now >= round.startsAt) {
        room.phase = "round";
        this.write(ROOM, room);
        this.broadcast(this.lobbyMessage(room));
        continue;
      }
      if (room.phase === "round" && round !== null && now >= round.endsAt) {
        this.finishRound("timeout", now);
        await this.announceResults();
        continue;
      }
      const expired = room.players.find(
        (p) => !p.left && p.graceUntil !== null && now >= p.graceUntil && this.socketsOf(p.id).length === 0,
      );
      if (expired !== undefined) {
        this.removePlayer(room, expired, now);
        continue;
      }
      if ((room.emptySince !== null && now >= room.emptySince + EMPTY_CLOSE_MS) || now >= room.lastActivity + IDLE_CLOSE_MS) {
        return this.closeRoom(now);
      }
      // A failed results write to retry, or one cut off by a restart.
      const award = this.read<PendingAward>(AWARD);
      if (award !== null && now >= award.retryAt && this.awarding === null) {
        await this.announceResults();
        continue;
      }
      return;
    }
  }

  /**
   * Notices sockets that vanished without a close event (after a restart,
   * say): their players' rejoin time starts now.
   */
  private reconcile(room: Room, now: number): void {
    let changed = false;
    for (const p of room.players) {
      if (!p.left && p.graceUntil === null && this.socketsOf(p.id).length === 0) {
        p.graceUntil = now + REJOIN_GRACE_MS;
        changed = true;
      }
    }
    if (room.emptySince === null && this.openSockets().length === 0) {
      room.emptySince = now;
      changed = true;
    }
    if (changed) this.write(ROOM, room);
  }

  private nextDeadline(): number | null {
    const room = this.room();
    if (room === null) return null;
    const deadlines = [room.lastActivity + IDLE_CLOSE_MS];
    if (room.emptySince !== null) deadlines.push(room.emptySince + EMPTY_CLOSE_MS);
    for (const p of room.players) if (!p.left && p.graceUntil !== null) deadlines.push(p.graceUntil);
    const round = this.round();
    if (round !== null && room.phase === "countdown") deadlines.push(round.startsAt);
    if (round !== null && room.phase === "round") deadlines.push(round.endsAt);
    const award = this.read<PendingAward>(AWARD);
    if (award !== null) deadlines.push(award.retryAt);
    return Math.min(...deadlines);
  }

  /** Points the single alarm at the nearest deadline (a storage write only when that changes). */
  private async schedule(): Promise<void> {
    const next = this.nextDeadline();
    if (next === this.read<number>(ALARM)) return;
    this.write(ALARM, next);
    if (next === null) await this.ctx.storage.deleteAlarm();
    else await this.ctx.storage.setAlarm(next);
  }

  /** After any change: the alarm, then the hub's open-rooms listing. */
  private async settle(): Promise<void> {
    await this.schedule();
    await this.syncListing();
  }

  // -------------------------------------------------------------------------
  // Ending rounds and rooms
  // -------------------------------------------------------------------------

  /**
   * Ends the round now (no waiting, so nothing more can count): results
   * phase, players who left are dropped, and the results are queued for
   * D1. {@link announceResults} writes them and sends ROUND_END.
   */
  private finishRound(reason: RoundEndReason, now: number): void {
    const room = this.room();
    const round = this.round();
    if (room === null || round === null || (room.phase !== "round" && room.phase !== "countdown")) return;
    const results = coopResults(round, reason, now);
    const usernames = Object.fromEntries(room.players.map((p) => [p.id, p.username]));
    room.phase = "results";
    room.players = room.players.filter((p) => !p.left);
    room.hostId = pickHost(room.hostId, seats(room));
    const award: PendingAward = {
      record: {
        matchId: round.matchId,
        mode: room.mode,
        code: room.code,
        puzzleId: round.puzzle.id,
        heat: round.heat,
        round: round.round,
        startedAt: round.startsAt,
        endedAt: now,
        results,
      },
      usernames,
      attempts: 0,
      retryAt: now,
      announced: false,
    };
    this.write(AWARD, award);
    this.write(RESULTS, this.resultsFields(award, {}));
    this.write(ROOM, room);
  }

  /**
   * Writes the finished round to D1 (XP, stats, rewards, match rows, in one
   * batch) and sends ROUND_END with everyone's XP. If D1 fails, ROUND_END
   * goes out without XP and the write is retried by the alarm.
   */
  private announceResults(): Promise<void> {
    this.awarding ??= this.writeAward().finally(() => {
      this.awarding = null;
    });
    return this.awarding;
  }

  private async writeAward(): Promise<void> {
    const award = this.read<PendingAward>(AWARD);
    if (award === null) return;
    let xp: Record<string, XpBody> | null = null;
    try {
      xp = await writeCoopRound(this.env.DB, award.record, Date.now());
    } catch (err) {
      console.error(`room ${award.record.code}: writing results failed (attempt ${award.attempts + 1})`, err);
    }

    const now = Date.now();
    const firstTime = !award.announced;
    award.announced = true;
    award.attempts += 1;
    award.retryAt = now + AWARD_RETRY_MS * award.attempts;
    if (xp !== null || award.attempts >= MAX_AWARD_ATTEMPTS) this.write(AWARD, null);
    else this.write(AWARD, award);

    const room = this.room();
    if (room === null) return;
    let levelled = false;
    for (const p of room.players) {
      const level = xp?.[p.id]?.level;
      if (level !== undefined && level !== p.level) {
        p.level = level;
        levelled = true;
      }
    }
    if (levelled) this.write(ROOM, room);
    if (!firstTime || this.round()?.matchId !== award.record.matchId) {
      // A retry: ROUND_END already went out, so just show the new levels.
      if (levelled) this.broadcast(this.lobbyMessage(room));
      return;
    }
    const body = this.resultsFields(award, xp ?? {});
    if (room.phase === "results") this.write(RESULTS, body);
    this.broadcast({ op: "ROUND_END", ...body });
    this.broadcast(this.lobbyMessage(room));
  }

  /** Closes the room: ends any round, closes every socket, clears storage and the hub listing. */
  private async closeRoom(now: number): Promise<void> {
    const room = this.room();
    if (room === null) return;
    this.finishRound("timeout", now);
    if (this.read<PendingAward>(AWARD) !== null) await this.announceResults();
    for (const ws of this.ctx.getWebSockets()) closeSocket(ws, CLOSE_ROOM_CLOSED, "room_closed");
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    this.cache.clear();
    for (const key of [ROOM, ROUND, RESULTS, AWARD, ALARM]) this.cache.set(key, null);
    this.submitLimits.clear();
    if (room.listed !== null) await this.tellHub(room.code, null);
  }

  // -------------------------------------------------------------------------
  // The hub's open-rooms directory
  // -------------------------------------------------------------------------

  /** Joinable rooms are listed for the host's friends; others aren't. */
  private listing(room: Room): RoomListing | null {
    const host = room.players.find((p) => p.id === room.hostId);
    const players = room.players.filter((p) => !p.left).length;
    const max = MAX_PLAYERS[room.mode];
    if (host === undefined || players >= max || (room.phase !== "lobby" && room.phase !== "results")) return null;
    return { mode: room.mode, hostId: host.id, hostUsername: host.username, players, max };
  }

  /** Tells the hub if this room's listing changed since it last heard. Best effort. */
  private async syncListing(): Promise<void> {
    const room = this.room();
    if (room === null) return;
    const listing = this.listing(room);
    const key = listing === null ? null : JSON.stringify(listing);
    if (key === room.listed) return;
    if (await this.tellHub(room.code, listing)) {
      const fresh = this.room();
      if (fresh !== null) {
        fresh.listed = key;
        this.write(ROOM, fresh);
      }
    }
  }

  private async tellHub(code: string, listing: RoomListing | null): Promise<boolean> {
    try {
      await this.env.HUB.get(this.env.HUB.idFromName("global")).roomListing(code, listing);
      return true;
    } catch (err) {
      console.error("room: telling the hub failed", err);
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Messages
  // -------------------------------------------------------------------------

  private heatOf(room: Room): HeatTier {
    const round = this.round();
    if (round !== null && (room.phase === "countdown" || room.phase === "round")) return round.heat;
    const host = room.players.find((p) => p.id === room.hostId);
    return heatForLevel(host?.level ?? 1);
  }

  /** The LOBBY fields; `except` is a socket that is closing. */
  private lobbyFields(room: Room, except?: WebSocket): LobbyFields {
    return {
      code: room.code,
      mode: room.mode,
      phase: room.phase,
      hostId: room.hostId,
      heat: this.heatOf(room),
      players: [...room.players]
        .sort((a, b) => a.joinedAt - b.joinedAt)
        .map((p) => ({
          id: p.id,
          username: p.username,
          avatar: p.avatar,
          level: p.level,
          color: p.color,
          ready: p.ready,
          connected: this.socketsOf(p.id, except).length > 0,
        })),
    };
  }

  private lobbyMessage(room: Room, except?: WebSocket): ServerMessage {
    return { op: "LOBBY", ...this.lobbyFields(room, except) };
  }

  private snapshot(room: Room, now: number): ServerMessage {
    const round = this.round();
    const results = this.read<ResultsFields>(RESULTS);
    return {
      op: "SNAPSHOT",
      lobby: this.lobbyFields(room),
      ...(round !== null && room.phase !== "lobby" ? { round: roundSnapshot(round, now) } : {}),
      ...(results !== null && room.phase === "results" ? { results } : {}),
    };
  }

  private resultsFields(award: PendingAward, xp: Readonly<Record<string, XpBody>>): ResultsFields {
    const { players, ...rest } = award.record.results;
    return {
      ...rest,
      players: players.map((p) => ({
        id: p.id,
        username: award.usernames[p.id] ?? "",
        points: p.points,
        words: p.words,
        longest: p.longest,
        bonus: p.bonus,
      })),
      xp,
    };
  }

  private error(ws: WebSocket, code: RoomErrorCode): void {
    send(ws, { op: "ERROR", code });
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /** A player's open sockets, leaving out `except`. */
  private socketsOf(uid: string, except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(uid).filter((ws) => ws !== except && ws.readyState === WebSocket.OPEN);
  }

  private openSockets(except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets().filter((ws) => ws !== except && ws.readyState === WebSocket.OPEN);
  }

  private connectedPlayers(room: Room): Player[] {
    return room.players.filter((p) => !p.left && this.socketsOf(p.id).length > 0);
  }

  private broadcast(message: ServerMessage, except?: WebSocket): void {
    const text = JSON.stringify(message);
    for (const ws of this.openSockets(except)) {
      try {
        ws.send(text);
      } catch {
        // Closing.
      }
    }
  }

  /** The per-socket limit on messages other than SUBMIT; past it they're dropped. */
  private allowOther(ws: WebSocket, now: number): boolean {
    let limiter = this.otherLimits.get(ws);
    if (limiter === undefined) {
      limiter = new RateLimiter(OTHER_BURST, OTHER_PER_SECOND, now);
      this.otherLimits.set(ws, limiter);
    }
    return limiter.take(now);
  }

  /** Runs a hint-stock write for `uid` after any earlier one for them. */
  private stock<T>(uid: string, write: () => Promise<T>): Promise<T> {
    const before = this.stockQueue.get(uid) ?? Promise.resolve();
    const result = before.then(write, write);
    const tail = result.catch(() => undefined);
    this.stockQueue.set(uid, tail);
    void tail.then(() => {
      if (this.stockQueue.get(uid) === tail) this.stockQueue.delete(uid);
    });
    return result;
  }
}
