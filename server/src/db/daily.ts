/**
 * D1 queries for the Daily Commission (shared/daily.md): the day's puzzle
 * from the multiplayer bank, a player's completed days, and writing a
 * completion. Writes are optimistic, like solo sync's (src/db/sync.ts):
 * nothing changes if the profile moved on since it was read.
 */

import type { Account } from "./accounts";
import { dailyHeat, dailyIndex, type DailyAward } from "../rules/daily";
import type { HeatTier } from "../rules/heat";
import { levelFromTotalXp } from "../rules/progression";

export interface DailyBankPuzzle {
  readonly heat: HeatTier;
  /** The bank puzzle's JSON (shared/puzzle-format.md, with its `size`). */
  readonly data: Record<string, unknown>;
}

/**
 * The puzzle for `date`: among the size-1 bank puzzles at the day's heat,
 * ordered by id, the one {@link dailyIndex} picks. If that heat has none,
 * the nearest heat that does (cooler first). `null` if the bank has no
 * size-1 puzzles at all.
 */
export async function loadDailyPuzzle(db: D1Database, date: string): Promise<DailyBankPuzzle | null> {
  const pool = await db
    .prepare("SELECT heat, COUNT(*) AS n FROM puzzles WHERE pool = 'mp' AND size = 1 GROUP BY heat ORDER BY abs(heat - ?1), heat LIMIT 1")
    .bind(dailyHeat(date))
    .first<{ heat: HeatTier; n: number }>();
  if (pool === null) return null;
  const row = await db
    .prepare("SELECT data FROM puzzles WHERE pool = 'mp' AND size = 1 AND heat = ?1 ORDER BY id LIMIT 1 OFFSET ?2")
    .bind(pool.heat, dailyIndex(date, pool.n))
    .first<{ data: string }>();
  return row === null ? null : { heat: pool.heat, data: JSON.parse(row.data) as Record<string, unknown> };
}

/** The days the player has completed (`YYYY-MM-DD`). */
export async function loadDailyDates(db: D1Database, uid: string): Promise<string[]> {
  const { results } = await db.prepare("SELECT date FROM daily_completions WHERE user_id = ?1").bind(uid).all<{ date: string }>();
  return results.map((r) => r.date);
}

/** Only true while the profile is still at the version we read. */
const UNCHANGED = "EXISTS (SELECT 1 FROM profiles WHERE user_id = ?1 AND updated_at = ?2)";

export interface DailyWrite {
  readonly date: string;
  /** The bank puzzle behind the day's puzzle, so rooms don't serve it again soon. */
  readonly bankPuzzleId: string;
  readonly award: DailyAward;
}

/**
 * Writes a day's first completion in one transaction, if the profile is
 * still at `account.version`: the `daily_completions` row, `xp_events`
 * (`source: "daily"`, `ref`: the date), the bank puzzle as seen, the hint
 * stock, words forged and longest word, and the profile (XP, level, Scrap
 * Bin). Returns false, writing nothing, if the profile changed or the day
 * was already recorded by a concurrent request.
 */
export async function writeDaily(db: D1Database, account: Account, w: DailyWrite, now: number): Promise<boolean> {
  const uid = account.id;
  const version = account.version;
  const s = w.award.state;
  const statements = [
    db
      .prepare(`INSERT INTO daily_completions (user_id, date, completed_at, xp) SELECT ?1, ?3, ?4, ?5 WHERE ${UNCHANGED}`)
      .bind(uid, version, w.date, now, w.award.xp),
    db
      .prepare(`INSERT INTO xp_events (user_id, source, amount, ref, created_at) SELECT ?1, 'daily', ?3, ?4, ?5 WHERE ${UNCHANGED}`)
      .bind(uid, version, w.award.xp, w.date, now),
    db
      .prepare(
        `INSERT INTO puzzle_seen (user_id, puzzle_id, seen_at) SELECT ?1, ?3, ?4 WHERE ${UNCHANGED}
         ON CONFLICT (user_id, puzzle_id) DO UPDATE SET seen_at = excluded.seen_at`,
      )
      .bind(uid, version, w.bankPuzzleId, now),
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
    // Last, because it moves the version the statements above check.
    db
      .prepare("UPDATE profiles SET xp = ?3, level = ?4, scrap_bin = ?5, updated_at = ?6 WHERE user_id = ?1 AND updated_at = ?2")
      .bind(uid, version, s.totalXp, levelFromTotalXp(s.totalXp), s.scrapBin, Math.max(now, version + 1)),
  ];
  try {
    const results = await db.batch(statements);
    return results.at(-1)?.meta.changes === 1;
  } catch (err) {
    // A concurrent request recorded this day first.
    if (String(err).includes("UNIQUE")) return false;
    throw err;
  }
}
