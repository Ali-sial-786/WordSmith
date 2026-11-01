/**
 * Rune Rush (shared/rune-rush.md): the letter-grid race. Everyone gets the
 * same grid of letter dice and finds words by joining touching letters
 * (diagonals too, each die once per word) until the timer runs out. A word
 * scores its length less two (at least 1), double if nobody else found it.
 * A game is a few rounds, each on a fresh grid, won on the total.
 *
 * - **Rune Rush** (`rune`): everyone for themselves.
 * - **Team Rune Rush** (`runeteam`): two teams, scored one of two ways:
 *   `pooled` (a team shares one list of words, each counted once; a word
 *   the other team didn't find is unique) or `sum` (everyone scores as in
 *   Rune Rush, and a team's score is its players' added up).
 *
 * The words are the game's accepted list (rune-words.gen.ts), so a board's
 * every word is known when it's made: a SUBMIT is checked against that.
 * Pure, so it's unit-tested in Node.
 */

import type { HeatTier } from "./heat";
import type { Rand } from "./mold";
import { noHints } from "./progression";
import { RUNE_WORDS } from "./rune-words.gen";
import { TEAMS, type TeamId } from "./teams";
import type { VsPlayerResult, VsSeriesOutcome, VsSeriesResults } from "./vs-round";
import { normalizeWord } from "./words";

// ---------------------------------------------------------------------------
// Settings (the host's, CONFIG `rune`)
// ---------------------------------------------------------------------------

export const RUNE_SIZES = [4, 5, 6] as const;
export type RuneSize = (typeof RUNE_SIZES)[number];
export const RUNE_SECONDS = [30, 60, 90, 120, 180] as const;
export type RuneSeconds = (typeof RUNE_SECONDS)[number];
export const RUNE_MINS = [3, 4, 5] as const;
export type RuneMin = (typeof RUNE_MINS)[number];
export const RUNE_ROUNDS = [1, 3, 5] as const;
export type RuneRounds = (typeof RUNE_ROUNDS)[number];
export const RUNE_TEAM_SCORINGS = ["pooled", "sum"] as const;
export type RuneTeamScoring = (typeof RUNE_TEAM_SCORINGS)[number];

export interface RuneSettings {
  readonly size: RuneSize;
  readonly seconds: RuneSeconds;
  readonly min: RuneMin;
  readonly rounds: RuneRounds;
  /** Team Rune Rush only. */
  readonly teamScoring: RuneTeamScoring;
}

export const DEFAULT_RUNE: RuneSettings = { size: 4, seconds: 180, min: 3, rounds: 3, teamScoring: "pooled" };

export type RuneSettingsPatch = Partial<RuneSettings>;

const isOneOf = <T>(list: readonly T[], v: unknown): v is T => (list as readonly unknown[]).includes(v);

/** CONFIG `rune`: an object with at least one known setting, each valid; anything else is `null`. */
export function parseRunePatch(v: unknown): RuneSettingsPatch | null {
  if (typeof v !== "object" || v === null || Array.isArray(v)) return null;
  const m = v as Record<string, unknown>;
  const keys = Object.keys(m);
  if (keys.length === 0 || keys.some((k) => !["size", "seconds", "min", "rounds", "teamScoring"].includes(k))) return null;
  if (m.size !== undefined && !isOneOf(RUNE_SIZES, m.size)) return null;
  if (m.seconds !== undefined && !isOneOf(RUNE_SECONDS, m.seconds)) return null;
  if (m.min !== undefined && !isOneOf(RUNE_MINS, m.min)) return null;
  if (m.rounds !== undefined && !isOneOf(RUNE_ROUNDS, m.rounds)) return null;
  if (m.teamScoring !== undefined && !isOneOf(RUNE_TEAM_SCORINGS, m.teamScoring)) return null;
  return m as RuneSettingsPatch;
}

