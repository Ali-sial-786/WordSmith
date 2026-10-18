/**
 * Blocks and reports (shared/safety.md, migrations/0008_safety.sql).
 *
 * A block from A of B is the row (A, B); only A ever reads it. Blocking
 * also ends any friendship or request between them (src/routes/safety.ts),
 * and while either has blocked the other no friend request passes. A
 * report is one row for whoever reviews them, with the reported player's
 * username at the time; nothing reads it back to either player.
 */

/** Why a player is reported. `name` is an offensive username. */
export const REPORT_REASONS = ["harassment", "hate", "sexual", "name", "cheating", "spam", "other"] as const;
export type ReportReason = (typeof REPORT_REASONS)[number];

/** Characters (code points) in a report's details, after trimming. */
export const MAX_REPORT_DETAILS = 500;
/** Chat lines a report may carry, and characters (code points) in each. Rooms cut lines to 160. */
export const MAX_REPORT_LINES = 20;
export const MAX_REPORT_LINE_TEXT = 200;
/** Reports one player may make in {@link REPORT_WINDOW_MS}. */
export const MAX_REPORTS_PER_WINDOW = 10;
export const REPORT_WINDOW_MS = 24 * 60 * 60 * 1000;

export function isReportReason(value: unknown): value is ReportReason {
  return typeof value === "string" && (REPORT_REASONS as readonly string[]).includes(value);
}

/** Body of `GET /v1/me/blocks`, one entry per blocked player. */
export interface BlockEntry {
  readonly id: string;
  readonly username: string;
  readonly avatar: string | null;
  /** When I blocked them. */
  readonly at: number;
}

/** The players `uid` has blocked, newest first. */
export async function listBlocks(db: D1Database, uid: string): Promise<BlockEntry[]> {
  const { results } = await db
    .prepare(
      `SELECT b.blocked_id AS id, u.username, u.avatar, b.created_at AS at
         FROM blocks b JOIN users u ON u.id = b.blocked_id
        WHERE b.user_id = ?1 AND u.username IS NOT NULL
        ORDER BY b.created_at DESC, b.rowid DESC`,
    )
    .bind(uid)
    .all<BlockEntry>();
  return results;
}

/** `uid` blocks `other`. Blocking again keeps the first time. */
export async function addBlock(db: D1Database, uid: string, other: string, now: number): Promise<void> {
  await db.prepare("INSERT OR IGNORE INTO blocks (user_id, blocked_id, created_at) VALUES (?1, ?2, ?3)").bind(uid, other, now).run();
}

/** `uid` unblocks `other`, if they had blocked them. */
export async function removeBlock(db: D1Database, uid: string, other: string): Promise<void> {
  await db.prepare("DELETE FROM blocks WHERE user_id = ?1 AND blocked_id = ?2").bind(uid, other).run();
}

/** `blocked_them` if `uid` has blocked `other` (whatever `other` did), `blocked_by_them` if only `other` has blocked `uid`. */
export type BlockStatus = "none" | "blocked_them" | "blocked_by_them";

/** Whether either of two players has blocked the other. */
export async function blockBetween(db: D1Database, uid: string, other: string): Promise<BlockStatus> {
  const { results } = await db
    .prepare("SELECT user_id FROM blocks WHERE (user_id = ?1 AND blocked_id = ?2) OR (user_id = ?2 AND blocked_id = ?1)")
    .bind(uid, other)
    .all<{ user_id: string }>();
  if (results.some((r) => r.user_id === uid)) return "blocked_them";
  return results.length > 0 ? "blocked_by_them" : "none";
}

/** One of the reported player's chat lines, as the reporter saw it (a room's `CHAT` id, text and time). */
export interface ReportLine {
  readonly id: number;
  readonly text: string;
  readonly at: number;
}

export interface NewReport {
  readonly reportedId: string;
  /** Their username now, kept in case they change it. */
  readonly reportedUsername: string;
  readonly reason: ReportReason;
  readonly details: string | null;
  readonly room: string | null;
  readonly lines: readonly ReportLine[];
}

/**
 * Stores a report from `reporter`, with status `open`, unless they have
 * made {@link MAX_REPORTS_PER_WINDOW} in the last {@link REPORT_WINDOW_MS}.
 * The count and the insert are one statement, so racing reports can't get
 * past the limit. Returns false if it was refused.
 */
export async function insertReport(db: D1Database, reporter: string, report: NewReport, now: number): Promise<boolean> {
  const res = await db
    .prepare(
      `INSERT INTO reports (reporter_id, reported_id, reported_username, reason, details, room, lines, created_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8
        WHERE (SELECT COUNT(*) FROM reports WHERE reporter_id = ?1 AND created_at > ?8 - ?9) < ?10`,
    )
    .bind(
      reporter,
      report.reportedId,
      report.reportedUsername,
      report.reason,
      report.details,
      report.room,
      JSON.stringify(report.lines),
      now,
      REPORT_WINDOW_MS,
      MAX_REPORTS_PER_WINDOW,
    )
    .run();
  return res.meta.changes > 0;
}
