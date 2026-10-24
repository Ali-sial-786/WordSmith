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
 *   (`room`), the round with its answers (`round`), a Versus series
 *   (`series`) and its last round's results (`standings`), the last
 *   results (`results`), results still to be written to D1 (`award`), the
 *   latest chat lines (`chat`) and the planned alarm (`alarm`). Only rate
 *   limits live in memory.
 * - **One alarm**, always set to the nearest deadline: the end of the
 *   countdown, the end of the round, a survival melt, the end of the
 *   Versus standings, a dropped player's rejoin time, the empty-room and
 *   idle closes, and retrying a failed results write. Each event first
 *   catches up on any deadline that has passed, so a late alarm changes
 *   nothing.
 * - **Cheap while idle** (docs/TECH.md §12): no timers, `{"op":"PING"}` is
 *   answered by the runtime, and a quiet room hibernates.
 *
 * The game rules are pure functions in src/rules/ (room.ts, mold.ts,
 * coop-round.ts, vs-round.ts); this class wires them to sockets, storage,
 * alarms and D1. The lobby, seats, host, timers, results writes and the
 * room's lifecycle are shared; each mode has its own round handling:
 *
 * - **Co-op:** `lobby → countdown → round → results`, and AGAIN.
 * - **Versus:** `lobby → countdown → round → standings → countdown → … →
 *   results`, a series of rounds on everyone's own copy of the mold. XP
 *   is written once, at the end of the series.
 * - **Survival** (shared/survival.md), a variant of either, chosen with
 *   CONFIG: one heated word at a time per mold (the team's, or each
 *   racer's), with a countdown kept in the round. HEATED follows whatever
 *   completed the last one; a melt (its deadline plus the grace) sends
 *   MELT and ends the round. A countdown pauses while nobody is there to
 *   forge it ({@link RoomDO.syncHeat}). Classic rooms never see any of it.
 */

import { DurableObject } from "cloudflare:workers";
import {
  grantHint,
  pickPuzzle,
  recordSeen,
  spendHint,
  writeCoopRound,
  writeVsSeries,
  type CoopRoundRecord,
  type VsSeriesRecord,
} from "../db/rooms";
import { maskProfanity } from "../account/profanity";
import type { Env } from "../env";
import { RateLimiter, type RoomListing } from "../hub/protocol";
import {
  applyCoopHeat,
  applyCoopMelt,
  applyEmberCollected,
  applyHint,
  applySubmit,
  coopMeltAt,
  coopResults,
  forgedWords,
  hintProblem,
  newCoopRound,
  roundSnapshot,
  roundStartFields,
  scoresOf,
  type CoopRound,
  type RoundEndReason,
  type SlotWord,
} from "../rules/coop-round";
import { chosenHeat, heatForLevel, vsHeat, type HeatTier } from "../rules/heat";
import { emberKind, type MpPuzzle } from "../rules/mold";
import { isHintUnlocked, type HintKind } from "../rules/progression";
import {
  CHAT_BURST,
  CHAT_HISTORY,
  CHAT_PER_SECOND,
  COLORS,
  COOP_NEXT_MS,
  COUNTDOWN_MS,
  EMPTY_CLOSE_MS,
  freeColor,
  IDLE_CLOSE_MS,
  isJoinablePhase,
  isPlayingPhase,
  isVersus,
  MAX_PLAYERS,
  MIN_PLAYERS,
  OTHER_BURST,
  OTHER_PER_SECOND,
  pickHost,
  PUZZLE_REPEAT_WINDOW_MS,
  puzzleSizeFor,
  REJOIN_GRACE_MS,
  rememberPuzzle,
  SubmitLimiter,
  type RoomMode,
  type RoomPhase,
  type Seat,
} from "../rules/room";
import { heatedFields, pauseClock, resumeClock, type HeatClock, type Variant } from "../rules/survival";
import { DEFAULT_TEAM_RULE, MAX_TEAM_SIZE, teamForNewcomer, teamSizes, teamsEven, type TeamId, type TeamRule } from "../rules/teams";
import type { SeriesLength } from "../rules/vs";
import {
  activeRacers,
  applyVsHeat,
  applyVsMelt,
  applyVsPickup,
  applyVsSubmit,
  canRace,
  DEFAULT_SERIES,
  endVsRound,
  markOut,
  newVsRound,
  newVsSeries,
  progressOf,
  seriesDecision,
  stopSeries,
  vsHeatedFor,
  vsNextMelt,
  vsRoundSnapshot,
  vsRoundStartFields,
  vsRoundDone,
  vsSeriesResults,
  watchesRound,
  type VsNextRound,
  type VsRound,
  type VsRoundEndFields,
  type VsRoundEndReason,
  type VsRoundSummary,
  type VsSeries,
  type VsSeriesOutcome,
} from "../rules/vs-round";
import { normalizeWord } from "../rules/words";
import { PROTOCOL_VERSION } from "../version";
import {
  parseClientMessage,
  parseIdentity,
  PING,
  PONG,
  type ChatLine,
  type ClientMessage,
  type HintRequest,
  type LobbyFields,
  type ResultsFields,
  type RoomErrorCode,
  type RoomIdentity,
  type RoomSummary,
  type SeriesEndFields,
  type ServerMessage,
  type VsXpBody,
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
/** Versus: when the next round's puzzle couldn't be read from D1, the standings wait this much longer. */
const NEXT_ROUND_RETRY_MS = 5_000;

// Storage keys.
const ROOM = "room";
const ROUND = "round";
const RESULTS = "results";
const AWARD = "award";
const ALARM = "alarm";
const SERIES = "series";
const STANDINGS = "standings";
const CHAT = "chat";
const KEYS = [ROOM, ROUND, RESULTS, AWARD, ALARM, SERIES, STANDINGS, CHAT];

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
  /**
   * Left mid-game (LEAVE, or rejoin time ran out): still listed until the
   * co-op round or the Versus series ends.
   */
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
  /** Co-op rounds started. */
  rounds: number;
  lastActivity: number;
  /** When the last socket closed, while none is open. */
  emptySince: number | null;
  /** The open-rooms listing last sent to the hub (JSON), or `null` if not listed. */
  listed: string | null;
  /** Versus: the series length (CONFIG). */
  series?: SeriesLength;
  /** The variant the next START or AGAIN plays (CONFIG); classic while absent. */
  variant?: Variant;
  /** The heat the host picked for the next START or AGAIN (CONFIG); `"auto"` while absent. */
  heat?: HeatTier;
  /** The latest puzzles this room has played, newest last (rules/room.ts `RECENT_PUZZLES`). */
  recent?: string[];
  /** Team Versus: each player's team, kept while they're in the room (rules/teams.ts). */
  teams?: Record<string, TeamId>;
  /** Team Versus: how the next series' rounds are won (CONFIG); `"combined"` while absent. */
  rule?: TeamRule;
  /** Co-op, after the host's AGAIN: when the next round's countdown starts, unless everyone is ready sooner. */
  nextAt?: number;
}

/** Where a round's clock stands, whatever the mode. */
interface RoundClock {
  readonly heat: HeatTier;
  readonly startsAt: number;
  readonly endsAt: number;
}

interface AwardProgress {
  attempts: number;
  retryAt: number;
  /** The results have been sent (with XP, or without it after a failed write). */
  announced: boolean;
}

/** A finished co-op round whose results haven't reached D1 (or the players) yet. */
interface CoopPendingAward extends AwardProgress {
  /** Absent in awards stored before Versus existed. */
  readonly kind?: "coop";
  readonly record: CoopRoundRecord;
  readonly usernames: Readonly<Record<string, string>>;
}

/** A finished Versus series whose results haven't reached D1 (or the players) yet. */
interface VsPendingAward extends AwardProgress {
  readonly kind: "vs";
  readonly record: VsSeriesRecord;
  readonly usernames: Readonly<Record<string, string>>;
  /** The series' rounds, for SERIES_END (D1 doesn't keep them). Absent in awards stored before it. */
  readonly history?: readonly VsRoundSummary[];
}

type PendingAward = CoopPendingAward | VsPendingAward;

/** The room's chat: the latest lines, oldest first, and the id the next one gets. */
interface ChatLog {
  next: number;
  lines: ChatLine[];
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

/** Players holding a seat (not left), in join order. */
function seated(room: Room): Player[] {
  return room.players.filter((p) => !p.left).sort((a, b) => a.joinedAt - b.joinedAt);
}

export class RoomDO extends DurableObject<Env> {
  /** Storage values by key, as last read or written. */
  private readonly cache = new Map<string, unknown>();
  /** Per-player SUBMIT and CHAT limits, and per-socket limits for everything else. In memory only. */
  private readonly submitLimits = new Map<string, SubmitLimiter>();
  private readonly chatLimits = new Map<string, RateLimiter>();
  private readonly otherLimits = new WeakMap<WebSocket, RateLimiter>();
  /** Per-player queue of hint-stock writes, so a collected ember is in D1 before the next spend. */
  private readonly stockQueue = new Map<string, Promise<unknown>>();
  /** A round's start (START, AGAIN, or the next Versus round) is waiting on D1 for a puzzle. */
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

  /** The round's clock, in either mode. */
  private clock(): RoundClock | null {
    return this.read<RoundClock>(ROUND);
  }

  /** The co-op round: only in a co-op room. */
  private coopRound(): CoopRound | null {
    return this.read<CoopRound>(ROUND);
  }

  /** The Versus round: only in a Versus room. */
  private vsRound(): VsRound | null {
    return this.read<VsRound>(ROUND);
  }

  private series(): VsSeries | null {
    return this.read<VsSeries>(SERIES);
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
      ...(isVersus(mode) ? { series: DEFAULT_SERIES } : {}),
      ...(mode === "team" ? { teams: { [creator.id]: 0 as TeamId } } : {}),
    };
    this.write(ROOM, room);
    await this.settle();
    return true;
  }

  /**
   * The LiveKit room for this room's video chat, if `userId` holds a seat
   * (`POST /v1/rooms/:code/video`); otherwise `null`. Named after the code
   * and creation time, so a reused code never shares a call.
   */
  async videoRoom(userId: string): Promise<string | null> {
    await this.catchUp(Date.now());
    await this.settle();
    const room = this.room();
    if (room === null || !room.players.some((p) => p.id === userId && !p.left)) return null;
    return `wordsmith-${room.code}-${room.createdAt.toString(36)}`;
  }

  /** `GET /v1/rooms/:code`, or `null` if there's no such room. */
  async summary(userId?: string): Promise<RoomSummary | null> {
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
      seated: userId !== undefined && room.players.some((p) => p.id === userId && !p.left),
    };
  }

  /**
   * A player changed their username (`POST /v1/me/username`): the room
   * shows the new one from the next LOBBY on (and in the open-rooms listing,
   * and in results still to come). Results already sent keep the old name.
   */
  async renamed(userId: string, username: string): Promise<void> {
    await this.catchUp(Date.now());
    const room = this.room();
    const player = room?.players.find((p) => p.id === userId);
    if (room == null || player === undefined) return;
    if (player.username !== username) {
      player.username = username;
      this.write(ROOM, room);
      this.broadcast(this.lobbyMessage(room));
    }
    await this.settle();
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
      if (!isJoinablePhase(room.phase)) return httpError(409, "round_in_progress");
      player = {
        ...me,
        color: freeColor(
          room.players.map((p) => p.color),
          COLORS[room.mode],
        )!,
        ready: false,
        joinedAt: room.joins++,
        graceUntil: null,
        left: false,
      };
      room.players.push(player);
      if (room.mode === "team") {
        const team = teamForNewcomer(room.teams ?? {}, seated(room).filter((p) => p.id !== me.id).map((p) => p.id));
        // Two full teams are six players, which MAX_PLAYERS already turned away.
        (room.teams ??= {})[me.id] = team ?? 0;
      }
    } else {
      // Versus: a racer who left mid-series comes back to watch; they stay out of it.
      Object.assign(player, { username: me.username, avatar: me.avatar, level: me.level, graceUntil: null, left: false });
    }
    // A host who lost the role while away doesn't take it back.
    room.hostId = pickHost(room.hostId, this.seats(room, me.id));
    room.lastActivity = now;
    room.emptySince = null;
    this.write(ROOM, room);

    const pair = new WebSocketPair();
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [me.id]);
    server.serializeAttachment({ u: me.id } satisfies Attachment);
    // Survival: someone is back, so a paused countdown goes on (before the SNAPSHOT shows it).
    const resumed = this.syncHeat(room, now);
    send(server, { op: "WELCOME", you: me.id, protocol: PROTOCOL_VERSION, serverNow: now });
    send(server, this.snapshot(room, now, me.id));
    this.sendHeated(resumed, now);
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
    this.syncHeat(room, now, ws);
    this.broadcast(this.lobbyMessage(room, ws), ws);
    // Everyone still here may be ready for the next round.
    await this.startIfAllReady(room, now);
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

      case "CONFIG": {
        // Co-op has no series to configure, only Team Versus has a rule, and teams play classic rounds.
        if (message.series !== undefined && !isVersus(room.mode)) return this.error(ws, "bad_message");
        if (message.rule !== undefined && room.mode !== "team") return this.error(ws, "bad_message");
        if (message.variant === "survival" && room.mode === "team") return this.error(ws, "bad_message");
        // The series is chosen in the lobby; the variant and heat in the lobby or results, for the next START or AGAIN.
        if (message.series !== undefined ? room.phase !== "lobby" : !isJoinablePhase(room.phase)) return this.error(ws, "wrong_phase");
        if (room.hostId !== player.id) return this.error(ws, "not_host");
        let changed = false;
        if (message.series !== undefined && room.series !== message.series) {
          room.series = message.series;
          changed = true;
        }
        if (message.variant !== undefined && (room.variant ?? "classic") !== message.variant) {
          room.variant = message.variant;
          changed = true;
        }
        if (message.heat !== undefined && (room.heat ?? "auto") !== message.heat) {
          if (message.heat === "auto") delete room.heat;
          else room.heat = message.heat;
          changed = true;
        }
        if (message.rule !== undefined && (room.rule ?? DEFAULT_TEAM_RULE) !== message.rule) {
          room.rule = message.rule;
          changed = true;
        }
        if (changed) {
          this.write(ROOM, room);
          this.broadcast(this.lobbyMessage(room));
        }
        return;
      }

      case "START":
      case "AGAIN": {
        const from: RoomPhase = message.op === "START" ? "lobby" : "results";
        const award = this.read<PendingAward>(AWARD);
        // AGAIN waits until everyone has the results.
        if (room.phase !== from || (from === "results" && award !== null && !award.announced)) return this.error(ws, "wrong_phase");
        if (room.hostId !== player.id) return this.error(ws, "not_host");
        if (this.connectedPlayers(room).length < MIN_PLAYERS[room.mode]) return this.error(ws, "not_enough_players");
        if (room.mode === "team" && !this.teamsEven(room)) return this.error(ws, "uneven_teams");
        if (isVersus(room.mode)) return this.startSeries(ws, from);
        // Co-op's next round waits a little, so nobody is pulled away from the results.
        return from === "results" ? this.waitForNext(room, player, now) : this.startRound(ws, from);
      }

      case "NEXT":
        return this.readyForNext(ws, room, player, now);

      case "TEAM":
        return this.moveToTeam(ws, room, player, message.team, message.id ?? player.id);

      case "SUBMIT":
        if (isVersus(room.mode)) return this.vsSubmit(ws, room, player, message.word, message.seq, now);
        return this.submit(ws, room, player, message.word, message.seq, now);

      case "HINT":
        if (isVersus(room.mode)) return this.error(ws, "no_hints");
        return this.hint(ws, room, player, message.hint, now);

      case "LEAVE":
        this.removePlayer(room, player, now);
        // Leaving may have decided a Versus series, or left only ready players waiting for the next round.
        await this.announceQueued();
        await this.startIfAllReady(room, now);
        return;

      case "EMOTE":
        this.broadcast({ op: "EMOTE", from: player.id, emote: message.emote });
        return;

      case "CHAT":
        return this.chat(ws, player, message.text, now);
    }
  }

  /**
   * TEAM (Team Versus), in the lobby or results: moves `target` (the
   * sender, or anyone if the sender is host) to `team`, unless it's full.
   */
  private moveToTeam(ws: WebSocket, room: Room, player: Player, team: TeamId, target: string): void {
    if (room.mode !== "team") return this.error(ws, "bad_message");
    if (!isJoinablePhase(room.phase)) return this.error(ws, "wrong_phase");
    if (target !== player.id && room.hostId !== player.id) return this.error(ws, "not_host");
    if (!seated(room).some((p) => p.id === target)) return this.error(ws, "not_in_room");
    const teams = (room.teams ??= {});
    if (teams[target] === team) return;
    const others = seated(room).filter((p) => p.id !== target).map((p) => p.id);
    if (teamSizes(teams, others)[team] >= MAX_TEAM_SIZE) return this.error(ws, "team_full");
    teams[target] = team;
    this.write(ROOM, room);
    this.broadcast(this.lobbyMessage(room));
  }

  /**
   * Co-op AGAIN: the next round's countdown starts in COOP_NEXT_MS, or as
   * soon as every connected player is ready; the host already is. Another
   * AGAIN meanwhile changes nothing.
   */
  private async waitForNext(room: Room, host: Player, now: number): Promise<void> {
    if (room.nextAt !== undefined) return;
    room.nextAt = now + COOP_NEXT_MS;
    for (const p of room.players) p.ready = p === host;
    this.write(ROOM, room);
    this.broadcast(this.lobbyMessage(room));
    await this.startIfAllReady(room, now);
  }

  /**
   * NEXT: ready for the next round, during the Versus standings or co-op's
   * wait after AGAIN. Once everyone who'll play it is, it starts.
   */
  private async readyForNext(ws: WebSocket, room: Room, player: Player, now: number): Promise<void> {
    const waiting = room.phase === "standings" || (room.phase === "results" && room.nextAt !== undefined);
    if (!waiting) return this.error(ws, "wrong_phase");
    if (!player.ready) {
      player.ready = true;
      this.write(ROOM, room);
      this.broadcast(this.lobbyMessage(room));
    }
    await this.startIfAllReady(room, now);
  }

  /**
   * Starts the next round now if everyone connected who'll play it is ready
   * (NEXT): in Versus, the next round's racers; in co-op, everyone seated.
   */
  private async startIfAllReady(room: Room, now: number): Promise<void> {
    if (this.starting) return;
    let players: Player[];
    if (room.phase === "standings") {
      const series = this.series();
      const decision = series === null ? null : seriesDecision(series);
      if (series === null || decision === null || decision.over) return;
      players = room.players.filter((p) => decision.next.players.includes(p.id));
    } else if (room.phase === "results" && room.nextAt !== undefined) {
      players = seated(room);
    } else {
      return;
    }
    const here = players.filter((p) => !p.left && this.socketsOf(p.id).length > 0);
    if (here.length === 0 || !here.every((p) => p.ready)) return;
    if (room.phase === "standings") await this.nextVsRound(now);
    else await this.startRound(null, "results");
  }

  /** Team Versus: whether everyone seated is on a team, and both teams are the same size. */
  private teamsEven(room: Room): boolean {
    return teamsEven(room.teams ?? {}, seated(room).map((p) => p.id));
  }

  /** CHAT, in any phase: starred, kept for SNAPSHOT and sent to everyone, the sender too. */
  private chat(ws: WebSocket, player: Player, text: string, now: number): void {
    let limiter = this.chatLimits.get(player.id);
    if (limiter === undefined) {
      limiter = new RateLimiter(CHAT_BURST, CHAT_PER_SECOND, now);
      this.chatLimits.set(player.id, limiter);
    }
    if (!limiter.take(now)) return this.error(ws, "chat_limit");
    const log = this.read<ChatLog>(CHAT) ?? { next: 1, lines: [] };
    const line: ChatLine = { id: log.next, from: player.id, username: player.username, text: maskProfanity(text), at: now };
    this.write(CHAT, { next: log.next + 1, lines: [...log.lines, line].slice(-CHAT_HISTORY) } satisfies ChatLog);
    this.broadcast({ op: "CHAT", ...line });
  }

  /**
   * LEAVE, or a dropped player's rejoin time ran out. In the lobby or
   * results their seat goes at once; mid-game they stay listed (not
   * connected) until the co-op round or Versus series ends, keeping their
   * points or wins, and XP. If they were host, the role moves to whoever
   * joined earliest among those connected, so nobody is left waiting on a
   * host who isn't there. In Versus a racer who goes mid-series is out of
   * it, which may decide it ({@link racerOut}).
   */
  private removePlayer(room: Room, player: Player, now: number): void {
    const midGame = isPlayingPhase(room.phase);
    if (midGame) {
      player.left = true;
      player.ready = false;
      player.graceUntil = null;
    } else {
      room.players = room.players.filter((p) => p !== player);
      if (room.teams !== undefined) delete room.teams[player.id];
    }
    room.hostId = pickHost(room.hostId, this.seats(room));
    for (const ws of this.socketsOf(player.id)) closeSocket(ws, CLOSE_LEFT, "left");
    if (this.openSockets().length === 0) room.emptySince ??= now;
    this.submitLimits.delete(player.id);
    this.chatLimits.delete(player.id);
    this.write(ROOM, room);
    this.syncHeat(room, now);
    this.broadcast(this.lobbyMessage(room));
    if (isVersus(room.mode) && midGame) this.racerOut(room, player.id, now);
  }

  // -------------------------------------------------------------------------
  // Co-op
  // -------------------------------------------------------------------------

  /** START from the lobby, or AGAIN from results: a new puzzle and a countdown. */
  /** `ws` is the host's, for errors; `null` when co-op's wait after AGAIN is over. */
  private async startRound(ws: WebSocket | null, from: RoomPhase): Promise<void> {
    if (this.starting) return; // the host double-tapped; the first one is on its way
    this.starting = true;
    try {
      const room = this.room()!;
      const heat = this.nextHeat(room);
      const ids = seated(room).map((p) => p.id);
      let puzzle: MpPuzzle | null = null;
      try {
        puzzle = await pickPuzzle(this.env.DB, {
          heat,
          size: puzzleSizeFor(ids.length),
          playerIds: ids,
          seenSince: Date.now() - PUZZLE_REPEAT_WINDOW_MS,
          avoid: room.recent ?? [],
        });
      } catch (err) {
        console.error("room: choosing a puzzle failed", err);
      }

      // Anything could have happened while D1 answered.
      const now = Date.now();
      const fresh = this.room();
      if (fresh === null || fresh.phase !== from) return;
      if (puzzle === null) {
        // The host can try again; the wait doesn't go round and round.
        if (fresh.nextAt !== undefined) {
          delete fresh.nextAt;
          for (const p of fresh.players) p.ready = false;
          this.write(ROOM, fresh);
          this.broadcast(this.lobbyMessage(fresh));
        }
        return ws === null ? this.broadcast({ op: "ERROR", code: "no_puzzle" }) : this.error(ws, "no_puzzle");
      }
      const players = fresh.players.filter((p) => !p.left);
      const round = newCoopRound({
        round: fresh.rounds + 1,
        heat,
        matchId: crypto.randomUUID(),
        puzzle,
        playerIds: players.map((p) => p.id),
        startsAt: now + COUNTDOWN_MS,
        rand: Math.random,
        variant: fresh.variant,
      });
      fresh.rounds = round.round;
      fresh.phase = "countdown";
      delete fresh.nextAt;
      fresh.recent = rememberPuzzle(fresh.recent ?? [], puzzle.id);
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

    const limiter = this.submitLimiter(player.id, now);
    if (!limiter.take(now)) return reply("rate_limited");
    if (room.phase === "results") return reply("too_late");
    const round = this.coopRound();
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
        // Survival: the claim (or a crossing it completed) may have saved the heated word.
        const heated = applyCoopHeat(round, now);
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
        if (heated) this.sendHeated([null], now);
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
    const round = this.coopRound();
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

    // Survival: the heated word may have melted while D1 answered.
    if (round.survival !== undefined) await this.catchUp(Date.now());
    // The round may have moved on (or the cell filled) while D1 answered: give it back.
    const fresh = this.room();
    const current = this.coopRound();
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
    const at = Date.now();
    // Survival: letters a hint shows can complete the heated word, which counts as saved.
    const heated = applyCoopHeat(current, at);
    this.write(ROUND, current);
    this.broadcast({ op: "REVEAL", by: player.id, kind: target.kind, cells: outcome.cells, auto: outcome.auto });
    if (heated) this.sendHeated([null], at);
    if (outcome.complete) {
      this.finishRound("complete", at);
      await this.announceResults();
    }
  }

  /**
   * Ends the co-op round now (no waiting, so nothing more can count):
   * results phase, players who left are dropped, and the results are
   * queued for D1. {@link announceResults} writes them and sends ROUND_END.
   */
  private finishRound(reason: RoundEndReason, now: number): void {
    const room = this.room();
    const round = this.coopRound();
    if (room === null || round === null || (room.phase !== "round" && room.phase !== "countdown")) return;
    const results = coopResults(round, reason, now);
    const usernames = Object.fromEntries(room.players.map((p) => [p.id, p.username]));
    room.phase = "results";
    room.players = room.players.filter((p) => !p.left);
    room.hostId = pickHost(room.hostId, this.seats(room));
    const award: CoopPendingAward = {
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
        forged: forgedWords(round),
      },
      usernames,
      attempts: 0,
      // Written straight away by announceResults(); this is only for a write cut off by a restart.
      retryAt: now + AWARD_RETRY_MS,
      announced: false,
    };
    this.write(AWARD, award);
    this.write(RESULTS, this.resultsFields(award, {}));
    this.write(ROOM, room);
  }

  // -------------------------------------------------------------------------
  // Versus
  // -------------------------------------------------------------------------

  /** START from the lobby, or AGAIN from results: a new series of the room's length, and round 1's countdown. */
  private async startSeries(ws: WebSocket, from: RoomPhase): Promise<void> {
    if (this.starting) return; // the host double-tapped; the first one is on its way
    this.starting = true;
    try {
      const room = this.room()!;
      const heat = this.nextHeat(room);
      let puzzle: MpPuzzle | null = null;
      try {
        puzzle = await pickPuzzle(this.env.DB, {
          heat,
          size: 1,
          playerIds: seated(room).map((p) => p.id),
          seenSince: Date.now() - PUZZLE_REPEAT_WINDOW_MS,
          avoid: room.recent ?? [],
        });
      } catch (err) {
        console.error("room: choosing a puzzle failed", err);
      }

      // Anything could have happened while D1 answered.
      const now = Date.now();
      const fresh = this.room();
      if (fresh === null || fresh.phase !== from) return;
      if (puzzle === null) return this.error(ws, "no_puzzle");
      if (this.connectedPlayers(fresh).length < MIN_PLAYERS[fresh.mode]) return this.error(ws, "not_enough_players");
      if (fresh.mode === "team" && !this.teamsEven(fresh)) return this.error(ws, "uneven_teams");
      const racers = seated(fresh).map((p) => p.id);
      const series = newVsSeries({
        matchId: crypto.randomUUID(),
        length: fresh.series ?? DEFAULT_SERIES,
        heat,
        racerIds: racers,
        startedAt: now + COUNTDOWN_MS,
        ...(fresh.mode === "team"
          ? { teams: { rule: fresh.rule ?? DEFAULT_TEAM_RULE, of: { ...fresh.teams } } }
          : { variant: fresh.variant }),
      });
      for (const p of fresh.players) p.ready = false;
      this.write(STANDINGS, null);
      this.write(RESULTS, null);
      this.beginVsRound(fresh, series, puzzle, { round: 1, suddenDeath: false, players: racers }, now);
      await this.schedule();

      try {
        await recordSeen(this.env.DB, puzzle.id, racers, now);
      } catch (err) {
        console.error("room: recording puzzle_seen failed", err);
      }
    } finally {
      this.starting = false;
    }
  }

  /** The standings are over: the next round's countdown, once D1 has given a puzzle for it. */
  private async nextVsRound(now: number): Promise<void> {
    if (this.starting) return;
    this.starting = true;
    try {
      const series = this.series()!;
      const before = this.room()!;
      let puzzle: MpPuzzle | null = null;
      try {
        // Everyone seated sees the answers at the end, watchers included (sudden death, or out of the series).
        puzzle = await pickPuzzle(this.env.DB, {
          heat: series.heat,
          size: 1,
          playerIds: seated(before).map((p) => p.id),
          seenSince: Date.now() - PUZZLE_REPEAT_WINDOW_MS,
          avoid: before.recent ?? [],
        });
      } catch (err) {
        console.error("room: choosing a puzzle failed", err);
      }

      const at = Math.max(now, Date.now());
      const room = this.room();
      const fresh = this.series();
      if (room === null || room.phase !== "standings" || fresh === null || fresh.matchId !== series.matchId) return;
      const decision = seriesDecision(fresh);
      if (decision.over) {
        // Players leaving already ends a series at once, so this is only a safety net.
        this.endSeries(room, fresh, decision, at);
        await this.announceResults();
        return;
      }
      if (puzzle === null) {
        fresh.standingsEndsAt = at + NEXT_ROUND_RETRY_MS;
        this.write(SERIES, fresh);
        return;
      }
      this.beginVsRound(room, fresh, puzzle, decision.next, at);
      await this.schedule();

      try {
        await recordSeen(this.env.DB, puzzle.id, seated(room).map((p) => p.id), at);
      } catch (err) {
        console.error("room: recording puzzle_seen failed", err);
      }
    } finally {
      this.starting = false;
    }
  }

  /** A Versus round's countdown: everyone gets ROUND_START, with the same puzzle and letters. */
  private beginVsRound(room: Room, series: VsSeries, puzzle: MpPuzzle, next: VsNextRound, now: number): void {
    const round = newVsRound({
      round: next.round,
      suddenDeath: next.suddenDeath,
      heat: series.heat,
      puzzle,
      playerIds: next.players,
      startsAt: now + COUNTDOWN_MS,
      rand: Math.random,
      variant: series.variant,
    });
    series.standingsEndsAt = null;
    room.phase = "countdown";
    room.recent = rememberPuzzle(room.recent ?? [], puzzle.id);
    // Ready (NEXT) was for this round.
    for (const p of room.players) p.ready = false;
    this.write(ROUND, round);
    this.write(SERIES, series);
    this.write(ROOM, room);
    // Survival: a racer still away from the standings starts with their countdown paused.
    this.syncHeat(room, now);
    this.broadcast({ op: "ROUND_START", ...vsRoundStartFields(round, series, Date.now()) });
    this.broadcast(this.lobbyMessage(room));
  }

  private async vsSubmit(ws: WebSocket, room: Room, player: Player, raw: string, seq: number, now: number): Promise<void> {
    const shown = normalizeWord(raw) ?? raw.trim().toUpperCase().slice(0, 16);
    const reply = (result: WordResultKind, extra: { word?: string; slot?: number; auto?: readonly SlotWord[]; pickup?: HintKind } = {}) =>
      send(ws, { op: "WORD_RESULT", seq, word: shown, result, ...extra });

    const limiter = this.submitLimiter(player.id, now);
    if (!limiter.take(now)) return reply("rate_limited");
    if (room.phase === "standings" || room.phase === "results") return reply("too_late");
    const round = this.vsRound();
    const series = this.series();
    if (room.phase !== "round" || round === null || series === null) return this.error(ws, "wrong_phase");
    if (!round.playerIds.includes(player.id) || !canRace(series, player.id)) return this.error(ws, "not_playing");

    const outcome = applyVsSubmit(round, player.id, raw);
    switch (outcome.result) {
      case "invalid":
        limiter.recordInvalid(now);
        return reply("invalid");
      case "already":
        return reply("already", { word: outcome.word });
      case "bonus":
        this.write(ROUND, round);
        return reply("bonus", { word: outcome.word });
      case "claimed": {
        let pickup: HintKind | null = null;
        if (outcome.ember !== null) {
          pickup = emberKind(Math.random, player.level);
          applyVsPickup(round, player.id, outcome.ember, pickup);
        }
        // Survival: the claim (or a crossing it completed) may have saved this racer's heated word.
        const heated = applyVsHeat(round, player.id, now);
        this.write(ROUND, round);
        reply("claimed", { word: outcome.word, slot: outcome.slot, auto: outcome.auto, ...(pickup === null ? {} : { pickup }) });
        this.sendProgress(round, series, player.id);
        if (heated) this.sendHeated([player.id], now);
        // Team Versus `combined` goes on until a whole team has finished.
        if (outcome.complete && vsRoundDone(series, round)) {
          this.finishVsRound("finished", now);
          await this.announceQueued();
        }
        return;
      }
    }
  }

  /**
   * Ends the Versus round now (no waiting, so nothing more counts) and
   * sends ROUND_END: then the standings, or the results if the series is
   * over (or `stop`: the room is closing). {@link announceResults} then
   * writes the series and sends SERIES_END.
   */
  private finishVsRound(reason: VsRoundEndReason, now: number, stop = false): void {
    const room = this.room();
    const round = this.vsRound();
    const series = this.series();
    if (room === null || round === null || series === null || room.phase !== "round") return;
    const end = endVsRound(series, round, reason, now, stop);
    this.write(STANDINGS, end.fields);
    this.broadcast({ op: "ROUND_END", ...end.fields });
    if (end.outcome !== null) return this.endSeries(room, series, end.outcome, now);
    room.phase = "standings";
    series.standingsEndsAt = end.fields.standingsEndsAt;
    this.write(SERIES, series);
    this.write(ROOM, room);
    this.broadcast(this.lobbyMessage(room));
  }

  /**
   * A racer left mid-series (LEAVE, or their rejoin time ran out): they're
   * out. If that decides the series (one racer left, say), it ends now: a
   * round in play is resolved first; a countdown's round never started, so
   * it doesn't count.
   */
  private racerOut(room: Room, id: string, now: number): void {
    const series = this.series();
    if (series === null || !markOut(series, id)) return;
    this.write(SERIES, series);
    const decision = seriesDecision(series);
    if (!decision.over) return;
    if (room.phase === "round") return this.finishVsRound("timeout", now, true);
    this.endSeries(room, series, decision, now);
  }

  /** The room is closing mid-series: it ends here, decided or not. */
  private stopSeriesNow(room: Room, now: number): void {
    if (room.phase === "round") return this.finishVsRound("timeout", now, true);
    const series = this.series();
    if (series !== null && isPlayingPhase(room.phase)) this.endSeries(room, series, stopSeries(series), now);
  }

  /**
   * The series is over: results phase, players who left are dropped (they
   * stay on the podium and get their XP), and the results are queued for
   * D1. {@link announceResults} writes them and sends SERIES_END.
   */
  private endSeries(room: Room, series: VsSeries, outcome: VsSeriesOutcome, now: number): void {
    const results = vsSeriesResults(series, outcome);
    const usernames = Object.fromEntries(room.players.map((p) => [p.id, p.username]));
    series.standingsEndsAt = null;
    room.phase = "results";
    room.players = room.players.filter((p) => !p.left);
    for (const p of room.players) p.ready = false;
    if (room.teams !== undefined) {
      room.teams = Object.fromEntries(Object.entries(room.teams).filter(([id]) => room.players.some((p) => p.id === id)));
    }
    room.hostId = pickHost(room.hostId, this.seats(room));
    const award: VsPendingAward = {
      kind: "vs",
      record: {
        matchId: series.matchId,
        code: room.code,
        heat: series.heat,
        length: series.length,
        startedAt: series.startedAt,
        endedAt: now,
        results,
        forged: series.forged ?? {},
        ...(series.variant === undefined ? {} : { variant: series.variant }),
        ...(series.teams === undefined ? {} : { rule: series.teams.rule }),
      },
      usernames,
      history: series.history ?? [],
      attempts: 0,
      // Written straight away by announceResults(); this is only for a write cut off by a restart.
      retryAt: now + AWARD_RETRY_MS,
      announced: false,
    };
    this.write(AWARD, award);
    this.write(RESULTS, this.seriesEndFields(award, {}));
    this.write(SERIES, series);
    this.write(ROOM, room);
  }

  // -------------------------------------------------------------------------
  // Deadlines
  // -------------------------------------------------------------------------

  /** Handles every deadline that has passed by `now`, in order. */
  private async catchUp(now: number): Promise<void> {
    // One results write per pass: a failed one is retried by a later alarm,
    // even when `now` is ahead of the clock its retry time was set by.
    let wroteAward = false;
    for (let guard = 0; guard < 64; guard++) {
      const room = this.room();
      if (room === null) return;
      this.reconcile(room, now);
      const clock = this.clock();

      if (room.phase === "countdown" && clock !== null && now >= clock.startsAt) {
        room.phase = "round";
        this.write(ROOM, room);
        this.broadcast(this.lobbyMessage(room));
        continue;
      }
      // Survival: a heated word melts at its deadline plus the grace, unless the round's safety cap comes first.
      const melt = room.phase === "round" && clock !== null ? this.nextMelt(room) : null;
      if (melt !== null && clock !== null && now >= melt.at && melt.at <= clock.endsAt && this.melt(room, melt.id, now)) {
        if (await this.announceQueued()) wroteAward = true;
        continue;
      }
      if (room.phase === "round" && clock !== null && now >= clock.endsAt) {
        if (isVersus(room.mode)) {
          this.finishVsRound("timeout", now);
          if (await this.announceQueued()) wroteAward = true;
        } else {
          this.finishRound("timeout", now);
          await this.announceResults();
          wroteAward = true;
        }
        continue;
      }
      const standingsEnd = room.phase === "standings" ? this.series()?.standingsEndsAt : null;
      if (standingsEnd != null && now >= standingsEnd && !this.starting) {
        await this.nextVsRound(now);
        continue;
      }
      // Co-op: the wait after AGAIN is over.
      if (room.phase === "results" && room.nextAt !== undefined && now >= room.nextAt && !this.starting) {
        await this.startRound(null, "results");
        if (this.room()?.phase === "results") return; // no puzzle: the host can try again
        continue;
      }
      const expired = room.players.find(
        (p) => !p.left && p.graceUntil !== null && now >= p.graceUntil && this.socketsOf(p.id).length === 0,
      );
      if (expired !== undefined) {
        this.removePlayer(room, expired, now);
        if (await this.announceQueued()) wroteAward = true;
        continue;
      }
      if ((room.emptySince !== null && now >= room.emptySince + EMPTY_CLOSE_MS) || now >= room.lastActivity + IDLE_CLOSE_MS) {
        return this.closeRoom(now);
      }
      // A failed results write to retry, or one cut off by a restart.
      const award = this.read<PendingAward>(AWARD);
      if (award !== null && now >= award.retryAt && this.awarding === null && !wroteAward) {
        await this.announceResults();
        wroteAward = true;
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
    this.sendHeated(this.syncHeat(room, now), now);
  }

  private nextDeadline(): number | null {
    const room = this.room();
    if (room === null) return null;
    const deadlines = [room.lastActivity + IDLE_CLOSE_MS];
    if (room.emptySince !== null) deadlines.push(room.emptySince + EMPTY_CLOSE_MS);
    for (const p of room.players) if (!p.left && p.graceUntil !== null) deadlines.push(p.graceUntil);
    const clock = this.clock();
    if (clock !== null && room.phase === "countdown") deadlines.push(clock.startsAt);
    if (clock !== null && room.phase === "round") deadlines.push(clock.endsAt);
    const melt = clock !== null && room.phase === "round" ? this.nextMelt(room) : null;
    if (melt !== null) deadlines.push(melt.at);
    // Not while the next round's puzzle is on its way: its caller reschedules afterwards.
    const standingsEnd = room.phase === "standings" && !this.starting ? this.series()?.standingsEndsAt : null;
    if (standingsEnd != null) deadlines.push(standingsEnd);
    if (room.phase === "results" && room.nextAt !== undefined && !this.starting) deadlines.push(room.nextAt);
    // Not while a write is in flight: its own caller reschedules afterwards.
    const award = this.read<PendingAward>(AWARD);
    if (award !== null && this.awarding === null) deadlines.push(award.retryAt);
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
  // Survival (shared/survival.md)
  // -------------------------------------------------------------------------

  /**
   * Pauses a countdown while nobody is there to forge it, and resumes it
   * (its deadline moved on by the pause) when someone is back. Co-op: the
   * team's, while no player is connected. Versus: each racer's own, while
   * they're away; a racer out of the series can't melt, so theirs is left
   * alone. `except` is a socket that is closing. Returns the countdowns
   * that resumed, for {@link sendHeated}.
   */
  private syncHeat(room: Room, now: number, except?: WebSocket): (string | null)[] {
    if (room.phase !== "countdown" && room.phase !== "round") return [];
    const resumed: (string | null)[] = [];
    let changed = false;
    const sync = (clock: HeatClock, whose: string | null, here: boolean) => {
      if (here && resumeClock(clock, now)) {
        resumed.push(whose);
        changed = true;
      } else if (!here && pauseClock(clock, now)) {
        changed = true;
      }
    };
    if (isVersus(room.mode)) {
      const round = this.vsRound();
      const series = this.series();
      if (round?.survival === undefined || round.survival.melted !== null || series === null) return [];
      for (const id of round.playerIds) {
        const clock = round.survival.clocks[id];
        if (clock !== undefined && canRace(series, id)) sync(clock, id, this.socketsOf(id, except).length > 0);
      }
      if (changed) this.write(ROUND, round);
    } else {
      const round = this.coopRound();
      if (round?.survival === undefined || round.survival.melted !== null) return [];
      sync(round.survival.clock, null, round.playerIds.some((id) => this.socketsOf(id, except).length > 0));
      if (changed) this.write(ROUND, round);
    }
    return resumed;
  }

  /**
   * HEATED for countdowns that changed or resumed: `null` is the co-op
   * team's (to everyone), an id is that racer's own (to them only).
   * Nothing for a mold with nothing left to heat.
   */
  private sendHeated(whose: readonly (string | null)[], now: number): void {
    for (const id of whose) {
      if (id === null) {
        const round = this.coopRound();
        const fields = round?.survival === undefined ? null : heatedFields(round.survival.clock, now);
        if (fields !== null) this.broadcast({ op: "HEATED", ...fields });
      } else {
        const round = this.vsRound();
        const fields = round === null ? null : vsHeatedFor(round, id, now);
        if (fields !== null) for (const ws of this.socketsOf(id)) send(ws, { op: "HEATED", ...fields });
      }
    }
  }

  /** The round's next melt (deadline plus grace), and on whose mold (`null`: the co-op team's). `null` if none is coming. */
  private nextMelt(room: Room): { readonly at: number; readonly id: string | null } | null {
    if (isVersus(room.mode)) {
      const round = this.vsRound();
      const series = this.series();
      return round === null || series === null ? null : vsNextMelt(round, activeRacers(series));
    }
    const round = this.coopRound();
    const at = round === null ? null : coopMeltAt(round);
    return at === null ? null : { at, id: null };
  }

  /**
   * The heated word on `id`'s mold (`null`: the team's) melted: MELT to
   * everyone, then the round ends `melted` (co-op: ROUND_END once the
   * results are written; Versus: ROUND_END now). False if nothing melted.
   */
  private melt(room: Room, id: string | null, now: number): boolean {
    if (isVersus(room.mode)) {
      const round = this.vsRound();
      if (round === null || id === null || !applyVsMelt(round, id)) return false;
      this.write(ROUND, round);
      this.broadcast({ op: "MELT", slot: round.survival!.melted!.slot, id });
      this.finishVsRound("melted", now);
      return true;
    }
    const round = this.coopRound();
    const slot = round === null ? null : applyCoopMelt(round);
    if (slot === null) return false;
    this.write(ROUND, round);
    this.broadcast({ op: "MELT", slot });
    this.finishRound("melted", now);
    return true;
  }

  // -------------------------------------------------------------------------
  // Results and closing
  // -------------------------------------------------------------------------

  /**
   * Writes the finished co-op round or Versus series to D1 (XP, stats,
   * rewards, match rows, in one batch) and sends ROUND_END (co-op) or
   * SERIES_END (Versus) with everyone's XP. If D1 fails, it goes out
   * without XP and the write is retried by the alarm.
   */
  private announceResults(): Promise<void> {
    this.awarding ??= this.writeAward().finally(() => {
      this.awarding = null;
    });
    return this.awarding;
  }

  /** Announces results that were just queued and haven't gone out yet. True if there were some. */
  private async announceQueued(): Promise<boolean> {
    const award = this.read<PendingAward>(AWARD);
    if (award === null || award.announced) return false;
    await this.announceResults();
    return true;
  }

  private async writeAward(): Promise<void> {
    const award = this.read<PendingAward>(AWARD);
    if (award === null) return;
    let coopXp: Record<string, XpBody> | null = null;
    let vsXp: Record<string, VsXpBody> | null = null;
    try {
      if (award.kind === "vs") vsXp = await writeVsSeries(this.env.DB, award.record, Date.now());
      else coopXp = await writeCoopRound(this.env.DB, award.record, Date.now());
    } catch (err) {
      console.error(`room ${award.record.code}: writing results failed (attempt ${award.attempts + 1})`, err);
    }
    const xp: Readonly<Record<string, XpBody>> | null = vsXp ?? coopXp;

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

    let body: ResultsFields | SeriesEndFields;
    let message: ServerMessage;
    let current: boolean;
    if (award.kind === "vs") {
      const fields = this.seriesEndFields(award, vsXp ?? {});
      body = fields;
      message = { op: "SERIES_END", ...fields };
      current = room.phase === "results" && this.series()?.matchId === award.record.matchId;
    } else {
      const fields = this.resultsFields(award, coopXp ?? {});
      body = fields;
      message = { op: "ROUND_END", ...fields };
      current = room.phase === "results" && this.coopRound()?.matchId === award.record.matchId;
    }
    if (!firstTime || !current) {
      // A retry: the results already went out, so just keep them for
      // SNAPSHOTs and show the new levels.
      if (current && xp !== null) this.write(RESULTS, body);
      if (levelled) this.broadcast(this.lobbyMessage(room));
      return;
    }
    this.write(RESULTS, body);
    this.broadcast(message);
    this.broadcast(this.lobbyMessage(room));
  }

  /** Closes the room: ends any round or series, closes every socket, clears storage and the hub listing. */
  private async closeRoom(now: number): Promise<void> {
    const room = this.room();
    if (room === null) return;
    if (isVersus(room.mode)) this.stopSeriesNow(room, now);
    else this.finishRound("timeout", now);
    if (this.read<PendingAward>(AWARD) !== null) await this.announceResults();
    for (const ws of this.ctx.getWebSockets()) closeSocket(ws, CLOSE_ROOM_CLOSED, "room_closed");
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    this.cache.clear();
    for (const key of KEYS) this.cache.set(key, null);
    this.submitLimits.clear();
    this.chatLimits.clear();
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
    if (host === undefined || players >= max || !isJoinablePhase(room.phase)) return null;
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

  /** What a heat of `"auto"` gives with the room as it is: co-op, the host's level; Versus, the median level of the seated players. */
  private autoHeat(room: Room): HeatTier {
    if (isVersus(room.mode)) {
      const levels = seated(room).map((p) => p.level);
      return levels.length === 0 ? heatForLevel(1) : vsHeat(levels);
    }
    const host = room.players.find((p) => p.id === room.hostId);
    return heatForLevel(host?.level ?? 1);
  }

  /** The heat the next START or AGAIN plays: the host's pick (CONFIG), or what `"auto"` gives. */
  private nextHeat(room: Room): HeatTier {
    return chosenHeat(room.heat ?? "auto", this.autoHeat(room));
  }

  /** The co-op round's heat or the Versus series' while one is on, else {@link nextHeat}. */
  private heatOf(room: Room): HeatTier {
    if (isVersus(room.mode)) {
      const series = this.series();
      if (series !== null && isPlayingPhase(room.phase)) return series.heat;
      return this.nextHeat(room);
    }
    const clock = this.clock();
    if (clock !== null && (room.phase === "countdown" || room.phase === "round")) return clock.heat;
    return this.nextHeat(room);
  }

  /** The LOBBY fields; `except` is a socket that is closing. */
  private lobbyFields(room: Room, except?: WebSocket): LobbyFields {
    return {
      code: room.code,
      mode: room.mode,
      phase: room.phase,
      hostId: room.hostId,
      heat: this.heatOf(room),
      heatChoice: room.heat ?? "auto",
      autoHeat: this.autoHeat(room),
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
          ...(room.mode === "team" ? { team: room.teams?.[p.id] ?? 0 } : {}),
        })),
      ...(isVersus(room.mode) ? { series: room.series ?? DEFAULT_SERIES } : {}),
      ...(room.variant === "survival" && room.mode !== "team" ? { variant: room.variant } : {}),
      ...(room.mode === "team" ? { rule: this.ruleOf(room) } : {}),
      ...(room.nextAt === undefined ? {} : { nextAt: room.nextAt }),
    };
  }

  /** Team Versus: the series' rule while one is on, else what the next one plays. */
  private ruleOf(room: Room): TeamRule {
    const series = this.series();
    if (series?.teams !== undefined && isPlayingPhase(room.phase)) return series.teams.rule;
    return room.rule ?? DEFAULT_TEAM_RULE;
  }

  private lobbyMessage(room: Room, except?: WebSocket): ServerMessage {
    return { op: "LOBBY", ...this.lobbyFields(room, except) };
  }

  /** SNAPSHOT for `receiver` (Versus shows them their own mold). */
  private snapshot(room: Room, now: number, receiver: string): ServerMessage {
    if (isVersus(room.mode)) return this.vsSnapshot(room, now, receiver);
    const round = this.coopRound();
    const results = this.read<ResultsFields>(RESULTS);
    return {
      op: "SNAPSHOT",
      lobby: this.lobbyFields(room),
      ...(round !== null && room.phase !== "lobby" ? { round: roundSnapshot(round, now, room.phase === "countdown" || room.phase === "round") } : {}),
      ...(results !== null && room.phase === "results" ? { results } : {}),
      ...this.chatFields(),
    };
  }

  /** SNAPSHOT `chat`, while the room has any. */
  private chatFields(): { readonly chat?: readonly ChatLine[] } {
    const lines = this.read<ChatLog>(CHAT)?.lines ?? [];
    return lines.length === 0 ? {} : { chat: lines };
  }

  /**
   * Versus SNAPSHOT: `round` (with `mine` and `progress`) during a
   * countdown or round, `standings` (the last ROUND_END) during the
   * standings and results, and `results` (the SERIES_END) during results.
   */
  private vsSnapshot(room: Room, now: number, receiver: string): ServerMessage {
    const round = this.vsRound();
    const series = this.series();
    const standings = this.read<VsRoundEndFields>(STANDINGS);
    const results = this.read<SeriesEndFields>(RESULTS);
    const live = room.phase === "countdown" || room.phase === "round";
    const after = room.phase === "standings" || room.phase === "results";
    return {
      op: "SNAPSHOT",
      lobby: this.lobbyFields(room),
      ...(live && round !== null && series !== null ? { round: vsRoundSnapshot(round, series, receiver, now) } : {}),
      ...(after && standings !== null ? { standings } : {}),
      ...(room.phase === "results" && results !== null ? { results } : {}),
      ...this.chatFields(),
    };
  }

  private resultsFields(award: CoopPendingAward, xp: Readonly<Record<string, XpBody>>): ResultsFields {
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

  private seriesEndFields(award: VsPendingAward, xp: Readonly<Record<string, VsXpBody>>): SeriesEndFields {
    const { winner, early, forfeit, rounds, players, team, teamTally } = award.record.results;
    return {
      winner,
      early,
      forfeit,
      rounds,
      podium: players.map((p) => ({
        id: p.id,
        username: award.usernames[p.id] ?? "",
        wins: p.wins,
        place: p.place,
        ...(p.team === undefined ? {} : { team: p.team }),
      })),
      history: award.history ?? [],
      xp,
      ...(team === undefined ? {} : { team, rule: award.record.rule ?? DEFAULT_TEAM_RULE, teamTally: teamTally ?? [0, 0] }),
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

  /** Everyone's seat, for {@link pickHost}. `joining` is a player whose socket is opening, so counts as connected. */
  private seats(room: Room, joining?: string): Seat[] {
    return room.players.map((p) => ({
      id: p.id,
      joinedAt: p.joinedAt,
      present: !p.left,
      connected: p.id === joining || this.socketsOf(p.id).length > 0,
    }));
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

  /** Versus PROGRESS for one racer: everyone gets the count; whoever is watching also gets their slots. */
  private sendProgress(round: VsRound, series: VsSeries, id: string): void {
    const progress = progressOf(round, true).find((p) => p.id === id);
    if (progress === undefined) return;
    const { slots, ...counts } = progress;
    const forRacers = JSON.stringify({ op: "PROGRESS", ...counts } satisfies ServerMessage);
    const forWatchers = JSON.stringify({ op: "PROGRESS", ...counts, slots: slots ?? [] } satisfies ServerMessage);
    for (const ws of this.openSockets()) {
      const uid = attachmentOf(ws)?.u;
      try {
        ws.send(uid === undefined || watchesRound(round, series, uid) ? forWatchers : forRacers);
      } catch {
        // Closing.
      }
    }
  }

  private submitLimiter(uid: string, now: number): SubmitLimiter {
    let limiter = this.submitLimits.get(uid);
    if (limiter === undefined) {
      limiter = new SubmitLimiter(now);
      this.submitLimits.set(uid, limiter);
    }
    return limiter;
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