/** `settings` with `patch` applied; `changed` if anything differs. */
export function applyRunePatch(settings: RuneSettings, patch: RuneSettingsPatch): { readonly settings: RuneSettings; readonly changed: boolean } {
  const next = { ...settings, ...patch };
  const changed = (Object.keys(next) as (keyof RuneSettings)[]).some((k) => next[k] !== settings[k]);
  return { settings: next, changed };
}

// ---------------------------------------------------------------------------
// The board
// ---------------------------------------------------------------------------

/** Letter dice: a Q face is the tile QU. 16 for 4×4, 25 for 5×5, and those 25 plus 11 more for 6×6. */
const DICE_16 = [
  "AAEEGN", "ABBJOO", "ACHOPS", "AFFKPS", "AOOTTW", "CIMOTU", "DEILRX", "DELRVY",
  "DISTTY", "EEGHNW", "EEINSU", "EHRTVW", "EIOSST", "ELRTTY", "HIMNQU", "HLNNRZ",
];
const DICE_25 = [
  "AAAFRS", "AAEEEE", "AAFIRS", "ADENNN", "AEEEEM", "AEEGMU", "AEGMNN", "AFIRSY", "BJKQXZ",
  "CCENST", "CEIILT", "CEILPT", "CEIPST", "DDHNOT", "DHHLOR", "DHLNOR", "DHLNOR", "EIIITT",
  "EMOTTT", "ENSSSU", "FIPRSY", "GORRVW", "IPRRRY", "NOOTUW", "OOOTTU",
];
const DICE_36 = [
  ...DICE_25,
  "AAEEGN", "ACHOPS", "AFFKPS", "AOOTTW", "DEILRX", "DELRVY", "EEGHNW", "EEINSU", "EHRTVW", "EIOSST", "ELRTTY",
];
const DICE: Readonly<Record<RuneSize, readonly string[]>> = { 4: DICE_16, 5: DICE_25, 6: DICE_36 };

/** The longest word the list has. */
export const MAX_RUNE_WORD = 8;

/** Rolls the dice into a `size`×`size` grid, row by row: each tile is a letter, or `QU`. */
export function rollGrid(size: RuneSize, rand: Rand): string[] {
  const dice = [...DICE[size]];
  for (let i = dice.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [dice[i], dice[j]] = [dice[j]!, dice[i]!];
  }
  return dice.map((die) => {
    const face = die[Math.floor(rand() * die.length)]!;
    return face === "Q" ? "QU" : face;
  });
}

let dictionary: readonly string[] | null = null;

/** The sorted word list, split the first time it's needed. */
function words(): readonly string[] {
  return (dictionary ??= RUNE_WORDS.split("\n"));
}

/** The first index in the list whose word is not before `key`. */
function lowerBound(list: readonly string[], key: string): number {
  let lo = 0;
  let hi = list.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (list[mid]! < key) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/** Whether `word` (lowercase) is in the list. */
export function isRuneWord(word: string): boolean {
  const list = words();
  return list[lowerBound(list, word)] === word;
}

const neighbourCache = new Map<number, number[][]>();

/** Each tile's touching tiles (diagonals too) on a `size`×`size` grid. */
export function neighbours(size: number): number[][] {
  let n = neighbourCache.get(size);
  if (n === undefined) {
    n = [];
    for (let i = 0; i < size * size; i++) {
      const x = i % size;
      const y = Math.floor(i / size);
      const touching: number[] = [];
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx;
          const ny = y + dy;
          if ((dx !== 0 || dy !== 0) && nx >= 0 && ny >= 0 && nx < size && ny < size) touching.push(ny * size + nx);
        }
      }
      n.push(touching);
    }
    neighbourCache.set(size, n);
  }
  return n;
}

/** Longest first, then A–Z. */
export function byLength(a: string, b: string): number {
  return b.length - a.length || (a < b ? -1 : a > b ? 1 : 0);
}

