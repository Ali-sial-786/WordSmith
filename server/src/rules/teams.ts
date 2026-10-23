/**
 * Team Versus rules (shared/room-protocol.md "Team Versus"): two teams,
 * Copper (0) and Cobalt (1), race the Versus way, each player on their own
 * mold, and a round is won by a team. Two ways to win a round, the room's
 * `rule`:
 *
 * - **combined:** a team's score is the letters its racers have filled,
 *   added up. A team whose every racer has filled their whole mold wins at
 *   once; at the timer the higher score wins, a tie going to the team that
 *   reached its score first.
 * - **first:** the first racer to fill their whole mold wins the round for
 *   their team; at the timer, the racer with the most letters does (a tie
 *   going to whoever got there first), as in Versus.
 *
 * Pure, like vs.ts: vs-round.ts applies these to a round and a series.
 */

import { resolveVsRound, type VsRoundHow, type VsRoundProgress } from "./vs";

export type TeamId = 0 | 1;
export const TEAMS: readonly TeamId[] = [0, 1];

export const TEAM_RULES = ["combined", "first"] as const;
export type TeamRule = (typeof TEAM_RULES)[number];
/** What a new room plays until the host picks (CONFIG `rule`). */
export const DEFAULT_TEAM_RULE: TeamRule = "combined";

/** Players a team can hold; two full teams fill the room. */
export const MAX_TEAM_SIZE = 3;

export function isTeamId(value: unknown): value is TeamId {
  return value === 0 || value === 1;
}

export function isTeamRule(value: unknown): value is TeamRule {
  return (TEAM_RULES as readonly unknown[]).includes(value);
}

/** How many of `ids` are on each team, as `[copper, cobalt]`. Ids without a team aren't counted. */
export function teamSizes(teams: Readonly<Record<string, TeamId>>, ids: readonly string[]): [number, number] {
  const sizes: [number, number] = [0, 0];
  for (const id of ids) {
    const team = teams[id];
    if (team !== undefined) sizes[team] += 1;
  }
  return sizes;
}

/** The team a newcomer joins: the smaller one, Copper on a tie. `null` when both are full. */
export function teamForNewcomer(teams: Readonly<Record<string, TeamId>>, ids: readonly string[]): TeamId | null {
  const [copper, cobalt] = teamSizes(teams, ids);
  if (copper >= MAX_TEAM_SIZE && cobalt >= MAX_TEAM_SIZE) return null;
  if (copper >= MAX_TEAM_SIZE) return 1;
  if (cobalt >= MAX_TEAM_SIZE) return 0;
  return cobalt < copper ? 1 : 0;
}

/** Whether a series can start with these players: both teams the same size, with at least one each. */
export function teamsEven(teams: Readonly<Record<string, TeamId>>, ids: readonly string[]): boolean {
  const [copper, cobalt] = teamSizes(teams, ids);
  return copper >= 1 && copper === cobalt && copper + cobalt === ids.length;
}

/** One racer's progress this round, with their team. */
export interface TeamRacerProgress extends VsRoundProgress {
  readonly team: TeamId;
}

export interface TeamRoundResult {
  /** The team that won the round, or `null` (nobody filled anything). */
  readonly team: TeamId | null;
  /** `first`: the racer whose finish (or lead) won it. `combined`: always `null`. */
  readonly winner: string | null;
  readonly how: VsRoundHow;
  /** Each team's letters, added up over `racers`, as `[copper, cobalt]`. */
  readonly scores: [number, number];
}

/** Each team's letters, added up, as `[copper, cobalt]`. */
export function teamScores(racers: readonly TeamRacerProgress[]): [number, number] {
  const scores: [number, number] = [0, 0];
  for (const r of racers) scores[r.team] += r.lettersFilled;
  return scores;
}

/**
 * Whether the round is over before the timer: `first`, someone has filled
 * their whole mold; `combined`, every racer on one team has.
 */
export function teamRoundDone(rule: TeamRule, totalLetters: number, racers: readonly TeamRacerProgress[]): boolean {
  if (rule === "first") return racers.some((r) => r.lettersFilled >= totalLetters);
  return TEAMS.some((team) => {
    const mine = racers.filter((r) => r.team === team);
    return mine.length > 0 && mine.every((r) => r.lettersFilled >= totalLetters);
  });
}

/**
 * Resolves a round that has just ended. Pass only the racers who can still
 * win it: the round's racers, without anyone who has left the series.
 */
export function resolveTeamRound(rule: TeamRule, totalLetters: number, racers: readonly TeamRacerProgress[]): TeamRoundResult {
  const scores = teamScores(racers);
  if (rule === "first") {
    const { winner, how } = resolveVsRound(totalLetters, racers);
    const team = racers.find((r) => r.playerId === winner)?.team ?? null;
    return { team, winner, how, scores };
  }

  const finished = TEAMS.filter((team) => {
    const mine = racers.filter((r) => r.team === team);
    return mine.length > 0 && mine.every((r) => r.lettersFilled >= totalLetters);
  });
  // Both teams finished (or both tied on letters): the one that got there first.
  const contenders = finished.length > 0 ? finished : TEAMS.filter((team) => scores[team] === Math.max(...scores));
  if (finished.length === 0 && Math.max(...scores) === 0) return { team: null, winner: null, how: "none", scores };
  const team = contenders.reduce((best, t) => (reachedAt(racers, t) < reachedAt(racers, best) ? t : best));
  return { team, winner: null, how: finished.length > 0 ? "finished" : "timeout", scores };
}

/** When a team reached its score: the latest change among its racers who have filled anything. */
function reachedAt(racers: readonly TeamRacerProgress[], team: TeamId): number {
  return Math.max(0, ...racers.filter((r) => r.team === team && r.lettersFilled > 0).map((r) => r.reachedAt));
}
