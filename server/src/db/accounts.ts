/**
 * D1 queries for accounts: users, profiles, inventory and stats
 * (docs/TECH.md §7), and the JSON shapes the API returns for them.
 */

import { DELETED_NAME } from "../account/username";
import { levelProgress, rankForLevel, STARTING_HINTS, type HintCounts } from "../rules/progression";
import type { SurvivalBest } from "../rules/survival";

export { DELETED_NAME };

export interface Stats {
  readonly wordsForged: number;
  /** "" until the first word. */
  readonly longestWord: string;
  readonly soloDone: number;
  readonly coopRounds: number;
  readonly coopMvps: number;
  readonly vsSeries: number;
  readonly vsSeriesWon: number;
  readonly vsRoundsWon: number;
}

/** Everything we keep about one player. */
export interface Account {
  readonly id: string;
  readonly username: string | null;
  readonly avatar: string | null;
  readonly createdAt: number;
  readonly totalXp: number;
  /** Highest campaign stage completed (0 = none). */
  readonly campaignCompleted: number;
  /** Bonus words towards the next Hammer Strike (0–9). */
  readonly scrapBin: number;
  /** `profiles.updated_at`, used as a version for optimistic writes. */
  readonly version: number;
  readonly hints: Readonly<HintCounts>;
  readonly stats: Stats;
  /** Daily Stoke claims ever made, and the UTC day of the last (shared/forge-board.md). */
  readonly stokeClaims: number;
  readonly stokeLast: string | null;
  /** Blueprint pieces collected (shared/masterworks.md). */
  readonly masterworkPieces: number;
  /** The UTC hour of the daily reminder, or `null` for none (shared/push.md). */
  readonly reminderHour: number | null;
  /** The best Crucible run (shared/survival.md), or `null` before the first. */
  readonly survivalBest: SurvivalBest | null;
}

export type SetUpAccount = Account & { readonly username: string; readonly avatar: string };

interface AccountRow {
  id: string;
  username: string | null;
  avatar: string | null;
  created_at: number;
  xp: number;
  campaign_stage: number;
  scrap_bin: number;
  updated_at: number;
  stoke_claims: number;
  stoke_last: string | null;
  masterwork_pieces: number;
  reminder_hour: number | null;
  words_forged: number;
  longest_word: string | null;
  solo_done: number;
  coop_rounds: number;
  coop_mvps: number;
  vs_series: number;
  vs_series_won: number;
  vs_rounds_won: number;
  hammer: number;
  chisel: number;
  sparks: number;
  best_puzzles: number | null;
  best_words: number | null;
  best_saved: number | null;
  best_at: number | null;
}

const ACCOUNT_SQL = `
SELECT u.id, u.username, u.avatar, u.created_at,
       p.xp, p.campaign_stage, p.scrap_bin, p.updated_at, p.stoke_claims, p.stoke_last, p.masterwork_pieces, p.reminder_hour,
       s.words_forged, s.longest_word, s.solo_done, s.coop_rounds, s.coop_mvps,
       s.vs_series, s.vs_series_won, s.vs_rounds_won,
       COALESCE((SELECT count FROM inventory WHERE user_id = u.id AND item = 'hammer'), 0) AS hammer,
       COALESCE((SELECT count FROM inventory WHERE user_id = u.id AND item = 'chisel'), 0) AS chisel,
       COALESCE((SELECT count FROM inventory WHERE user_id = u.id AND item = 'sparks'), 0) AS sparks,
       b.puzzles AS best_puzzles, b.words AS best_words, b.saved AS best_saved, b.at AS best_at
  FROM users u
  JOIN profiles p ON p.user_id = u.id
  JOIN stats s ON s.user_id = u.id
  LEFT JOIN survival_best b ON b.uid = u.id
 WHERE u.id = ?`;

