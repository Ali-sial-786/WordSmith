/**
 * D1 queries for Survival's solo runs, The Crucible (shared/survival.md,
 * migrations/0006_survival.sql): what `POST /v1/survival/solo` reads, and
 * writing a run.
 *
 * Writes are optimistic, like solo sync's (src/db/sync.ts): every statement
 * only applies while `profiles.updated_at` still has the value we read, and
 * the last one moves it on. A run already recorded (a retry racing the
 * first send) fails the batch on `survival_runs`' key, so it's never
 * counted twice.
 */

import type { Account } from "./accounts";
import { orderProgress } from "./orders";
import { levelFromTotalXp } from "../rules/progression";
import type { SurvivalAward, SurvivalRun } from "../rules/survival";

/** A run already recorded. */
export interface RecordedRun {
  /** When it ended. */
  readonly at: number;
  readonly puzzles: number;
  readonly words: number;
  readonly saved: number;
  /** XP it was given. */
  readonly xp: number;
}

export interface RunContext {
  /** This run, if it was recorded before. */
  readonly recorded: RecordedRun | null;
  /** The player's highest stage in `solo_results` (0 for none). */
  readonly highestSoloStage: number;
}

/** What checking a run needs besides the account: whether it's a repeat, and how far the player has got in the campaign. */
export async function loadRunContext(db: D1Database, uid: string, runId: string): Promise<RunContext> {
  const [run, highest] = await db.batch<Record<string, number>>([
    db.prepare("SELECT at, puzzles, words, saved, xp FROM survival_runs WHERE uid = ?1 AND run_id = ?2").bind(uid, runId),
    db.prepare("SELECT COALESCE(MAX(stage), 0) AS n FROM solo_results WHERE user_id = ?1").bind(uid),
  ]);
  const row = run!.results[0];
  return {
    recorded: row === undefined ? null : { at: row.at!, puzzles: row.puzzles!, words: row.words!, saved: row.saved!, xp: row.xp! },
    highestSoloStage: highest!.results[0]?.n ?? 0,
  };
}

/** Only true while the profile is still at the version we read. */
const UNCHANGED = "EXISTS (SELECT 1 FROM profiles WHERE user_id = ?1 AND updated_at = ?2)";

/**
 * Writes a checked run in one transaction, if the profile is still at
 * `account.version`: the `survival_runs` row, `xp_events` (`source:
 * "survival"`, `ref`: the run id), the hint stock, words forged and longest
 * word, the best run if this one beat it, Work Orders progress, and the
 * profile (XP, level). Returns false, writing nothing, if the profile
 * changed or the run was recorded meanwhile.
 */
export async function writeSurvivalRun(db: D1Database, account: Account, run: SurvivalRun, award: SurvivalAward, now: number): Promise<boolean> {
  const uid = account.id;
  const version = account.version;
  const s = award.state;
  const { score } = award;
  const best = s.best;
  const statements = [
    db
      .prepare(
        `INSERT INTO survival_runs (uid, run_id, at, puzzles, words, saved, xp)
         SELECT ?1, ?3, ?4, ?5, ?6, ?7, ?8 WHERE ${UNCHANGED}`,
      )
      .bind(uid, version, run.runId, run.endedAt, score.puzzles, score.words, score.saved, award.xp),
    db
      .prepare(`INSERT INTO xp_events (user_id, source, amount, ref, created_at) SELECT ?1, 'survival', ?3, ?4, ?5 WHERE ?3 > 0 AND ${UNCHANGED}`)
      .bind(uid, version, award.xp, run.runId, now),
    db
      .prepare(
        `INSERT INTO inventory (user_id, item, count)
         SELECT ?1, j.key, j.value FROM json_each(?3) AS j WHERE ${UNCHANGED}
         ON CONFLICT (user_id, item) DO UPDATE SET count = excluded.count`,
      )
      .bind(uid, version, JSON.stringify(s.hints)),
    db
      .prepare(`UPDATE stats SET words_forged = ?3, longest_word = ?4 WHERE user_id = ?1 AND ${UNCHANGED}`)
      .bind(uid, version, s.wordsForged, s.longestWord === "" ? null : s.longestWord),
    ...(award.newBest && best !== null
      ? [
          db
            .prepare(
              `INSERT INTO survival_best (uid, puzzles, words, saved, at) SELECT ?1, ?3, ?4, ?5, ?6 WHERE ${UNCHANGED}
               ON CONFLICT (uid) DO UPDATE SET puzzles = excluded.puzzles, words = excluded.words, saved = excluded.saved, at = excluded.at`,
            )
            .bind(uid, version, best.puzzles, best.words, best.saved, best.at),
        ]
      : []),
    ...orderProgress(db, uid, version, award.facts, now),
    // Last, because it moves the version the statements above check.
    db
      .prepare("UPDATE profiles SET xp = ?3, level = ?4, updated_at = ?5 WHERE user_id = ?1 AND updated_at = ?2")
      .bind(uid, version, s.totalXp, levelFromTotalXp(s.totalXp), Math.max(now, version + 1)),
  ];
  try {
    const results = await db.batch(statements);
    return results.at(-1)?.meta.changes === 1;
  } catch (err) {
    // A concurrent request recorded this run first.
    if (String(err).includes("UNIQUE")) return false;
    throw err;
  }
}
