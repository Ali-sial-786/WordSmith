/**
 * Room rules shared by every mode: codes, seats and colours, the host,
 * timings and the submission rate limit (shared/room-protocol.md,
 * docs/TECH.md §6). Pure, so it's unit-tested in Node.
 */

// ---------------------------------------------------------------------------
// Room codes
// ---------------------------------------------------------------------------

/** No 0/O or 1/I, so codes can be read out loud (DESIGN.md §7). */
export const ROOM_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
export const ROOM_CODE_LENGTH = 6;
export const ROOM_CODE_RE = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/;

/**
 * A room code from `ROOM_CODE_LENGTH` random bytes. The alphabet has 32
 * characters, so taking each byte mod 32 is unbiased.
 */
export function roomCodeFromBytes(bytes: Uint8Array): string {
  if (bytes.length < ROOM_CODE_LENGTH) throw new RangeError(`need ${ROOM_CODE_LENGTH} random bytes`);
  let code = "";
  for (let i = 0; i < ROOM_CODE_LENGTH; i++) code += ROOM_CODE_ALPHABET[bytes[i]! % ROOM_CODE_ALPHABET.length];
  return code;
}

/** Upper-cases and trims what a player typed; `null` if it can't be a room code. */
export function normalizeRoomCode(raw: string): string | null {
  const code = raw.trim().toUpperCase();
  return ROOM_CODE_RE.test(code) ? code : null;
}

// ---------------------------------------------------------------------------
// Modes and timings
// ---------------------------------------------------------------------------

export type RoomMode = "coop";
export type RoomPhase = "lobby" | "countdown" | "round" | "results";

/** Players a room holds, by mode. */
export const MAX_PLAYERS: Readonly<Record<RoomMode, number>> = { coop: 4 };
/** Players needed to START, by mode. Solo co-op is allowed (for testing). */
export const MIN_PLAYERS: Readonly<Record<RoomMode, number>> = { coop: 1 };

export const COUNTDOWN_MS = 3_000;
/** A dropped player keeps their seat and points this long. */
export const REJOIN_GRACE_MS = 30_000;
/** A room nobody is connected to closes after this. */
export const EMPTY_CLOSE_MS = 2 * 60_000;
/** A room closes this long after the last message from any player. */
export const IDLE_CLOSE_MS = 30 * 60_000;
/** Multiplayer puzzles a player has had this recently are skipped. */
export const PUZZLE_REPEAT_WINDOW_MS = 60 * 24 * 3600_000;

// ---------------------------------------------------------------------------
// Seats
// ---------------------------------------------------------------------------

/** Player colours: copper, gold, verdigris, cobalt. */
export const PLAYER_COLORS = 4;

/** The lowest colour nobody in `taken` has, or `null` if all are used. */
export function freeColor(taken: readonly number[], colors = PLAYER_COLORS): number | null {
  for (let c = 0; c < colors; c++) if (!taken.includes(c)) return c;
  return null;
}

export interface Seat {
  readonly id: string;
  /** Join order: lower joined earlier. */
  readonly joinedAt: number;
  /** False once the player has left (LEAVE or rejoin time ran out) but is still listed. */
  readonly present: boolean;
}

/**
 * Who should be host: the current host if they're still present, otherwise
 * whoever joined earliest among those present. `null` if nobody is.
 */
export function pickHost(current: string | null, seats: readonly Seat[]): string | null {
  const present = seats.filter((s) => s.present);
  if (current !== null && present.some((s) => s.id === current)) return current;
  let earliest: Seat | null = null;
  for (const s of present) if (earliest === null || s.joinedAt < earliest.joinedAt) earliest = s;
  return earliest?.id ?? null;
}

/** Puzzle size for a team: one per player, 1–4 (shared/puzzle-format.md). */
export function puzzleSizeFor(players: number): number {
  return Math.min(4, Math.max(1, players));
}

// ---------------------------------------------------------------------------
// Rate limiting (docs/TECH.md §6)
// ---------------------------------------------------------------------------

/** SUBMIT token bucket: a burst of 4, refilled at 4 per second. */
export const SUBMIT_BURST = 4;
export const SUBMIT_PER_SECOND = 4;
/** This many invalid words within the window locks the player out. */
export const INVALID_LIMIT = 10;
export const INVALID_WINDOW_MS = 5_000;
export const LOCKOUT_MS = 3_000;

/**
 * One player's SUBMIT limiter. Kept in memory: it resets if the room
 * hibernates, which only ever lets a player through sooner.
 */
export class SubmitLimiter {
  private tokens: number;
  private last: number;
  private invalid: number[] = [];
  private lockedUntil = 0;

  constructor(
    now: number,
    private readonly burst = SUBMIT_BURST,
    private readonly perSecond = SUBMIT_PER_SECOND,
  ) {
    this.tokens = burst;
    this.last = now;
  }

  /** Whether a SUBMIT may go ahead now. Takes a token if so. */
  take(now: number): boolean {
    this.tokens = Math.min(this.burst, this.tokens + (Math.max(0, now - this.last) / 1000) * this.perSecond);
    this.last = now;
    if (now < this.lockedUntil) return false;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }

  /** Records an `invalid` result; the 10th within 5 s starts a 3 s lockout. */
  recordInvalid(now: number): void {
    this.invalid = this.invalid.filter((t) => now - t < INVALID_WINDOW_MS);
    this.invalid.push(now);
    if (this.invalid.length >= INVALID_LIMIT) {
      this.lockedUntil = now + LOCKOUT_MS;
      this.invalid = [];
    }
  }

  locked(now: number): boolean {
    return now < this.lockedUntil;
  }
}

/** Token bucket for everything else a socket sends (READY, EMOTE, …): dropped past this. */
export const OTHER_BURST = 10;
export const OTHER_PER_SECOND = 2;
