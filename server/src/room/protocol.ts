/**
 * Room messages: the contract in shared/room-protocol.md. JSON `{op, ...}`
 * over one `wordsmith.v1` WebSocket per room. Pure, so it's unit-tested in
 * Node.
 *
 * Client → server: READY, CONFIG (the variant, the heat, and the Versus series),
 * START, SUBMIT, HINT, AGAIN, LEAVE, EMOTE, CHAT, and the exact text
 * `{"op":"PING"}` (answered `{"op":"PONG"}` by the runtime without waking
 * the room).
 *
 * Server → client: WELCOME, LOBBY, ROUND_START, WORD_RESULT, CLAIMED, BONUS,
 * REVEAL, PROGRESS (Versus), HEATED and MELT (survival), ROUND_END,
 * SERIES_END (Versus), SNAPSHOT, EMOTE, CHAT, ERROR.
 *
 * Survival (shared/survival.md) adds its fields only to survival rooms and
 * rounds: a message without `variant` is classic, exactly as before.
 */

import type { CoopResults, RevealedCell, RoundSnapshot, RoundStartFields, SlotWord } from "../rules/coop-round";
import { isHeatChoice, type HeatChoice, type HeatTier } from "../rules/heat";
import type { HintCounts, HintKind } from "../rules/progression";
import { MAX_CHAT_LENGTH, type RoomMode, type RoomPhase } from "../rules/room";
import { isVariant, type HeatedFields, type Variant } from "../rules/survival";
import { isSeriesLength, type SeriesLength } from "../rules/vs";
import type { VsRoundEndFields, VsRoundSnapshot, VsRoundStartFields, VsRoundSummary } from "../rules/vs-round";

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
  /** The host's choices: the variant and the heat (lobby or results), and the Versus series length (lobby). At least one. */
  | { readonly op: "CONFIG"; readonly variant?: Variant; readonly series?: SeriesLength; readonly heat?: HeatChoice }
  | { readonly op: "START" }
  | { readonly op: "SUBMIT"; readonly word: string; readonly seq: number }
  | { readonly op: "HINT"; readonly hint: HintRequest }
  | { readonly op: "AGAIN" }
  | { readonly op: "LEAVE" }
  | { readonly op: "EMOTE"; readonly emote: Emote }
  /** `text` is already tidied ({@link cleanChatText}); the room stars out profanity before sending it on. */
  | { readonly op: "CHAT"; readonly text: string };

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
  | "no_hints"
  /** CHAT faster than the chat limit (rules/room.ts `CHAT_BURST`). */
  | "chat_limit";

export type ParseResult = { readonly ok: true; readonly message: ClientMessage } | { readonly ok: false };

const BAD: ParseResult = { ok: false };

/**
 * A chat line as the room keeps it: control, private-use and invisible
 * formatting characters removed, right-to-left overrides among them (the
 * joiners and tags inside emoji stay), line breaks and runs of spaces made
 * one space, trimmed, and cut to {@link MAX_CHAT_LENGTH} characters.
 * `null` if nothing is left.
 */
export function cleanChatText(text: string): string | null {
  const tidy = text
    .replace(/[\r\n\t]+/g, " ")
    .replace(/(?![\u200d\u{e0020}-\u{e007f}])[\p{Cc}\p{Cf}\p{Co}]/gu, "")
    .replace(/\s+/g, " ")
    .trim();
  if (tidy === "") return null;
  const chars = [...tidy];
  return chars.length > MAX_CHAT_LENGTH ? chars.slice(0, MAX_CHAT_LENGTH).join("").trimEnd() : tidy;
}

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
    case "CONFIG": {
      if (m.variant === undefined && m.series === undefined && m.heat === undefined) return BAD;
      if (m.variant !== undefined && !isVariant(m.variant)) return BAD;
      if (m.series !== undefined && !isSeriesLength(m.series)) return BAD;
      if (m.heat !== undefined && !isHeatChoice(m.heat)) return BAD;
      const message: ClientMessage = {
        op: "CONFIG",
        ...(m.variant === undefined ? {} : { variant: m.variant }),
        ...(m.series === undefined ? {} : { series: m.series }),
        ...(m.heat === undefined ? {} : { heat: m.heat }),
      };
      return { ok: true, message };
    }
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
    case "CHAT": {
      const text = typeof m.text === "string" ? cleanChatText(m.text) : null;
      return text === null ? BAD : { ok: true, message: { op: "CHAT", text } };
    }
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
  /**
   * The heat the next round or series plays (the round's or series' own
   * while one is on): `heatChoice`, or what `"auto"` gives.
   */
  readonly heat: HeatTier;
  /** The host's pick (CONFIG): a tier, or `"auto"` (the default). Kept through AGAIN. */
  readonly heatChoice: HeatChoice;
  /** What `"auto"` gives with the room as it is: co-op, the host's level; Versus, the median level of the seated players. */
  readonly autoHeat: HeatTier;
  readonly players: readonly LobbyPlayer[];
  /** Versus only: the series length (3, 5, 7 or 10). */
  readonly series?: SeriesLength;
  /** Only while it's `"survival"` (CONFIG): left out, the room is classic. Applies from the next START or AGAIN. */
  readonly variant?: Variant;
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
  /** The part of `xp` the heat added (0 when only the XP survived a retried write). */
  readonly heatBonus: number;
  /** Tiers the heat was above the player's own, each adding to the bonus. */
  readonly tiersAbove: number;
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
  /** Every round played, in order: how it went and everyone's mold (`[]` for a series stored before it). */
  readonly history: readonly VsRoundSummary[];
  /** `{}` until the results are written to D1. */
  readonly xp: Readonly<Record<string, VsXpBody>>;
}

/** One chat line (CHAT, and SNAPSHOT `chat`). */
export interface ChatLine {
  /** Counts up from 1 in each room. */
  readonly id: number;
  readonly from: string;
  /** The sender's username when they sent it, so a player who has left can still be named. */
  readonly username: string;
  /** Profanity starred out. */
  readonly text: string;
  /** Server time, ms. */
  readonly at: number;
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
  /** Versus. `slots` only to those watching the round (never letters). */
  | { readonly op: "PROGRESS"; readonly id: string; readonly filled: number; readonly total: number; readonly slots?: readonly number[] }
  /** Survival: a mold's heated slot changed (co-op: to everyone; Versus: to the racer, about their own), or its countdown resumed. */
  | ({ readonly op: "HEATED" } & HeatedFields)
  /** Survival: a heated slot melted (Versus: on `id`'s mold). Straight before ROUND_END. */
  | { readonly op: "MELT"; readonly slot: number; readonly id?: string }
  | ({ readonly op: "ROUND_END" } & (ResultsFields | VsRoundEndFields))
  | ({ readonly op: "SERIES_END" } & SeriesEndFields)
  | {
      readonly op: "SNAPSHOT";
      readonly lobby: LobbyFields;
      /** The round during countdown and play, and the finished board during results. */
      readonly round?: RoundSnapshot;
      readonly results?: ResultsFields;
      /** The room's latest chat lines, oldest first; left out while there are none. */
      readonly chat?: readonly ChatLine[];
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
      readonly chat?: readonly ChatLine[];
    }
  | { readonly op: "EMOTE"; readonly from: string; readonly emote: Emote }
  | ({ readonly op: "CHAT" } & ChatLine)
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
  /** The caller holds a seat (they can always come back, even mid-round or when full). */
  readonly seated: boolean;
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
