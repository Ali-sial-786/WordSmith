/**
 * Room messages: the contract in shared/room-protocol.md. JSON `{op, ...}`
 * over one `wordsmith.v1` WebSocket per room. Pure, so it's unit-tested in
 * Node.
 *
 * Client → server: READY, CONFIG (Versus), START, SUBMIT, HINT, AGAIN,
 * LEAVE, EMOTE, and the exact text `{"op":"PING"}` (answered
 * `{"op":"PONG"}` by the runtime without waking the room).
 *
 * Server → client: WELCOME, LOBBY, ROUND_START, WORD_RESULT, CLAIMED, BONUS,
 * REVEAL, PROGRESS (Versus), ROUND_END, SERIES_END (Versus), SNAPSHOT,
 * EMOTE, ERROR.
 */

import type { CoopResults, RevealedCell, RoundSnapshot, RoundStartFields, SlotWord } from "../rules/coop-round";
import type { HeatTier } from "../rules/heat";
import type { HintCounts, HintKind } from "../rules/progression";
import type { RoomMode, RoomPhase } from "../rules/room";
import { isSeriesLength, type SeriesLength } from "../rules/vs";
import type { VsRoundEndFields, VsRoundSnapshot, VsRoundStartFields } from "../rules/vs-round";

export { PING, PONG } from "../hub/protocol";

/** Client messages longer than this are refused. */
export const MAX_CLIENT_MESSAGE_LENGTH = 1024;
/** Longest SUBMIT word accepted for refereeing (anvils have at most 8 letters). */
export const MAX_SUBMIT_LENGTH = 64;

export const EMOTES = ["nice", "close", "fire", "hammer", "gg"] as const;
export type Emote = (typeof EMOTES)[number];

export type HintRequest = { readonly kind: "hammer" | "sparks" } | { readonly kind: "chisel"; readonly x: number; readonly y: number };

export type ClientMessage =
  | { readonly op: "READY"; readonly ready: boolean }
  /** Versus: the series length, chosen by the host in the lobby. */
  | { readonly op: "CONFIG"; readonly series: SeriesLength }
  | { readonly op: "START" }
  | { readonly op: "SUBMIT"; readonly word: string; readonly seq: number }
  | { readonly op: "HINT"; readonly hint: HintRequest }
  | { readonly op: "AGAIN" }
  | { readonly op: "LEAVE" }
  | { readonly op: "EMOTE"; readonly emote: Emote };

export type RoomErrorCode =
  | "not_host"
  | "not_enough_players"
  | "bad_message"
  | "no_hint"
  | "hint_locked"
  | "bad_cell"
  | "wrong_phase"
  /** Not in the contract: the puzzle bank has nothing to offer (it was never seeded). */
  | "no_puzzle"
  /** Versus: a SUBMIT from someone watching this round (sudden death, or out of the series). */
  | "not_playing"
  /** Versus: HINT isn't allowed. */
  | "no_hints";

export type ParseResult = { readonly ok: true; readonly message: ClientMessage } | { readonly ok: false };

const BAD: ParseResult = { ok: false };

function isCoord(v: unknown): v is number {
  return typeof v === "number" && Number.isInteger(v) && v >= 0 && v < 10;
}

/** Reads one client message. Anything malformed or unknown is `bad_message`. */
export function parseClientMessage(raw: string | ArrayBuffer): ParseResult {
  if (typeof raw !== "string" || raw.length > MAX_CLIENT_MESSAGE_LENGTH) return BAD;
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return BAD;
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) return BAD;
  const m = value as Record<string, unknown>;
  switch (m.op) {
    case "READY":
      return typeof m.ready === "boolean" ? { ok: true, message: { op: "READY", ready: m.ready } } : BAD;
    case "CONFIG":
      return isSeriesLength(m.series) ? { ok: true, message: { op: "CONFIG", series: m.series } } : BAD;
    case "START":
    case "AGAIN":
    case "LEAVE":
      return { ok: true, message: { op: m.op } };
    case "SUBMIT":
      if (typeof m.word !== "string" || m.word.length > MAX_SUBMIT_LENGTH) return BAD;
      if (typeof m.seq !== "number" || !Number.isSafeInteger(m.seq) || m.seq < 0) return BAD;
      return { ok: true, message: { op: "SUBMIT", word: m.word, seq: m.seq } };
    case "HINT":
      if (m.kind === "hammer" || m.kind === "sparks") return { ok: true, message: { op: "HINT", hint: { kind: m.kind } } };
      if (m.kind === "chisel" && isCoord(m.x) && isCoord(m.y)) {
        return { ok: true, message: { op: "HINT", hint: { kind: "chisel", x: m.x, y: m.y } } };
      }
      return BAD;
    case "EMOTE":
      return (EMOTES as readonly unknown[]).includes(m.emote) ? { ok: true, message: { op: "EMOTE", emote: m.emote as Emote } } : BAD;
    default:
      return BAD;
  }
}

// ---------------------------------------------------------------------------
// Server → client
// ---------------------------------------------------------------------------

export interface LobbyPlayer {
  readonly id: string;
  readonly username: string;
  readonly avatar: string;
  readonly level: number;
  /** 0–3: copper, gold, verdigris, cobalt (Versus adds 4, titanium). Kept while the player is in the room. */
  readonly color: number;
  readonly ready: boolean;
  readonly connected: boolean;
}

export interface LobbyFields {
  readonly code: string;
  readonly mode: RoomMode;
  readonly phase: RoomPhase;
  /** `null` only while the room is empty. */
  readonly hostId: string | null;
  /** Co-op: from the host's level. Versus: from the median level of the seated players, or the series' heat while one is on. */
  readonly heat: HeatTier;
  readonly players: readonly LobbyPlayer[];
  /** Versus only: the series length (3, 5, 7 or 10). */
  readonly series?: SeriesLength;
}