/** Every word of at least `min` letters the grid holds (uppercase), longest first. */
export function solveGrid(tiles: readonly string[], size: number, min: number): string[] {
  const list = words();
  const lower = tiles.map((t) => t.toLowerCase());
  const touching = neighbours(size);
  const used = new Array<boolean>(tiles.length).fill(false);
  const found = new Set<string>();
  const visit = (i: number, prefix: string): void => {
    const word = prefix + lower[i]!;
    if (word.length > MAX_RUNE_WORD) return;
    const at = lowerBound(list, word);
    // No word starts this way: nothing further along this path either.
    if (at >= list.length || !list[at]!.startsWith(word)) return;
    if (word.length >= min && list[at] === word) found.add(word.toUpperCase());
    used[i] = true;
    for (const j of touching[i]!) if (!used[j]) visit(j, word);
    used[i] = false;
  };
  for (let i = 0; i < tiles.length; i++) visit(i, "");
  return [...found].sort(byLength);
}

/** Words a good board has at least, by size, at a shortest word of 3 (fewer at 4 and 5). */
const TARGET_WORDS: Readonly<Record<RuneSize, number>> = { 4: 60, 5: 150, 6: 250 };
const TARGET_SHARE: Readonly<Record<RuneMin, number>> = { 3: 1, 4: 0.7, 5: 0.4 };
const BOARD_TRIES = 30;

export interface RuneBoard {
  readonly tiles: readonly string[];
  /** Every word on it of at least the shortest length, longest first. */
  readonly words: readonly string[];
}

/** A fresh board: rolled until it holds enough words (or the most found in a few tries). */
export function newBoard(size: RuneSize, min: RuneMin, rand: Rand): RuneBoard {
  const target = Math.round(TARGET_WORDS[size] * TARGET_SHARE[min]);
  let best: RuneBoard | null = null;
  for (let i = 0; i < BOARD_TRIES; i++) {
    const tiles = rollGrid(size, rand);
    const board = { tiles, words: solveGrid(tiles, size, min) };
    if (best === null || board.words.length > best.words.length) best = board;
    if (board.words.length >= target) break;
  }
  return best!;
}

/** A word's points: its length less two, at least 1 (3 letters 1, 4 letters 2, 5 letters 3, …). Double when unique. */
export function wordPoints(word: string): number {
  return Math.max(1, word.length - 2);
}

// ---------------------------------------------------------------------------
// A round
// ---------------------------------------------------------------------------

/** A round as the room stores it (`round`): the board, and every word found, in order. */
export interface RuneRound {
  readonly game: "rune";
  readonly round: number;
  /** A tiebreaker round, after the regular ones. */
  readonly tiebreak: boolean;
  /** The series' heat (it sets the XP). */
  readonly heat: HeatTier;
  readonly startsAt: number;
  readonly endsAt: number;
  readonly size: RuneSize;
  readonly min: RuneMin;
  readonly tiles: readonly string[];
  /** Every word on the board, longest first. */
  readonly words: readonly string[];
  /** Who plays it (a tiebreaker: only the tied). */
  readonly playerIds: readonly string[];
  /** Every word found, in order: `[player, word]`. */
  readonly finds: [string, string][];
}

export interface NewRuneRoundInput {
  readonly round: number;
  readonly tiebreak: boolean;
  readonly heat: HeatTier;
  readonly settings: RuneSettings;
  readonly playerIds: readonly string[];
  readonly startsAt: number;
  readonly rand: Rand;
}

export function newRuneRound(input: NewRuneRoundInput): RuneRound {
  const { size, min, seconds } = input.settings;
  const board = newBoard(size, min, input.rand);
  return {
    game: "rune",
    round: input.round,
    tiebreak: input.tiebreak,
    heat: input.heat,
    startsAt: input.startsAt,
    endsAt: input.startsAt + seconds * 1000,
    size,
    min,
    tiles: board.tiles,
    words: board.words,
    playerIds: [...input.playerIds],
    finds: [],
  };
}

/** The words `id` found, in order. */
export function wordsOf(r: RuneRound, id: string): string[] {
  return r.finds.filter(([by]) => by === id).map(([, word]) => word);
}

