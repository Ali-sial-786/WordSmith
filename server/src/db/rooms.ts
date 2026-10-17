/**
 * D1 queries for rooms: choosing a bank puzzle, remembering who has seen
 * it, spending and granting hints, and writing a finished co-op round
 * (docs/TECH.md §6–§7).
 *
 * Every write that changes a player's hint stock or XP also moves
 * `profiles.updated_at` on, so a solo sync that read the profile before it
 * notices and retries instead of overwriting the change (src/db/sync.ts).
 */

import { coopAward, type CoopResults } from "../rules/coop-round";
import type { HeatTier } from "../rules/heat";
import { parseMpPuzzle, type MpPuzzle } from "../rules/mold";
import { HINT_KINDS, levelFromTotalXp, noHints, type HintKind } from "../rules/progression";
import type { RoomMode } from "../rules/room";
import type { XpBody } from "../room/protocol";

// ---------------------------------------------------------------------------
// Puzzles
// ---------------------------------------------------------------------------

export interface PuzzleChoice {
  readonly heat: HeatTier;
  readonly size: number;
  readonly playerIds: readonly string[];
  /** Puzzles any player saw after this (epoch ms) are skipped if possible. */
  readonly seenSince: number;
}

/**
 * A random bank puzzle for the team. Prefers, in order: the right heat,
 * the right size (or the nearest), not seen by any player since
 * `seenSince` (else the one they saw longest ago). `null` if the bank is empty.
 */
export async function pickPuzzle(db: D1Database, choice: PuzzleChoice): Promise<MpPuzzle | null> {
  // `last`: when any of the players last had it. Recent ones go last, oldest first.
  const select = `SELECT p.data,
                         (SELECT MAX(s.seen_at) FROM puzzle_seen s
                           WHERE s.puzzle_id = p.id AND s.user_id IN (SELECT value FROM json_each(?3))) AS last
                    FROM puzzles p`;
  const recent = "(last IS NOT NULL AND last > ?4)";
  const ids = JSON.stringify(choice.playerIds);
  const row =
    (await db
      .prepare(
        `${select} WHERE p.pool = 'mp' AND p.heat = ?1
          ORDER BY abs(p.size - ?2), ${recent}, CASE WHEN ${recent} THEN last ELSE 0 END, random() LIMIT 1`,
      )
      .bind(choice.heat, choice.size, ids, choice.seenSince)
      .first<{ data: string }>()) ??
    // Nothing at this heat at all: take the nearest heat rather than fail.
    (await db
      .prepare(`${select} WHERE p.pool = 'mp' ORDER BY abs(p.heat - ?1), abs(p.size - ?2), ${recent}, random() LIMIT 1`)
      .bind(choice.heat, choice.size, ids, choice.seenSince)
      .first<{ data: string }>());
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
}

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
 * Writes a finished round in one D1 batch: the `matches` row, and for each
 * player their `match_players` row, XP (`xp_events`, profile and level),
 * stats, Scrap Bin, and level-up and Scrap Bin hints.
 *
 * Safe to repeat: a player who already has a row for this match is skipped.
 * Each player's statements only apply while their profile is still at the
 * version read, so a concurrent solo sync can't be overwritten; players
 * whose profile changed are retried. Players with no profile (deleted
 * accounts) are left out. Returns each written player's XP.
 */
