/**
 * Friends (docs/DESIGN.md §7, docs/TECH.md §7).
 *
 * A request from A to B is the row (A, B, pending). Accepting it makes the
 * friendship symmetric: (A, B, accepted) and (B, A, accepted). Declining,
 * cancelling and removing delete the rows in both directions. Each side's
 * row can carry the nickname that side gave the other (migrations/0007).
 */

import { levelFromTotalXp, rankForLevel } from "../rules/progression";

/** Friends per player, and requests one player may have waiting on others. */
export const MAX_FRIENDS = 100;
export const MAX_OUTGOING_REQUESTS = 50;

export interface UserSummary {
  readonly id: string;
  readonly username: string;
  readonly avatar: string | null;
  readonly level: number;
  readonly rank: string;
}

export interface FriendEntry extends UserSummary {
  /** When the request was made (for friends: when they became friends, roughly). */
  readonly since: number;
  /** The nickname I gave this friend (only I see it), or `null`. Always `null` for requests. */
  readonly nickname: string | null;
}

/** Body of `GET /v1/friends`. Online status comes from the hub, not here. */
export interface FriendsList {
  readonly friends: readonly FriendEntry[];
  /** Requests waiting for me to answer. */
  readonly incoming: readonly FriendEntry[];
  /** My requests waiting for them. */
  readonly outgoing: readonly FriendEntry[];
}

interface SummaryRow {
  id: string;
  username: string;
  avatar: string | null;
  xp: number;
}

function summary(row: SummaryRow): UserSummary {
  const level = levelFromTotalXp(row.xp);
  return { id: row.id, username: row.username, avatar: row.avatar, level, rank: rankForLevel(level).name };
}

const byName = (a: UserSummary, b: UserSummary) => a.username.toLowerCase().localeCompare(b.username.toLowerCase());

/** Friends by the name I see: my nickname for them, else their username. */
const byShownName = (a: FriendEntry, b: FriendEntry) =>
  (a.nickname ?? a.username).toLowerCase().localeCompare((b.nickname ?? b.username).toLowerCase());

export async function listFriends(db: D1Database, uid: string): Promise<FriendsList> {
  const { results } = await db
    .prepare(
      `SELECT f.friend_id AS id, f.status, f.created_at, f.nickname, 'out' AS dir, u.username, u.avatar, p.xp
         FROM friends f JOIN users u ON u.id = f.friend_id JOIN profiles p ON p.user_id = f.friend_id
        WHERE f.user_id = ?1 AND u.username IS NOT NULL
       UNION ALL
       SELECT f.user_id AS id, f.status, f.created_at, NULL AS nickname, 'in' AS dir, u.username, u.avatar, p.xp
         FROM friends f JOIN users u ON u.id = f.user_id JOIN profiles p ON p.user_id = f.user_id
        WHERE f.friend_id = ?1 AND f.status = 'pending' AND u.username IS NOT NULL`,
    )
    .bind(uid)
    .all<SummaryRow & { status: string; created_at: number; nickname: string | null; dir: "in" | "out" }>();
  const friends: FriendEntry[] = [];
  const incoming: FriendEntry[] = [];
  const outgoing: FriendEntry[] = [];
  for (const row of results) {
    const entry = { ...summary(row), since: row.created_at, nickname: row.status === "accepted" ? row.nickname : null };
    if (row.dir === "in") incoming.push(entry);
    else if (row.status === "accepted") friends.push(entry);
    else outgoing.push(entry);
  }
  return { friends: friends.sort(byShownName), incoming: incoming.sort(byName), outgoing: outgoing.sort(byName) };
}

/**
 * Sets (or with `null` clears) the nickname `uid` gave `friend`. Returns
 * false unless they're accepted friends. Only `uid`'s own row changes, so
 * nobody else ever sees it.
 */
export async function setNickname(db: D1Database, uid: string, friend: string, nickname: string | null): Promise<boolean> {
  const res = await db
    .prepare("UPDATE friends SET nickname = ?3 WHERE user_id = ?1 AND friend_id = ?2 AND status = 'accepted'")
    .bind(uid, friend, nickname)
    .run();
  return res.meta.changes > 0;
}

/** A set-up user's summary, looked up by ID or by username (ignoring case). */
export async function findUser(db: D1Database, by: { id: string } | { username: string }): Promise<UserSummary | null> {
  const [where, value] = "id" in by ? ["u.id = ?1", by.id] : ["u.username = ?1", by.username];
  const row = await db
    .prepare(
      `SELECT u.id, u.username, u.avatar, p.xp FROM users u JOIN profiles p ON p.user_id = u.id
        WHERE ${where} AND u.username IS NOT NULL`,
    )
    .bind(value)
    .first<SummaryRow>();
  return row === null ? null : summary(row);
}

export type Link = "none" | "friends" | "request_sent" | "request_received";

/** How `uid` stands with `other`. */
export async function linkBetween(db: D1Database, uid: string, other: string): Promise<Link> {
  const { results } = await db
    .prepare(
      `SELECT user_id, status FROM friends
        WHERE (user_id = ?1 AND friend_id = ?2) OR (user_id = ?2 AND friend_id = ?1)`,
    )
    .bind(uid, other)
    .all<{ user_id: string; status: string }>();
  if (results.some((r) => r.status === "accepted")) return "friends";
  if (results.some((r) => r.user_id === uid)) return "request_sent";
  if (results.some((r) => r.user_id === other)) return "request_received";
  return "none";
}