export type RuneSubmitOutcome =
  /** Not a word on this board (or too short). */
  | { readonly result: "invalid" }
  /** Already found: by the sender, or (pooled teams) by `by`, a teammate. */
  | { readonly result: "already"; readonly word: string; readonly by: string }
  | { readonly result: "found"; readonly word: string; readonly points: number };

/**
 * A word sent by `by`. `team`: the sender's teammates, when their team
 * shares one list (pooled): a word one of them has is theirs already.
 */
export function applyRuneSubmit(r: RuneRound, by: string, raw: string, team: readonly string[] = []): RuneSubmitOutcome {
  const word = normalizeWord(raw);
  if (word === null || word.length < r.min || !r.words.includes(word)) return { result: "invalid" };
  const had = r.finds.find(([id, w]) => w === word && (id === by || team.includes(id)));
  if (had !== undefined) return { result: "already", word, by: had[0] };
  r.finds.push([by, word]);
  return { result: "found", word, points: wordPoints(word) };
}

/** How many words each racer has found so far. */
export function tallyOf(r: RuneRound): Record<string, number> {
  const tally: Record<string, number> = Object.fromEntries(r.playerIds.map((id) => [id, 0]));
  for (const [id] of r.finds) tally[id] = (tally[id] ?? 0) + 1;
  return tally;
}

/** One found word as a round's end shows it. */
export interface RuneFoundWord {
  readonly word: string;
  /** What it scored: {@link wordPoints}, doubled when unique. */
  readonly points: number;
  /** Nobody else found it (pooled teams: the other team didn't). */
  readonly unique: boolean;
}

export interface RuneRoundScore {
  /** Each racer's words, in the order found. */
  readonly found: Record<string, RuneFoundWord[]>;
  /** Each racer's points this round. */
  readonly points: Record<string, number>;
  /** Teams only: each team's points, `[copper, cobalt]` (its players' added up). */
  readonly teamPoints?: [number, number];
}

/** Scores a round: who found what, what was unique, and the points. */
export function scoreRound(r: RuneRound, teams?: { readonly of: Readonly<Record<string, TeamId>>; readonly scoring: RuneTeamScoring }): RuneRoundScore {
  // Who found each word: the players, or (pooled) the teams.
  const pooled = teams?.scoring === "pooled";
  const finders = new Map<string, Set<string>>();
  for (const [id, word] of r.finds) {
    const who = pooled ? `team${teams!.of[id] ?? 0}` : id;
    let set = finders.get(word);
    if (set === undefined) finders.set(word, (set = new Set()));
    set.add(who);
  }
  const found: Record<string, RuneFoundWord[]> = Object.fromEntries(r.playerIds.map((id) => [id, []]));
  const points: Record<string, number> = Object.fromEntries(r.playerIds.map((id) => [id, 0]));
  for (const [id, word] of r.finds) {
    const unique = finders.get(word)!.size === 1;
    const scored = wordPoints(word) * (unique ? 2 : 1);
    (found[id] ??= []).push({ word, points: scored, unique });
    points[id] = (points[id] ?? 0) + scored;
  }
  if (teams === undefined) return { found, points };
  const teamPoints: [number, number] = [0, 0];
  for (const [id, p] of Object.entries(points)) teamPoints[teams.of[id] ?? 0] += p;
  return { found, points, teamPoints };
}

// ---------------------------------------------------------------------------
// A game (a series of rounds)
// ---------------------------------------------------------------------------

/** Tiebreaker rounds played at most; still tied after them, the leaders share first place. */
export const MAX_TIEBREAKS = 3;
/** Words a round's end lists at most (the longest), and keeps in the history. */
export const MAX_LISTED_WORDS = 300;

export interface RuneRacer {
  readonly id: string;
  readonly team?: TeamId;
  /** Points over the game so far. */
  points: number;
  /** Words found over the game so far. */
  words: number;
  /** The longest word found ("" for none). */
  longest: string;
  /** Rounds where they scored the most (teams: their team did). */
  wins: number;
  /** Rounds played. */
  rounds: number;
  /** Left mid-game: out of it, their points kept. */
  out: boolean;
}

