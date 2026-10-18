/**
 * Blocking and reporting (shared/safety.md). All need a set-up account.
 *
 * - `GET /v1/me/blocks` → {blocks: [{id, username, avatar, at}]}, newest first
 * - `PUT /v1/me/blocks/:id` → {ok: true}: blocks them (again is fine), and
 *   ends any friendship or request between us as `DELETE /v1/friends/:id` does
 * - `DELETE /v1/me/blocks/:id` → {ok: true}: unblocks them (again is fine);
 *   a friendship the block ended stays ended
 * - `POST /v1/reports {userId, reason, details?, room?, lines?}` → 201 {ok: true}
 *
 * The blocked or reported player is never told.
 */

import { findUser } from "../db/friends";
import {
  addBlock,
  insertReport,
  isReportReason,
  listBlocks,
  MAX_REPORT_DETAILS,
  MAX_REPORT_LINE_TEXT,
  MAX_REPORT_LINES,
  removeBlock,
  type NewReport,
  type ReportLine,
} from "../db/safety";
import { ApiError, isRecord, json, readJsonObject } from "../http";
import { ROOM_CODE_RE } from "../rules/room";
import { requireSetUp, type AuthedContext } from "./context";
import { endLink } from "./friends";

/** Room for 20 lines of 200 characters even with every one escaped in the JSON. */
const MAX_REPORT_BODY_BYTES = 64 * 1024;

export async function getBlocks(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  return json({ blocks: await listBlocks(c.env.DB, c.uid) });
}

export async function putBlock(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  const other = c.params.id ?? "";
  if (other === c.uid) throw new ApiError(400, "cannot_block_self");
  if ((await findUser(c.env.DB, { id: other })) === null) throw new ApiError(404, "user_not_found");
  // The block first, so a friend request racing it is refused.
  await addBlock(c.env.DB, c.uid, other, c.now);
  await endLink(c, other);
  return json({ ok: true });
}

export async function deleteBlock(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  await removeBlock(c.env.DB, c.uid, c.params.id ?? "");
  return json({ ok: true });
}

export async function postReport(c: AuthedContext): Promise<Response> {
  await requireSetUp(c);
  let body: Record<string, unknown>;
  try {
    body = await readJsonObject(c.request, MAX_REPORT_BODY_BYTES);
  } catch (err) {
    // The contract has one error for every malformed body.
    if (err instanceof ApiError) throw new ApiError(400, "bad_request", err.detail ?? err.code);
    throw err;
  }
  const input = parseReport(body);
  if (input === null) throw new ApiError(400, "bad_request", "Expected {userId, reason, details?, room?, lines?} (shared/safety.md)");
  const { userId, ...fields } = input;
  if (userId === c.uid) throw new ApiError(400, "cannot_report_self");
  const reported = await findUser(c.env.DB, { id: userId });
  if (reported === null) throw new ApiError(404, "user_not_found");

  const report: NewReport = { ...fields, reportedId: reported.id, reportedUsername: reported.username };
  if (!(await insertReport(c.env.DB, c.uid, report, c.now))) {
    throw new ApiError(429, "too_many_reports", "That's a lot of reports today; try again tomorrow");
  }
  return json({ ok: true }, 201);
}

type ReportInput = Omit<NewReport, "reportedId" | "reportedUsername"> & { readonly userId: string };

const codePoints = (s: string) => [...s].length;
const isCount = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;

/** A report body, or `null` if anything in it is malformed. Missing and `null` optional fields are the same. */
function parseReport(body: Record<string, unknown>): ReportInput | null {
  const { userId, reason } = body;
  if (typeof userId !== "string" || userId === "" || !isReportReason(reason)) return null;

  const details = body.details ?? null;
  if (details !== null && typeof details !== "string") return null;
  const trimmed = details?.trim() ?? "";
  if (codePoints(trimmed) > MAX_REPORT_DETAILS) return null;

  const room = body.room ?? null;
  if (room !== null && (typeof room !== "string" || !ROOM_CODE_RE.test(room))) return null;

  const raw = body.lines ?? [];
  if (!Array.isArray(raw) || raw.length > MAX_REPORT_LINES) return null;
  const lines: ReportLine[] = [];
  for (const line of raw) {
    if (!isRecord(line)) return null;
    const { id, text, at } = line;
    if (!isCount(id) || typeof text !== "string" || codePoints(text) > MAX_REPORT_LINE_TEXT || !isCount(at)) return null;
    // Only the fields the contract names are kept.
    lines.push({ id, text, at });
  }

  return { userId, reason, details: trimmed === "" ? null : trimmed, room, lines };
}
