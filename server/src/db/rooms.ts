/**
 * D1 queries for rooms: choosing a bank puzzle, remembering who has seen
 * it, spending and granting hints, and writing a finished co-op round or
 * Versus series (docs/TECH.md §6–§7).
 *
 * Every write that changes a player's hint stock or XP also moves
 * `profiles.updated_at` on, so a solo sync that read the profile before it
 * notices and retries instead of overwriting the change (src/db/sync.ts).
 * A finished match also counts towards each player's Work Orders
 * (src/db/orders.ts), in the same batch.
 */

import { orderProgress } from "./orders";
import { coopAward, type CoopResults } from "../rules/coop-round";
import type { HeatTier } from "../rules/heat";
import { parseMpPuzzle, type MpPuzzle } from "../rules/mold";
import { HINT_KINDS, levelFromTotalXp, noHints, type HintCounts, type HintKind } from "../rules/progression";
import type { PlayFacts } from "../rules/orders";
import { choosePuzzle, type PuzzleCandidate, type RoomMode } from "../rules/room";
import type { SeriesLength } from "../rules/vs";
import { vsAward, wonSeries, type VsSeriesResults } from "../rules/vs-round";
import type { TeamRule } from "../rules/teams";
import type { VsXpBody, XpBody } from "../room/protocol";

// ---------------------------------------------------------------------------
// Puzzles
// ---------------------------------------------------------------------------

export interface PuzzleChoice {
  readonly heat: HeatTier;
  readonly size: number;
  /** Everyone who will see the answers: their recent puzzles are skipped if possible. */
  readonly playerIds: readonly string[];
  /** Puzzles any player saw after this (epoch ms) are skipped if possible. */
  readonly seenSince: number;
  /** The room's own latest puzzles, skipped unless nothing else is left (so a series never repeats one). */
  readonly avoid?: readonly string[];
  /** For tests; `Math.random` otherwise. */
  readonly rand?: () => number;
}

/**
 * A random bank puzzle for the team, from the right heat and size, or the
 * nearest size at that heat, or (no puzzle at that heat at all) the
 * nearest heat. Among those it's random: one nobody in the room has seen
 * since `seenSince`, else one of the third they saw longest ago (rules/room.ts
 * `choosePuzzle`). `null` if the bank is empty.
 */
export async function pickPuzzle(db: D1Database, choice: PuzzleChoice): Promise<MpPuzzle | null> {
  // `last`: when any of the players last had it.
  const candidates = (heat: number, size: number) =>
    db
      .prepare(
        `SELECT p.id,
                (SELECT MAX(s.seen_at) FROM puzzle_seen s
                  WHERE s.puzzle_id = p.id AND s.user_id IN (SELECT value FROM json_each(?3))) AS last
           FROM puzzles p WHERE p.pool = 'mp' AND p.heat = ?1 AND p.size = ?2`,
      )
      .bind(heat, size, JSON.stringify(choice.playerIds))
      .all<PuzzleCandidate>();

  let { results } = await candidates(choice.heat, choice.size);
  if (results.length === 0) {
    // None of this size and heat: the nearest size at this heat, or else the nearest heat, rather than fail.
    const nearest = await db
      .prepare("SELECT heat, size FROM puzzles WHERE pool = 'mp' ORDER BY abs(heat - ?1), heat, abs(size - ?2), size LIMIT 1")
      .bind(choice.heat, choice.size)
      .first<{ heat: number; size: number }>();
    if (nearest === null) return null;
    ({ results } = await candidates(nearest.heat, nearest.size));
  }
  const id = choosePuzzle(results, choice.seenSince, choice.avoid ?? [], choice.rand ?? Math.random);
  const row = id === null ? null : await db.prepare("SELECT data FROM puzzles WHERE id = ?1").bind(id).first<{ data: string }>();
  return row === null ? null : parseMpPuzzle(JSON.parse(row.data));
}