interface Counts {
  friends: number;
  outgoing: number;
}

async function counts(db: D1Database, uid: string): Promise<Counts> {
  const row = await db
    .prepare(
      `SELECT COALESCE(SUM(status = 'accepted'), 0) AS friends, COALESCE(SUM(status = 'pending'), 0) AS outgoing
         FROM friends WHERE user_id = ?1`,
    )
    .bind(uid)
    .first<Counts>();
  return row ?? { friends: 0, outgoing: 0 };
}

export type LimitHit = "my_friends_full" | "their_friends_full" | "too_many_requests";

/** Whether `uid` may send one more request. */
export async function requestLimit(db: D1Database, uid: string): Promise<LimitHit | null> {
  const mine = await counts(db, uid);
  if (mine.friends >= MAX_FRIENDS) return "my_friends_full";
  if (mine.outgoing >= MAX_OUTGOING_REQUESTS) return "too_many_requests";
  return null;
}

/** Whether `a` and `b` may become friends. */
export async function acceptLimit(db: D1Database, a: string, b: string): Promise<LimitHit | null> {
  const [mine, theirs] = await Promise.all([counts(db, a), counts(db, b)]);
  if (mine.friends >= MAX_FRIENDS) return "my_friends_full";
  if (theirs.friends >= MAX_FRIENDS) return "their_friends_full";
  return null;
}

export async function insertRequest(db: D1Database, from: string, to: string, now: number): Promise<void> {
  await db
    .prepare("INSERT OR IGNORE INTO friends (user_id, friend_id, status, created_at) VALUES (?1, ?2, 'pending', ?3)")
    .bind(from, to, now)
    .run();
}

/**
 * Turns `requester`'s pending request to `accepter` into a friendship.
 * Returns false if there was no such request.
 */
export async function acceptRequest(db: D1Database, requester: string, accepter: string, now: number): Promise<boolean> {
  const [updated] = await db.batch([
    db
      .prepare("UPDATE friends SET status = 'accepted' WHERE user_id = ?1 AND friend_id = ?2 AND status = 'pending'")
      .bind(requester, accepter),
    db
      .prepare(
        `INSERT INTO friends (user_id, friend_id, status, created_at)
         SELECT ?2, ?1, 'accepted', ?3
          WHERE EXISTS (SELECT 1 FROM friends WHERE user_id = ?1 AND friend_id = ?2 AND status = 'accepted')
         ON CONFLICT (user_id, friend_id) DO UPDATE SET status = 'accepted'`,
      )
      .bind(requester, accepter, now),
  ]);
  return (updated?.meta.changes ?? 0) > 0;
}

/** Deletes a pending request. Returns false if there was none. */
export async function deleteRequest(db: D1Database, requester: string, recipient: string): Promise<boolean> {
  const res = await db
    .prepare("DELETE FROM friends WHERE user_id = ?1 AND friend_id = ?2 AND status = 'pending'")
    .bind(requester, recipient)
    .run();
  return res.meta.changes > 0;
}

/** Deletes every row between two players. Returns what they were before. */
export async function unlink(db: D1Database, a: string, b: string): Promise<Link> {
  const before = await linkBetween(db, a, b);
  if (before !== "none") {
    await db
      .prepare("DELETE FROM friends WHERE (user_id = ?1 AND friend_id = ?2) OR (user_id = ?2 AND friend_id = ?1)")
      .bind(a, b)
      .run();
  }
  return before;
}

/** Body of `GET /v1/leaderboard`. */
export interface LeaderboardEntry extends UserSummary {
  /** 1-based, by lifetime XP; equal XP shares a place. */
  readonly place: number;
  readonly totalXp: number;
  readonly vsSeriesWon: number;
  readonly vsRoundsWon: number;
  readonly coopRounds: number;
  readonly coopMvps: number;
  readonly me: boolean;
}

/** Me plus my accepted friends, best first. */
export async function leaderboard(db: D1Database, uid: string): Promise<LeaderboardEntry[]> {
  const { results } = await db
    .prepare(
      `SELECT u.id, u.username, u.avatar, p.xp, s.vs_series_won, s.vs_rounds_won, s.coop_rounds, s.coop_mvps
         FROM users u JOIN profiles p ON p.user_id = u.id JOIN stats s ON s.user_id = u.id
        WHERE u.username IS NOT NULL
          AND (u.id = ?1 OR u.id IN (SELECT friend_id FROM friends WHERE user_id = ?1 AND status = 'accepted'))
        ORDER BY p.xp DESC, u.username COLLATE NOCASE`,
    )
    .bind(uid)
    .all<SummaryRow & { vs_series_won: number; vs_rounds_won: number; coop_rounds: number; coop_mvps: number }>();
  const entries: LeaderboardEntry[] = [];
  results.forEach((row, i) => {
    const prev = entries[i - 1];
    entries.push({
      ...summary(row),
      place: prev !== undefined && results[i - 1]!.xp === row.xp ? prev.place : i + 1,
      totalXp: row.xp,
      vsSeriesWon: row.vs_series_won,
      vsRoundsWon: row.vs_rounds_won,
      coopRounds: row.coop_rounds,
      coopMvps: row.coop_mvps,
      me: row.id === uid,
    });
  });
  return entries;
}