export async function writeCoopRound(db: D1Database, record: CoopRoundRecord, now: number): Promise<Record<string, XpBody>> {
  const { results, matchId } = record;
  const out: Record<string, XpBody> = {};
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
  });

  let pending = results.players.map((p) => p.id);
  for (let attempt = 1; attempt <= MAX_ATTEMPTS && pending.length > 0; attempt++) {
    const { results: rows } = await db
      .prepare(
        `SELECT p.user_id, p.xp, p.scrap_bin, p.updated_at,
                (SELECT xp FROM match_players m WHERE m.match_id = ?1 AND m.user_id = p.user_id) AS awarded
           FROM profiles p WHERE p.user_id IN (SELECT value FROM json_each(?2))`,
      )
      .bind(matchId, JSON.stringify(pending))
      .all<ProfileRow>();

    const statements: D1PreparedStatement[] = [
      db
        .prepare("INSERT OR IGNORE INTO matches (id, mode, code, started_at, ended_at, summary) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
        .bind(matchId, record.mode, record.code, record.startedAt, record.endedAt, summary),
    ];
    const profileStatement = new Map<string, number>();
    const awards = new Map<string, XpBody>();

    for (const row of rows) {
      const player = results.players.find((p) => p.id === row.user_id)!;
      if (row.awarded !== null) {
        // Written by an earlier attempt; the level-up details are gone, but the XP isn't.
        out[row.user_id] = { xp: row.awarded, level: levelFromTotalXp(row.xp), levelUps: 0, rewards: noHints(), scrapHammers: 0 };
        continue;
      }
      const award = coopAward(player, results, { totalXp: row.xp, scrapBin: row.scrap_bin });
      const gained = { ...award.xp.rewards };
      gained.hammer += award.scrap.hammers;
      const uid = row.user_id;
      const version = row.updated_at;
      const guard = "EXISTS (SELECT 1 FROM profiles WHERE user_id = ?1 AND updated_at = ?2)";
      statements.push(
        db
          .prepare(`INSERT INTO xp_events (user_id, source, amount, ref, created_at) SELECT ?1, 'coop', ?3, ?4, ?5 WHERE ${guard}`)
          .bind(uid, version, award.amount, matchId, now),
        db
          .prepare(
            `INSERT INTO inventory (user_id, item, count)
             SELECT ?1, j.key, j.value FROM json_each(?3) AS j WHERE j.value > 0 AND ${guard}
             ON CONFLICT (user_id, item) DO UPDATE SET count = count + excluded.count`,
          )
          .bind(uid, version, JSON.stringify(Object.fromEntries(HINT_KINDS.map((k) => [k, gained[k]])))),
        db
          .prepare(
            `UPDATE stats SET coop_rounds = coop_rounds + 1, coop_mvps = coop_mvps + ?3,
                    words_forged = words_forged + ?4,
                    longest_word = CASE WHEN length(?5) > length(COALESCE(longest_word, '')) THEN ?5 ELSE longest_word END
              WHERE user_id = ?1 AND ${guard}`,
          )
          .bind(uid, version, results.mvp === uid ? 1 : 0, player.words, player.longest),
        db
          .prepare(
            `INSERT INTO match_players (match_id, user_id, placement, points, rounds_won, xp)
             SELECT ?3, ?1, ?4, ?5, 0, ?6 WHERE ${guard}
             ON CONFLICT (match_id, user_id) DO NOTHING`,
          )
          .bind(uid, version, matchId, places.get(uid) ?? null, player.points, award.amount),
      );
      // Last, because it moves the version the statements above check.
      profileStatement.set(uid, statements.length);
      statements.push(
        db
          .prepare("UPDATE profiles SET xp = ?3, level = ?4, scrap_bin = ?5, updated_at = ?6 WHERE user_id = ?1 AND updated_at = ?2")
          .bind(uid, version, award.xp.totalXp, award.xp.level, award.scrap.bin, Math.max(now, version + 1)),
      );
      awards.set(uid, {
        xp: award.amount,
        level: award.xp.level,
        levelUps: award.xp.levelsGained,
        rewards: award.xp.rewards,
        scrapHammers: award.scrap.hammers,
      });
    }

    const written = await db.batch(statements);
    const retry: string[] = [];
    for (const [uid, index] of profileStatement) {
      if (written[index]?.meta.changes === 1) out[uid] = awards.get(uid)!;
      else retry.push(uid);
    }
    pending = retry;
  }
  return out;
}