export interface RuneTeams {
  readonly of: Readonly<Record<string, TeamId>>;
  readonly scoring: RuneTeamScoring;
  /** Each team's points and words over the game, and rounds won. */
  readonly points: [number, number];
  readonly words: [number, number];
  readonly wins: [number, number];
}

/** One finished round, for the end of the game to go back over. */
export interface RuneRoundSummary {
  readonly round: number;
  readonly tiebreak: boolean;
  readonly size: RuneSize;
  readonly tiles: readonly string[];
  readonly found: Readonly<Record<string, readonly RuneFoundWord[]>>;
  readonly points: Readonly<Record<string, number>>;
  readonly teamPoints?: readonly [number, number];
  /** Who scored the most (`null`: a tie, or a team game). */
  readonly winner: string | null;
  /** Teams only: the team that scored the most (`null`: a tie). */
  readonly team?: TeamId | null;
  /** Every word on the board, longest first (at most {@link MAX_LISTED_WORDS}), and how many there were. */
  readonly words: readonly string[];
  readonly total: number;
}

/** A game as the room stores it (`series`). */
export interface RuneSeries {
  readonly game: "rune";
  readonly matchId: string;
  readonly settings: RuneSettings;
  readonly heat: HeatTier;
  readonly startedAt: number;
  readonly racers: RuneRacer[];
  readonly teams?: RuneTeams;
  /** Rounds played, tiebreakers included. */
  played: number;
  tiebreaks: number;
  /** While the standings show between rounds: when the next round starts. */
  standingsEndsAt: number | null;
  readonly history: RuneRoundSummary[];
}

export interface NewRuneSeriesInput {
  readonly matchId: string;
  readonly settings: RuneSettings;
  readonly heat: HeatTier;
  readonly racerIds: readonly string[];
  readonly startedAt: number;
  /** Team Rune Rush: everyone's team. */
  readonly teams?: Readonly<Record<string, TeamId>>;
}

export function newRuneSeries(input: NewRuneSeriesInput): RuneSeries {
  const teams = input.teams;
  return {
    game: "rune",
    matchId: input.matchId,
    settings: { ...input.settings },
    heat: input.heat,
    startedAt: input.startedAt,
    racers: input.racerIds.map((id) => ({
      id,
      ...(teams === undefined ? {} : { team: teams[id] ?? 0 }),
      points: 0,
      words: 0,
      longest: "",
      wins: 0,
      rounds: 0,
      out: false,
    })),
    ...(teams === undefined
      ? {}
      : {
          teams: {
            of: Object.fromEntries(input.racerIds.map((id) => [id, teams[id] ?? 0])),
            scoring: input.settings.teamScoring,
            points: [0, 0],
            words: [0, 0],
            wins: [0, 0],
          },
        }),
    played: 0,
    tiebreaks: 0,
    standingsEndsAt: null,
    history: [],
  };
}

export function activeRuneRacers(s: RuneSeries): string[] {
  return s.racers.filter((r) => !r.out).map((r) => r.id);
}

export function canRuneRace(s: RuneSeries, id: string): boolean {
  return s.racers.some((r) => r.id === id && !r.out);
}

/** A racer left mid-game: out. False if they weren't racing. */
export function markRuneOut(s: RuneSeries, id: string): boolean {
  const racer = s.racers.find((r) => r.id === id && !r.out);
  if (racer === undefined) return false;
  racer.out = true;
  return true;
}

/** Pooled teams: the sender's teammates, whose words are theirs too. */
export function teammatesOf(s: RuneSeries, id: string): string[] {
  const teams = s.teams;
  if (teams === undefined || teams.scoring !== "pooled") return [];
  return s.racers.filter((r) => r.id !== id && r.team === teams.of[id]).map((r) => r.id);
}

export interface RuneNextRound {
  readonly round: number;
  readonly tiebreak: boolean;
  readonly players: readonly string[];
}

export type RuneDecision = { readonly over: false; readonly next: RuneNextRound } | ({ readonly over: true } & VsSeriesOutcome);