export interface XpBody {
  /** XP gained this round. */
  readonly xp: number;
  /** Smith Level after it. */
  readonly level: number;
  readonly levelUps: number;
  /** Level-up rewards. */
  readonly rewards: HintCounts;
  /** Not in the contract: Hammer Strikes smelted from this round's bonus words (Scrap Bin). */
  readonly scrapHammers: number;
}

export interface ResultsPlayer {
  readonly id: string;
  /** Not in the contract: so results can name players who have since left. */
  readonly username: string;
  readonly points: number;
  readonly words: number;
  readonly longest: string;
  /** Not in the contract: bonus words found. */
  readonly bonus: number;
}

export interface ResultsFields extends Omit<CoopResults, "players"> {
  readonly players: readonly ResultsPlayer[];
  readonly xp: Readonly<Record<string, XpBody>>;
}

export type WordResultKind = "claimed" | "bonus" | "already" | "invalid" | "rate_limited" | "too_late";

/** Versus XP: the co-op shape plus the embers collected during the series. */
export interface VsXpBody extends XpBody {
  /** Embers collected during the series, granted at its end. */
  readonly pickups: HintCounts;
}

export interface PodiumEntry {
  readonly id: string;
  readonly username: string;
  readonly wins: number;
  /** 1-based; equal wins share a place. */
  readonly place: number;
}

/** `SERIES_END` (Versus). */
export interface SeriesEndFields {
  readonly winner: string | null;
  readonly early: boolean;
  readonly forfeit: boolean;
  readonly rounds: number;
  readonly podium: readonly PodiumEntry[];
  /** `{}` until the results are written to D1. */
  readonly xp: Readonly<Record<string, VsXpBody>>;
}

export type ServerMessage =
  | { readonly op: "WELCOME"; readonly you: string; readonly protocol: number; readonly serverNow: number }
  | ({ readonly op: "LOBBY" } & LobbyFields)
  | ({ readonly op: "ROUND_START" } & (RoundStartFields | VsRoundStartFields))
  | {
      readonly op: "WORD_RESULT";
      readonly seq: number;
      readonly word: string;
      readonly result: WordResultKind;
      /** Co-op `already`: who has it (`null` if it filled in by itself). */
      readonly by?: string | null;
      /** Co-op `claimed` and `bonus`. */
      readonly points?: number;
      /** Versus `claimed`: the slot, and the crossing slots it completed on the sender's mold. */
      readonly slot?: number;
      readonly auto?: readonly SlotWord[];
      /** Versus `claimed`: the ember collected (granted after the series). */
      readonly pickup?: HintKind;
    }
  | {
      readonly op: "CLAIMED";
      readonly slot: number;
      readonly word: string;
      readonly by: string;
      readonly points: number;
      readonly scores: Readonly<Record<string, number>>;
      readonly auto: readonly SlotWord[];
      readonly pickup?: HintKind;
    }
  | { readonly op: "BONUS"; readonly word: string; readonly by: string; readonly points: number; readonly scores: Readonly<Record<string, number>> }
  | { readonly op: "REVEAL"; readonly by: string; readonly kind: HintKind; readonly cells: readonly RevealedCell[]; readonly auto: readonly SlotWord[] }
  | { readonly op: "PROGRESS"; readonly id: string; readonly filled: number; readonly total: number }
  | ({ readonly op: "ROUND_END" } & (ResultsFields | VsRoundEndFields))
  | ({ readonly op: "SERIES_END" } & SeriesEndFields)
  | {
      readonly op: "SNAPSHOT";
      readonly lobby: LobbyFields;
      /** The round during countdown and play, and the finished board during results. */
      readonly round?: RoundSnapshot;
      readonly results?: ResultsFields;
    }
  | {
      readonly op: "SNAPSHOT";
      readonly lobby: LobbyFields;
      /** Versus, during countdown and play: the round, the receiver's own mold and everyone's progress. */
      readonly round?: VsRoundSnapshot;
      /** Versus, during standings and results: the last ROUND_END. */
      readonly standings?: VsRoundEndFields;
      /** Versus, during results: the SERIES_END. */
      readonly results?: SeriesEndFields;
    }
  | { readonly op: "EMOTE"; readonly from: string; readonly emote: Emote }
  | { readonly op: "ERROR"; readonly code: RoomErrorCode };

// ---------------------------------------------------------------------------
// Worker → room
// ---------------------------------------------------------------------------

/** Who is connecting, as the Worker verified and looked up. */
export interface RoomIdentity {
  readonly id: string;
  readonly username: string;
  readonly avatar: string;
  readonly level: number;
}

/** `GET /v1/rooms/:code`. */
export interface RoomSummary {
  readonly code: string;
  readonly mode: RoomMode;
  readonly phase: RoomPhase;
  readonly host: { readonly id: string; readonly username: string } | null;
  readonly players: number;
  readonly maxPlayers: number;
}

export function parseIdentity(raw: string | null): RoomIdentity | null {
  if (raw === null) return null;
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof v !== "object" || v === null) return null;
  const r = v as Record<string, unknown>;
  if (typeof r.id !== "string" || r.id === "" || typeof r.username !== "string" || r.username === "") return null;
  if (typeof r.avatar !== "string" || typeof r.level !== "number" || !Number.isInteger(r.level) || r.level < 1) return null;
  return { id: r.id, username: r.username, avatar: r.avatar, level: r.level };
}