function toAccount(row: AccountRow): Account {
  return {
    id: row.id,
    username: row.username,
    avatar: row.avatar,
    createdAt: row.created_at,
    totalXp: row.xp,
    campaignCompleted: row.campaign_stage,
    scrapBin: row.scrap_bin,
    version: row.updated_at,
    hints: { hammer: row.hammer, chisel: row.chisel, sparks: row.sparks },
    stats: {
      wordsForged: row.words_forged,
      longestWord: row.longest_word ?? "",
      soloDone: row.solo_done,
      coopRounds: row.coop_rounds,
      coopMvps: row.coop_mvps,
      vsSeries: row.vs_series,
      vsSeriesWon: row.vs_series_won,
      vsRoundsWon: row.vs_rounds_won,
    },
    stokeClaims: row.stoke_claims,
    stokeLast: row.stoke_last,
    masterworkPieces: row.masterwork_pieces,
    reminderHour: row.reminder_hour,
    survivalBest:
      row.best_at === null ? null : { puzzles: row.best_puzzles ?? 0, words: row.best_words ?? 0, saved: row.best_saved ?? 0, at: row.best_at },
  };
}

export async function loadAccount(db: D1Database, uid: string): Promise<Account | null> {
  const row = await db.prepare(ACCOUNT_SQL).bind(uid).first<AccountRow>();
  return row === null ? null : toAccount(row);
}

/**
 * Loads the account, creating its rows on first sight: a user with no name
 * yet, a fresh profile and stats, and the starting hints (3 Hammer Strikes).
 */
export async function ensureAccount(db: D1Database, uid: string, now: number): Promise<Account> {
  const existing = await loadAccount(db, uid);
  if (existing !== null) return existing;
  await db.batch([
    db.prepare("INSERT OR IGNORE INTO users (id, created_at) VALUES (?1, ?2)").bind(uid, now),
    db.prepare("INSERT OR IGNORE INTO profiles (user_id, updated_at) VALUES (?1, ?2)").bind(uid, now),
    db.prepare("INSERT OR IGNORE INTO stats (user_id) VALUES (?1)").bind(uid),
    db
      .prepare(
        "INSERT OR IGNORE INTO inventory (user_id, item, count) VALUES (?1, 'hammer', ?2), (?1, 'chisel', ?3), (?1, 'sparks', ?4)",
      )
      .bind(uid, STARTING_HINTS.hammer, STARTING_HINTS.chisel, STARTING_HINTS.sparks),
  ]);
  const created = await loadAccount(db, uid);
  if (created === null) throw new Error(`account ${uid} missing right after creation`);
  return created;
}

export function isSetUp(account: Account): account is SetUpAccount {
  return account.username !== null && account.avatar !== null;
}

/** Body of `GET /v1/me` (also returned by setup, sync, the Daily Commission, the Forge Board's claims and Survival runs). */
export interface ProfileBody {
  readonly id: string;
  readonly username: string | null;
  readonly avatar: string | null;
  /** True until `POST /v1/me/setup` has set a username and avatar. */
  readonly needsSetup: boolean;
  readonly totalXp: number;
  readonly level: number;
  readonly xpIntoLevel: number;
  readonly xpForLevel: number;
  readonly rank: string;
  /** Highest campaign stage completed (0 = none); `profiles.campaign_stage`. */
  readonly campaignCompleted: number;
  /** The next stage to play: campaignCompleted + 1 (the app's `Profile.campaignStage`). */
  readonly nextStage: number;
  readonly scrapBin: number;
  readonly hints: Readonly<HintCounts>;
  readonly stats: Stats;
  /** Blueprint pieces collected; the app works out the Masterworks from it (shared/masterworks.md). */
  readonly masterworks: { readonly pieces: number };
  /** The UTC hour of the daily reminder, or `null` for none (shared/push.md). */
  readonly reminderHour: number | null;
  /** The best Crucible run `{puzzles, words, saved, at}`, or `null` before the first (shared/survival.md). */
  readonly survivalBest: SurvivalBest | null;
  readonly createdAt: number;
}

export function profileBody(account: Account): ProfileBody {
  const progress = levelProgress(account.totalXp);
  return {
    id: account.id,
    username: account.username,
    avatar: account.avatar,
    needsSetup: !isSetUp(account),
    totalXp: account.totalXp,
    level: progress.level,
    xpIntoLevel: progress.xpIntoLevel,
    xpForLevel: progress.xpForLevel,
    rank: rankForLevel(progress.level).name,
    campaignCompleted: account.campaignCompleted,
    nextStage: account.campaignCompleted + 1,
    scrapBin: account.scrapBin,
    hints: account.hints,
    stats: account.stats,
    masterworks: { pieces: account.masterworkPieces },
    reminderHour: account.reminderHour,
    survivalBest: account.survivalBest,
    createdAt: account.createdAt,
  };
}