/** Whether `a` is ahead of `b`: more points, then more words. */
const ahead = (a: { points: number; words: number }, b: { points: number; words: number }) =>
  a.points > b.points || (a.points === b.points && a.words > b.words);

/**
 * Where the game stands: every regular round played, the leader on points
 * (then words) wins; tied leaders play a tiebreaker round, only they in
 * Rune Rush, everyone in teams. One racer (or one team) left is a forfeit.
 */
export function runeDecision(s: RuneSeries): RuneDecision {
  const active = activeRuneRacers(s);
  const round = s.played + 1;
  const teams = s.teams;
  if (teams !== undefined) {
    const left = TEAMS.filter((t) => s.racers.some((r) => !r.out && r.team === t));
    if (left.length <= 1) return { over: true, winner: null, team: left[0] ?? null, early: false, forfeit: true };
    if (s.played < s.settings.rounds) return { over: false, next: { round, tiebreak: false, players: active } };
    const [a, b] = TEAMS.map((t) => ({ points: teams.points[t], words: teams.words[t] })) as [{ points: number; words: number }, { points: number; words: number }];
    if (ahead(a, b) || ahead(b, a)) return { over: true, winner: null, team: ahead(a, b) ? 0 : 1, early: false, forfeit: false };
    if (s.tiebreaks >= MAX_TIEBREAKS) return { over: true, winner: null, team: null, early: false, forfeit: false };
    return { over: false, next: { round, tiebreak: true, players: active } };
  }
  if (active.length <= 1) return { over: true, winner: active[0] ?? null, early: false, forfeit: true };
  if (s.played < s.settings.rounds) return { over: false, next: { round, tiebreak: false, players: active } };
  const racing = s.racers.filter((r) => !r.out);
  const leaders = racing.filter((r) => !racing.some((o) => ahead(o, r))).map((r) => r.id);
  if (leaders.length === 1) return { over: true, winner: leaders[0]!, early: false, forfeit: false };
  if (s.tiebreaks >= MAX_TIEBREAKS) return { over: true, winner: null, early: false, forfeit: false };
  return { over: false, next: { round, tiebreak: true, players: leaders } };
}

/** How a game ends when it has to stop now (the room is closing): as decided if it is, otherwise with no winner. */
export function stopRuneSeries(s: RuneSeries): VsSeriesOutcome {
  const d = runeDecision(s);
  const team = s.teams === undefined ? {} : { team: d.over ? (d.team ?? null) : null };
  return d.over ? { winner: d.winner, early: false, forfeit: d.forfeit, ...team } : { winner: null, early: false, forfeit: false, ...team };
}

/** Everyone's points over the game. */
export function totalsOf(s: RuneSeries): Record<string, number> {
  return Object.fromEntries(s.racers.map((r) => [r.id, r.points]));
}

/** `ROUND_START` for Rune Rush (and the round in a SNAPSHOT). */
export interface RuneRoundStartFields {
  readonly game: "rune";
  readonly round: number;
  /** The regular rounds in the game. */
  readonly rounds: RuneRounds;
  readonly tiebreak: boolean;
  readonly players: readonly string[];
  readonly size: RuneSize;
  readonly tiles: readonly string[];
  readonly min: RuneMin;
  readonly seconds: RuneSeconds;
  readonly startsAt: number;
  readonly endsAt: number;
  readonly serverNow: number;
  readonly heat: HeatTier;
  /** Points over the game so far. */
  readonly totals: Readonly<Record<string, number>>;
  /** Teams only. */
  readonly teams?: Readonly<Record<string, TeamId>>;
  readonly teamScoring?: RuneTeamScoring;
  readonly teamTotals?: readonly [number, number];
}