/** Records that these players have had this puzzle (for the 60-day repeat check). */
export async function recordSeen(db: D1Database, puzzleId: string, playerIds: readonly string[], now: number): Promise<void> {
  await db
    .prepare(
      `INSERT INTO puzzle_seen (user_id, puzzle_id, seen_at)
       SELECT value, ?1, ?2 FROM json_each(?3) WHERE true
       ON CONFLICT (user_id, puzzle_id) DO UPDATE SET seen_at = excluded.seen_at`,
    )
    .bind(puzzleId, now, JSON.stringify(playerIds))
    .run();
}

// ---------------------------------------------------------------------------
// Hints
// ---------------------------------------------------------------------------

const bump = (db: D1Database, uid: string, now: number) =>
  db.prepare("UPDATE profiles SET updated_at = MAX(updated_at + 1, ?2) WHERE user_id = ?1").bind(uid, now);

/** Takes one hint from the player's stock. False if they have none (nothing changes). */
export async function spendHint(db: D1Database, uid: string, kind: HintKind, now: number): Promise<boolean> {
  const [spent] = await db.batch([
    db.prepare("UPDATE inventory SET count = count - 1 WHERE user_id = ?1 AND item = ?2 AND count > 0").bind(uid, kind),
    bump(db, uid, now),
  ]);
  return (spent?.meta.changes ?? 0) === 1;
}

/** Adds one hint to the player's stock (an ember, or a refund). */
export async function grantHint(db: D1Database, uid: string, kind: HintKind, now: number): Promise<void> {
  await db.batch([
    db
      .prepare(
        `INSERT INTO inventory (user_id, item, count) VALUES (?1, ?2, 1)
         ON CONFLICT (user_id, item) DO UPDATE SET count = count + 1`,
      )
      .bind(uid, kind),
    bump(db, uid, now),
  ]);
}

// ---------------------------------------------------------------------------
// Writing a finished match (a co-op round, or a Versus series)
// ---------------------------------------------------------------------------

interface ProfileRow {
  user_id: string;
  xp: number;
  scrap_bin: number;
  updated_at: number;
  /** This match's XP if the player already has a `match_players` row for it. */
  awarded: number | null;
}

/** Most attempts at players whose profile keeps changing under us. */
const MAX_ATTEMPTS = 3;

/** The `matches` row. */
interface MatchRow {
  readonly matchId: string;
  readonly mode: RoomMode;
  readonly code: string;
  readonly startedAt: number;
  readonly endedAt: number;
  /** JSON. */
  readonly summary: string;
}

/** One player's share of a match, worked out from their profile as it was read. */
interface PlayerWrite<B> {
  /** XP gained (`xp_events.amount`, `match_players.xp`). */
  readonly xp: number;
  readonly totalXp: number;
  readonly level: number;
  readonly scrapBin: number;
  /** Hints to add to their stock. */
  readonly gained: Readonly<HintCounts>;
  readonly placement: number | null;
  readonly points: number;
  readonly roundsWon: number;
  /** The `SET` list for their `stats` row; it may use `?3`, `?4`, … bound to {@link statsBinds}. */
  readonly statsSet: string;
  readonly statsBinds: readonly (string | number)[];
  /** What the match counts towards their Work Orders. */
  readonly facts: PlayFacts;
  /** What the caller gets back for them. */
  readonly body: B;
}

/**
 * Writes a finished match in one D1 batch: the `matches` row, and for each
 * player their `match_players` row, XP (`xp_events` with the mode as
 * source, profile and level), stats, Scrap Bin, hints won and Work Orders.
 *
 * Safe to repeat: a player who already has a row for this match is skipped
 * (`earlier` describes them from what's left). Each player's statements
 * only apply while their profile is still at the version read, so a
 * concurrent solo sync can't be overwritten; players whose profile changed
 * are retried. Players with no profile (deleted accounts) are left out.
 */