/** Body of `GET /v1/users/:username`. */
export interface PublicProfileBody {
  readonly id: string;
  readonly username: string;
  readonly avatar: string | null;
  readonly level: number;
  readonly rank: string;
  readonly campaignCompleted: number;
  readonly stats: Stats;
}

export function publicProfileBody(account: SetUpAccount): PublicProfileBody {
  const level = levelProgress(account.totalXp).level;
  return {
    id: account.id,
    username: account.username,
    avatar: account.avatar,
    level,
    rank: rankForLevel(level).name,
    campaignCompleted: account.campaignCompleted,
    stats: account.stats,
  };
}

/** The user ID with this username (ignoring case), or `null`. */
export async function userIdByUsername(db: D1Database, username: string): Promise<string | null> {
  const row = await db.prepare("SELECT id FROM users WHERE username = ?1").bind(username).first<{ id: string }>();
  return row?.id ?? null;
}

export type SetupResult = "ok" | "taken" | "already_set";

/**
 * Sets the username and avatar. A username can only be set once; repeating
 * the same username (ignoring case) just updates the avatar, so a retried
 * request and later avatar changes both work.
 */
export async function setupAccount(db: D1Database, account: Account, username: string, avatar: string): Promise<SetupResult> {
  if (account.username !== null) {
    if (account.username.toLowerCase() !== username.toLowerCase()) return "already_set";
    await db.prepare("UPDATE users SET avatar = ?2 WHERE id = ?1").bind(account.id, avatar).run();
    return "ok";
  }
  const holder = await userIdByUsername(db, username);
  if (holder !== null && holder !== account.id) return "taken";
  try {
    const res = await db
      .prepare("UPDATE users SET username = ?2, avatar = ?3 WHERE id = ?1 AND username IS NULL")
      .bind(account.id, username, avatar)
      .run();
    // Lost a race with another setup call for this account.
    if (res.meta.changes === 0) return "already_set";
  } catch (err) {
    if (String(err).includes("UNIQUE")) return "taken";
    throw err;
  }
  return "ok";
}

/** Accepted friends' user IDs. */
export async function friendIds(db: D1Database, uid: string): Promise<string[]> {
  const { results } = await db
    .prepare("SELECT friend_id FROM friends WHERE user_id = ?1 AND status = 'accepted'")
    .bind(uid)
    .all<{ friend_id: string }>();
  return results.map((r) => r.friend_id);
}

/**
 * Deletes everything we hold about a player (docs/TECH.md §3). Their rows in
 * past matches stay, under a random placeholder ID that no user has, so
 * those matches show {@link DELETED_NAME}; the uid is also replaced inside
 * match summaries. Returns the accepted friends they had, so the hub can
 * tell them.
 */
export async function deleteAccount(db: D1Database, uid: string): Promise<{ formerFriends: string[] }> {
  const formerFriends = await friendIds(db, uid);
  const placeholder = `deleted:${crypto.randomUUID()}`;
  const byUser = (table: string) => db.prepare(`DELETE FROM ${table} WHERE user_id = ?1`).bind(uid);
  await db.batch([
    db.prepare("UPDATE match_players SET user_id = ?2 WHERE user_id = ?1").bind(uid, placeholder),
    db
      .prepare(
        `UPDATE matches SET summary = replace(summary, ?1, ?2)
          WHERE summary IS NOT NULL AND id IN (SELECT match_id FROM match_players WHERE user_id = ?2)`,
      )
      .bind(uid, placeholder),
    db.prepare("DELETE FROM friends WHERE user_id = ?1 OR friend_id = ?1").bind(uid),
    db.prepare("DELETE FROM gifts WHERE from_user = ?1 OR to_user = ?1").bind(uid),
    byUser("inventory"),
    byUser("stats"),
    byUser("profiles"),
    byUser("puzzle_seen"),
    byUser("xp_events"),
    byUser("solo_results"),
    byUser("pickup_seeds"),
    byUser("daily_completions"),
    byUser("push_tokens"),
    byUser("work_orders"),
    byUser("weekly_xp"),
    byUser("trial_claims"),
    db.prepare("DELETE FROM survival_runs WHERE uid = ?1").bind(uid),
    db.prepare("DELETE FROM survival_best WHERE uid = ?1").bind(uid),
    db.prepare("DELETE FROM users WHERE id = ?1").bind(uid),
  ]);
  return { formerFriends };
}