export function runeRoundStartFields(r: RuneRound, s: RuneSeries, serverNow: number): RuneRoundStartFields {
  return {
    game: "rune",
    round: r.round,
    rounds: s.settings.rounds,
    tiebreak: r.tiebreak,
    players: r.playerIds,
    size: r.size,
    tiles: r.tiles,
    min: r.min,
    seconds: s.settings.seconds,
    startsAt: r.startsAt,
    endsAt: r.endsAt,
    serverNow,
    heat: r.heat,
    totals: totalsOf(s),
    ...(s.teams === undefined ? {} : { teams: s.teams.of, teamScoring: s.teams.scoring, teamTotals: s.teams.points }),
  };
}

/** A word found, as a SNAPSHOT lists the receiver's (pooled teams: their team's). */
export interface RuneMineWord {
  readonly word: string;
  readonly by: string;
  readonly points: number;
}

export interface RuneRoundSnapshot extends RuneRoundStartFields {
  readonly mine: readonly RuneMineWord[];
  readonly tally: Readonly<Record<string, number>>;
}

export function runeRoundSnapshot(r: RuneRound, s: RuneSeries, receiver: string, serverNow: number): RuneRoundSnapshot {
  const team = [receiver, ...teammatesOf(s, receiver)];
  return {
    ...runeRoundStartFields(r, s, serverNow),
    mine: r.finds.filter(([by]) => team.includes(by)).map(([by, word]) => ({ word, by, points: wordPoints(word) })),
    tally: tallyOf(r),
  };
}

/** `ROUND_END` for Rune Rush (and the standings in a SNAPSHOT). */
export interface RuneRoundEndFields extends RuneRoundSummary {
  readonly game: "rune";
  readonly totals: Readonly<Record<string, number>>;
  readonly teamTotals?: readonly [number, number];
  /** The next round (`null`: the game is over). */
  readonly next: RuneNextRound | null;
  readonly standingsEndsAt: number | null;
}

export interface RuneRoundEnd {
  readonly fields: RuneRoundEndFields;
  /** The game is over (decided, or stopped): `null` while it goes on to `fields.next`. */
  readonly outcome: VsSeriesOutcome | null;
}

/**
 * Ends the round now: scores it, adds it to the game (and its history), and
 * decides what comes next. With `stop` the game ends here whatever the
 * score (the room is closing). The standings would run until
 * `now + standingsMs`.
 */
export function endRuneRound(s: RuneSeries, r: RuneRound, now: number, standingsMs: number, stop = false): RuneRoundEnd {
  const score = scoreRound(r, s.teams === undefined ? undefined : { of: s.teams.of, scoring: s.teams.scoring });
  for (const racer of s.racers) {
    if (!r.playerIds.includes(racer.id)) continue;
    const mine = score.found[racer.id] ?? [];
    racer.rounds += 1;
    racer.points += score.points[racer.id] ?? 0;
    racer.words += mine.length;
    for (const { word } of mine) if (word.length > racer.longest.length) racer.longest = word;
  }
  // The round's winner, among those who played it and are still in.
  let winner: string | null = null;
  let team: TeamId | null | undefined;
  if (s.teams !== undefined) {
    const teams = s.teams;
    for (const racer of s.racers) {
      if (!r.playerIds.includes(racer.id) || racer.team === undefined) continue;
      teams.points[racer.team] += score.points[racer.id] ?? 0;
      teams.words[racer.team] += score.found[racer.id]?.length ?? 0;
    }
    const [a, b] = score.teamPoints!;
    team = a === b ? null : a > b ? 0 : 1;
    if (team !== null) {
      teams.wins[team] += 1;
      for (const racer of s.racers) if (racer.team === team && r.playerIds.includes(racer.id)) racer.wins += 1;
    }
  } else {
    const contenders = r.playerIds.filter((id) => canRuneRace(s, id));
    const entry = (id: string) => ({ points: score.points[id] ?? 0, words: score.found[id]?.length ?? 0 });
    const best = contenders.filter((id) => !contenders.some((o) => ahead(entry(o), entry(id))));
    if (best.length === 1 && entry(best[0]!).points > 0) winner = best[0]!;
    const racer = s.racers.find((x) => x.id === winner);
    if (racer !== undefined) racer.wins += 1;
  }
  s.played += 1;
  if (r.tiebreak) s.tiebreaks += 1;
  const summary: RuneRoundSummary = {
    round: r.round,
    tiebreak: r.tiebreak,
    size: r.size,
    tiles: r.tiles,
    found: score.found,
    points: score.points,
    ...(score.teamPoints === undefined ? {} : { teamPoints: score.teamPoints, team: team ?? null }),
    winner,
    words: r.words.slice(0, MAX_LISTED_WORDS),
    total: r.words.length,
  };
  s.history.push(summary);

  const decision = runeDecision(s);
  const outcome = decision.over
    ? { winner: decision.winner, early: false, forfeit: decision.forfeit, ...(decision.team === undefined ? {} : { team: decision.team }) }
    : stop
      ? stopRuneSeries(s)
      : null;
  return {
    fields: {
      game: "rune",
      ...summary,
      totals: totalsOf(s),
      ...(s.teams === undefined ? {} : { teamTotals: [...s.teams.points] as [number, number] }),
      next: outcome === null && !decision.over ? decision.next : null,
      standingsEndsAt: outcome === null ? now + standingsMs : null,
    },
    outcome,
  };
}