async function writeMatch<B>(
  db: D1Database,
  match: MatchRow,
  playerIds: readonly string[],
  now: number,
  plan: (uid: string, profile: { readonly totalXp: number; readonly scrapBin: number }) => PlayerWrite<B>,
  earlier: (awardedXp: number, totalXp: number) => B,
): Promise<Record<string, B>> {
  const out: Record<string, B> = {};
  let pending = [...playerIds];
  for (let attempt = 1; attempt <= MAX_ATTEMPTS && pending.length > 0; attempt++) {
    const { results: rows } = await db
      .prepare(
        `SELECT p.user_id, p.xp, p.scrap_bin, p.updated_at,
                (SELECT xp FROM match_players m WHERE m.match_id = ?1 AND m.user_id = p.user_id) AS awarded
           FROM profiles p WHERE p.user_id IN (SELECT value FROM json_each(?2))`,
      )
      .bind(match.matchId, JSON.stringify(pending))
      .all<ProfileRow>();

    const statements: D1PreparedStatement[] = [
      db
        .prepare("INSERT OR IGNORE INTO matches (id, mode, code, started_at, ended_at, summary) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
        .bind(match.matchId, match.mode, match.code, match.startedAt, match.endedAt, match.summary),
    ];
    const profileStatement = new Map<string, number>();
    const bodies = new Map<string, B>();

    for (const row of rows) {
      const uid = row.user_id;
      if (row.awarded !== null) {
        // Written by an earlier attempt; the level-up details are gone, but the XP isn't.
        out[uid] = earlier(row.awarded, row.xp);
        continue;
      }
      const w = plan(uid, { totalXp: row.xp, scrapBin: row.scrap_bin });
      const version = row.updated_at;
      const guard = "EXISTS (SELECT 1 FROM profiles WHERE user_id = ?1 AND updated_at = ?2)";
      statements.push(
        db
          .prepare(`INSERT INTO xp_events (user_id, source, amount, ref, created_at) SELECT ?1, ?3, ?4, ?5, ?6 WHERE ${guard}`)
          .bind(uid, version, match.mode, w.xp, match.matchId, now),
        db
          .prepare(
            `INSERT INTO inventory (user_id, item, count)
             SELECT ?1, j.key, j.value FROM json_each(?3) AS j WHERE j.value > 0 AND ${guard}
             ON CONFLICT (user_id, item) DO UPDATE SET count = count + excluded.count`,
          )
          .bind(uid, version, JSON.stringify(Object.fromEntries(HINT_KINDS.map((k) => [k, w.gained[k]])))),
        db.prepare(`UPDATE stats SET ${w.statsSet} WHERE user_id = ?1 AND ${guard}`).bind(uid, version, ...w.statsBinds),
        db
          .prepare(
            `INSERT INTO match_players (match_id, user_id, placement, points, rounds_won, xp)
             SELECT ?3, ?1, ?4, ?5, ?6, ?7 WHERE ${guard}
             ON CONFLICT (match_id, user_id) DO NOTHING`,
          )
          .bind(uid, version, match.matchId, w.placement, w.points, w.roundsWon, w.xp),
        ...orderProgress(db, uid, version, w.facts, now),
      );
      // Last, because it moves the version the statements above check.
      profileStatement.set(uid, statements.length);
      statements.push(
        db
          .prepare("UPDATE profiles SET xp = ?3, level = ?4, scrap_bin = ?5, updated_at = ?6 WHERE user_id = ?1 AND updated_at = ?2")
          .bind(uid, version, w.totalXp, w.level, w.scrapBin, Math.max(now, version + 1)),
      );
      bodies.set(uid, w.body);
    }

    const written = await db.batch(statements);
    const retry: string[] = [];
    for (const [uid, index] of profileStatement) {
      if (written[index]?.meta.changes === 1) out[uid] = bodies.get(uid)!;
      else retry.push(uid);
    }
    pending = retry;
  }
  return out;
}

/** Keeps the longer of the stored longest word and `?n`. */
const longestWordSet = (n: number) => `longest_word = CASE WHEN length(?${n}) > length(COALESCE(longest_word, '')) THEN ?${n} ELSE longest_word END`;

// ---------------------------------------------------------------------------
// A finished co-op round
// ---------------------------------------------------------------------------

/** Everything needed to write a round's results, kept in the room until written. */
export interface CoopRoundRecord {
  readonly matchId: string;
  readonly mode: RoomMode;
  readonly code: string;
  readonly puzzleId: string;
  readonly heat: HeatTier;
  readonly round: number;
  readonly startedAt: number;
  readonly endedAt: number;
  readonly results: CoopResults;
  /** The grid words each player forged, for their Work Orders. Absent in records stored before them. */
  readonly forged?: Readonly<Record<string, readonly string[]>>;
}

/** 1-based places by points; equal points share a place. */
function placements(results: CoopResults): Map<string, number> {
  const sorted = [...results.players].sort((a, b) => b.points - a.points);
  const places = new Map<string, number>();
  sorted.forEach((p, i) => {
    const prev = sorted[i - 1];
    places.set(p.id, prev !== undefined && prev.points === p.points ? places.get(prev.id)! : i + 1);
  });
  return places;
}

/**
 * Writes a finished co-op round (see {@link writeMatch}): stats are
 * `coop_rounds`, `coop_mvps`, `words_forged` and `longest_word`; hints won
 * are level-up rewards and Scrap Bin hammers. A survival round's XP has
 * its bonus for words saved, and all of it grows with the round's heat
 * (`coopAward`). Returns each written player's XP.
 */
export async function writeCoopRound(db: D1Database, record: CoopRoundRecord, now: number): Promise<Record<string, XpBody>> {
  const { results } = record;
  const places = placements(results);
  const summary = JSON.stringify({
    puzzleId: record.puzzleId,
    heat: record.heat,
    round: record.round,
    reason: results.reason,
    stars: results.stars,
    teamScore: results.teamScore,
    filled: results.filled,
    total: results.total,
    mvp: results.mvp,
    players: results.players.map(({ id, points, words, longest }) => ({ id, points, words, longest })),
    // Survival rounds only (shared/survival.md "Records").
    ...(results.variant === undefined ? {} : { variant: results.variant, saved: results.saved, melted: results.melted }),
  });
  const match = { matchId: record.matchId, mode: record.mode, code: record.code, startedAt: record.startedAt, endedAt: record.endedAt, summary };

  return writeMatch<XpBody>(
    db,
    match,
    results.players.map((p) => p.id),
    now,
    (uid, profile) => {
      const player = results.players.find((p) => p.id === uid)!;
      const award = coopAward(player, results, profile, record.heat);
      const gained = { ...award.xp.rewards };
      gained.hammer += award.scrap.hammers;
      return {
        xp: award.amount,
        totalXp: award.xp.totalXp,
        level: award.xp.level,
        scrapBin: award.scrap.bin,
        gained,
        placement: places.get(uid) ?? null,
        points: player.points,
        roundsWon: 0,
        statsSet: `coop_rounds = coop_rounds + 1, coop_mvps = coop_mvps + ?3, words_forged = words_forged + ?4, ${longestWordSet(5)}`,
        statsBinds: [results.mvp === uid ? 1 : 0, player.words, player.longest],
        facts: { coopRounds: 1, bonusWords: player.bonus, forged: record.forged?.[uid] ?? [] },
        body: {
          xp: award.amount,
          level: award.xp.level,
          levelUps: award.xp.levelsGained,
          rewards: award.xp.rewards,
          scrapHammers: award.scrap.hammers,
          heatBonus: award.heatBonus,
          tiersAbove: award.tiersAbove,
        },
      };
    },
    (xp, totalXp) => ({ xp, level: levelFromTotalXp(totalXp), levelUps: 0, rewards: noHints(), scrapHammers: 0, heatBonus: 0, tiersAbove: 0 }),
  );
}

// ---------------------------------------------------------------------------
// A finished Versus series
// ---------------------------------------------------------------------------

/** Everything needed to write a series' results, kept in the room until written. */
export interface VsSeriesRecord {
  readonly matchId: string;
  readonly code: string;
  readonly heat: HeatTier;
  readonly length: SeriesLength;
  readonly startedAt: number;
  readonly endedAt: number;
  readonly results: VsSeriesResults;
  /** The grid words each racer forged on their own molds, for their Work Orders. Absent in records stored before them. */
  readonly forged?: Readonly<Record<string, readonly string[]>>;
  /** Survival series only. */
  readonly variant?: "survival";
  /** Team Versus only: the rule its rounds were won by. */
  readonly rule?: TeamRule;
}

/**
 * Writes a finished series as one match (see {@link writeMatch}), for
 * everyone who raced in it, including racers who left: `vsSeriesXp` at
 * the series' heat (`vsAward`), level-up rewards, Scrap Bin hammers from the series' bonus words, the
 * embers collected, and stats `vs_series`, `vs_series_won`,
 * `vs_rounds_won`, `words_forged` and `longest_word`. `match_players` gets
 * the podium place and round wins. Team Versus is written the same way, as
 * a `vs` match whose summary adds `teams`, and a player wins the series
 * when their team does. Returns each written player's XP.
 */
export async function writeVsSeries(db: D1Database, record: VsSeriesRecord, now: number): Promise<Record<string, VsXpBody>> {
  const { results } = record;
  const summary = JSON.stringify({
    heat: record.heat,
    series: record.length,
    rounds: results.rounds,
    winner: results.winner,
    early: results.early,
    forfeit: results.forfeit,
    players: results.players.map(({ id, wins, place, rounds, words, longest }) => ({ id, wins, place, rounds, words, longest })),
    // Survival series only (shared/survival.md "Records").
    ...(record.variant === undefined ? {} : { variant: record.variant }),
    // Team Versus only: the rule, the winning team, and everyone's team.
    ...(results.team === undefined
      ? {}
      : {
          teams: {
            rule: record.rule ?? "combined",
            winner: results.team,
            members: Object.fromEntries(results.players.map((p) => [p.id, p.team ?? 0])),
          },
        }),
  });
  const match = { matchId: record.matchId, mode: "vs" as const, code: record.code, startedAt: record.startedAt, endedAt: record.endedAt, summary };

  return writeMatch<VsXpBody>(
    db,
    match,
    results.players.map((p) => p.id),
    now,
    (uid, profile) => {
      const player = results.players.find((p) => p.id === uid)!;
      const won = wonSeries(results, player);
      const award = vsAward(player, won, profile, record.heat);
      return {
        xp: award.amount,
        totalXp: award.xp.totalXp,
        level: award.xp.level,
        scrapBin: award.scrap.bin,
        gained: award.gained,
        placement: player.place,
        points: 0,
        roundsWon: player.wins,
        statsSet: `vs_series = vs_series + 1, vs_series_won = vs_series_won + ?3, vs_rounds_won = vs_rounds_won + ?4,
                   words_forged = words_forged + ?5, ${longestWordSet(6)}`,
        statsBinds: [won ? 1 : 0, player.wins, player.words, player.longest],
        facts: { vsSeries: 1, bonusWords: player.bonus, forged: record.forged?.[uid] ?? [] },
        body: {
          xp: award.amount,
          level: award.xp.level,
          levelUps: award.xp.levelsGained,
          rewards: award.xp.rewards,
          scrapHammers: award.scrap.hammers,
          heatBonus: award.heatBonus,
          tiersAbove: award.tiersAbove,
          pickups: { ...player.pickups },
        },
      };
    },
    (xp, totalXp) => ({ xp, level: levelFromTotalXp(totalXp), levelUps: 0, rewards: noHints(), scrapHammers: 0, heatBonus: 0, tiersAbove: 0, pickups: noHints() }),
  );
}
