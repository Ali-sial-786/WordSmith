/**
 * Reading and writing what `POST /v1/solo/sync` needs.
 *
 * Writes are optimistic: every statement in the batch only applies while
 * `profiles.updated_at` still has the value we read, and the last one moves
 * it on. If another write to the profile got in between, nothing changes
 * and {@link writeSync} returns false, so the caller re-reads and tries again.
 * That stops two overlapping syncs (a retry, or two phones) from granting
 * the same stage twice or losing each other's XP.
 *
 * The same batch adds the accepted entries to the player's Work Orders
 * (src/db/orders.ts), and records Masterwork rewards as their own
 * `xp_events` (`source: "masterwork"`), so their XP counts towards the
 * Weekly Trials like the rest (migrations/0005_forge_board.sql).
 */

import type { Account } from "./accounts";
import { orderProgress } from "./orders";
import { levelFromTotalXp } from "../rules/progression";
import type { SoloState, SyncOutcome } from "../rules/sync";

/** The solo state of `account`, with the stages among `stages` already counted. */
export async function loadSoloState(db: D1Database, account: Account, stages: readonly number[]): Promise<SoloState> {
  const [done, seeds] = await db.batch<{ stage?: number; seed?: string }>([
    db
      .prepare("SELECT stage FROM solo_results WHERE user_id = ?1 AND stage IN (SELECT value FROM json_each(?2))")
      .bind(account.id, JSON.stringify([...new Set(stages)])),
    db.prepare("SELECT seed FROM pickup_seeds WHERE user_id = ?1").bind(account.id),
  ]);
  return {
    totalXp: account.totalXp,
    scrapBin: account.scrapBin,
    hints: account.hints,
    campaignCompleted: account.campaignCompleted,
    wordsForged: account.stats.wordsForged,
    longestWord: account.stats.longestWord,
    soloDone: account.stats.soloDone,
    masterworkPieces: account.masterworkPieces,
    completedStages: new Set(done!.results.map((r) => r.stage!)),
    installSeeds: new Set(seeds!.results.map((r) => r.seed!)),
  };
}

/** Only true while the profile is still at the version we read. */
const UNCHANGED = "EXISTS (SELECT 1 FROM profiles WHERE user_id = ?1 AND updated_at = ?2)";

/**
 * Writes an outcome's accepted entries and new totals in one transaction,
 * if the profile is still at `account.version`. Returns false (and writes
 * nothing) if it isn't.
 */
export async function writeSync(db: D1Database, account: Account, outcome: SyncOutcome, now: number): Promise<boolean> {
  const uid = account.id;
  const version = account.version;
  const s = outcome.state;
  const accepted = JSON.stringify(outcome.accepted);
  const masterworks = JSON.stringify(outcome.accepted.flatMap((a) => a.masterworks));
  const nextVersion = Math.max(now, version + 1);

  const statements = [
    db
      .prepare(
        `INSERT INTO solo_results (user_id, stage, completed_at)
         SELECT ?1, json_extract(j.value, '$.stage'), json_extract(j.value, '$.completedAt')
           FROM json_each(?3) AS j WHERE ${UNCHANGED}`,
      )
      .bind(uid, version, accepted),
    db
      .prepare(
        `INSERT INTO xp_events (user_id, source, amount, ref, created_at)
         SELECT ?1, 'solo', json_extract(j.value, '$.xp'), json_extract(j.value, '$.puzzleId'), ?4
           FROM json_each(?3) AS j WHERE ${UNCHANGED}`,
      )
      .bind(uid, version, accepted, now),
    db
      .prepare(
        `INSERT INTO xp_events (user_id, source, amount, ref, created_at)
         SELECT ?1, 'masterwork', json_extract(j.value, '$.xp'), json_extract(j.value, '$.id'), ?4
           FROM json_each(?3) AS j WHERE ${UNCHANGED}`,
      )
      .bind(uid, version, masterworks, now),
    db
      .prepare(
        `INSERT INTO pickup_seeds (user_id, seed, first_used_at)
         SELECT ?1, j.value, ?4 FROM json_each(?3) AS j WHERE ${UNCHANGED}
         ON CONFLICT (user_id, seed) DO NOTHING`,
      )
      .bind(uid, version, JSON.stringify(outcome.newInstallSeeds), now),
    db
      .prepare(
        `INSERT INTO inventory (user_id, item, count)
         SELECT ?1, j.key, j.value FROM json_each(?3) AS j WHERE ${UNCHANGED}
         ON CONFLICT (user_id, item) DO UPDATE SET count = excluded.count`,
      )
      .bind(uid, version, JSON.stringify(s.hints)),
    db
      .prepare(`UPDATE stats SET words_forged = ?3, longest_word = ?4, solo_done = ?5 WHERE user_id = ?1 AND ${UNCHANGED}`)
      .bind(uid, version, s.wordsForged, s.longestWord === "" ? null : s.longestWord, s.soloDone),
    ...orderProgress(db, uid, version, outcome.facts, now),
    // Last, because it moves the version the statements above check.
    db
      .prepare(
        `UPDATE profiles SET xp = ?3, level = ?4, campaign_stage = ?5, scrap_bin = ?6, masterwork_pieces = ?7, updated_at = ?8
          WHERE user_id = ?1 AND updated_at = ?2`,
      )
      .bind(uid, version, s.totalXp, levelFromTotalXp(s.totalXp), s.campaignCompleted, s.scrapBin, s.masterworkPieces, nextVersion),
  ];

  try {
    const results = await db.batch(statements);
    return results.at(-1)?.meta.changes === 1;
  } catch (err) {
    // A concurrent sync already inserted one of these stages.
    if (String(err).includes("UNIQUE")) return false;
    throw err;
  }
}