/**
 * The finished game in the Versus results shape, so it's written (XP,
 * stats, the match) as a Versus series is: `score` is the points, `wins`
 * the rounds won, `words` the words found; no bonus words or embers.
 * Ranked on points, then words; teams by the team's.
 */
export function runeSeriesResults(s: RuneSeries, outcome: VsSeriesOutcome): VsSeriesResults {
  const result = (r: RuneRacer, place: number): VsPlayerResult => ({
    id: r.id,
    wins: r.wins,
    place,
    rounds: r.rounds,
    words: r.words,
    longest: r.longest,
    bonus: 0,
    pickups: noHints(),
    ...(r.team === undefined ? {} : { team: r.team }),
    score: r.points,
  });
  const base = { ...outcome, scoring: "total" as const, rounds: s.played, ...(s.tiebreaks > 0 && (outcome.winner !== null || outcome.team != null) ? { tiebreak: true as const } : {}) };
  if (s.teams !== undefined) {
    const winner = outcome.team ?? null;
    const placeOf = (team: TeamId | undefined) => (winner === null || team === winner ? 1 : 2);
    const ordered = [...s.racers].sort((a, b) => placeOf(a.team) - placeOf(b.team) || (a.team ?? 0) - (b.team ?? 0) || b.points - a.points);
    return { ...base, team: winner, teamTally: [s.teams.wins[0], s.teams.wins[1]], players: ordered.map((r) => result(r, placeOf(r.team))) };
  }
  // The winner first (a forfeit can leave them behind on points), then by points and words.
  const rest = s.racers.filter((r) => r.id !== outcome.winner).sort((a, b) => b.points - a.points || b.words - a.words);
  const top = s.racers.find((r) => r.id === outcome.winner);
  const ordered = top === undefined ? rest : [top, ...rest];
  return {
    ...base,
    players: ordered.map((r) => result(r, r === top ? 1 : 1 + ordered.filter((o) => o !== r && (o === top || ahead(o, r))).length)),
  };
}

/** `SERIES_END.rune`: what a Rune Rush game adds to the Versus shape. */
export interface RuneSeriesEndFields {
  readonly settings: RuneSettings;
  /** Every round, in order. */
  readonly history: readonly RuneRoundSummary[];
  /** Each racer's words found over the game (the podium's `score` is their points). */
  readonly words: Readonly<Record<string, number>>;
  /** Teams only: each team's points and words over the game. */
  readonly teamTotals?: readonly [number, number];
  readonly teamWords?: readonly [number, number];
}

export function runeSeriesEndFields(s: RuneSeries): RuneSeriesEndFields {
  return {
    settings: s.settings,
    history: s.history,
    words: Object.fromEntries(s.racers.map((r) => [r.id, r.words])),
    ...(s.teams === undefined ? {} : { teamTotals: [...s.teams.points] as [number, number], teamWords: [...s.teams.words] as [number, number] }),
  };
}
