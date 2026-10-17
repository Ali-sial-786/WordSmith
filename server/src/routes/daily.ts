/**
 * The Daily Commission (shared/daily.md; rules in src/rules/daily.ts):
 *
 * - `GET /v1/daily?date=` → `{date, heat, puzzle, completed, streak, best, total}`:
 *   that day's (today's without `date`); `400 wrong_day` outside the
 *   window (the 1st of last month up to today)
 * - `POST /v1/daily/complete` `{date, foundWords, bonusWords, hintsUsed, durationMs}`
 *   → `{profile, xp, late, streak, best, total, alreadyDone}`; `400 wrong_day`,
 *   `400 incomplete`, `400 too_fast`, `400 invalid_body`
 * - `GET /v1/daily/calendar?month=YYYY-MM` → `{month, days, trophy, trophies}`;
 *   `400 wrong_month` unless it's this month or last
 *
 * All need a set-up account. `503 daily_unavailable` while the bank has no
 * size-1 puzzles (it was never seeded).
 */

import { loadAccount, profileBody, type Account } from "../db/accounts";
import { loadDailyDays, loadDailyPuzzle, onTimeDates, writeDaily, type DailyBankPuzzle } from "../db/daily";
import { ApiError, json, readJsonObject } from "../http";
import { campaignPuzzle } from "../rules/campaign";
import {
  applyDaily,
  calendar,
  checkDaily,
  dailyPuzzleId,
  isDate,
  isLateDay,
  isMonth,
  isPlayableDay,
  monthOf,
  parseDailyCompletion,
  previousMonth,
  streakEndingOn,
  streaks,
  utcDate,
} from "../rules/daily";
import { requireSetUp, type AuthedContext } from "./context";

/** Attempts before giving up on a profile that keeps changing underneath us. */
const MAX_ATTEMPTS = 3;

const WRONG_DAY = "Only days from the 1st of last month up to today can be played";

async function puzzleFor(c: AuthedContext, date: string): Promise<DailyBankPuzzle> {
  const puzzle = await loadDailyPuzzle(c.env.DB, date);
  if (puzzle === null) throw new ApiError(503, "daily_unavailable", "The puzzle bank hasn't been loaded on the server");
  return puzzle;
}

/** The bank puzzle in the campaign format (shared/puzzle-format.md), as `daily-<date>`. */
function campaignShape(date: string, p: DailyBankPuzzle): Record<string, unknown> {
  const { letters, heat, cols, rows, words, bonus } = p.data;
  return { id: dailyPuzzleId(date), letters, heat, cols, rows, words, bonus };
}

/** A query parameter, or `null` if it's missing. */
function query(c: AuthedContext, name: string): string | null {
  return new URL(c.request.url).searchParams.get(name);
}

export async function getDaily(c: AuthedContext): Promise<Response> {
  const account = await requireSetUp(c);
  const today = utcDate(c.now);
  const date = query(c, "date") ?? today;
  if (!isDate(date)) throw new ApiError(400, "invalid_body", "Expected ?date=YYYY-MM-DD");
  if (!isPlayableDay(date, c.now)) throw new ApiError(400, "wrong_day", WRONG_DAY);
  const puzzle = await puzzleFor(c, date);
  const days = await loadDailyDays(c.env.DB, account.id);
  return json({
    date,
    heat: puzzle.heat,
    puzzle: campaignShape(date, puzzle),
    completed: days.some((d) => d.date === date),
    ...streaks(onTimeDates(days), today),
    total: days.length,
  });
}

export async function postDailyComplete(c: AuthedContext): Promise<Response> {
  let account: Account = await requireSetUp(c);
  const parsed = parseDailyCompletion(await readJsonObject(c.request));
  if (!parsed.ok) throw new ApiError(400, "invalid_body", `Bad or missing ${parsed.detail}`);
  const completion = parsed.completion;
  const { date } = completion;
  if (!isPlayableDay(date, c.now)) throw new ApiError(400, "wrong_day", WRONG_DAY);
  const late = isLateDay(date, c.now);

  const bank = await puzzleFor(c, date);
  const puzzle = campaignPuzzle(0, bank.data);
  const problem = checkDaily(completion, puzzle);
  if (problem !== null) throw new ApiError(400, problem);

  const today = utcDate(c.now);
  for (let attempt = 1; ; attempt++) {
    const days = await loadDailyDays(c.env.DB, account.id);
    const onTime = new Set(onTimeDates(days));
    if (days.some((d) => d.date === date)) {
      return json({ profile: profileBody(account), xp: 0, late, ...streaks(onTime, today), total: days.length, alreadyDone: true });
    }
    if (!late) onTime.add(date);
    const award = applyDaily(
      {
        totalXp: account.totalXp,
        scrapBin: account.scrapBin,
        hints: account.hints,
        wordsForged: account.stats.wordsForged,
        longestWord: account.stats.longestWord,
      },
      completion,
      puzzle,
      streakEndingOn(onTime, date),
      late,
    );
    if (await writeDaily(c.env.DB, account, { date, bankPuzzleId: puzzle.id, award }, c.now)) {
      const fresh = (await loadAccount(c.env.DB, account.id))!;
      return json({ profile: profileBody(fresh), xp: award.xp, late, ...streaks(onTime, today), total: days.length + 1, alreadyDone: false });
    }
    if (attempt === MAX_ATTEMPTS) throw new ApiError(409, "sync_conflict", "Your profile changed meanwhile; try again");
    const reloaded = await loadAccount(c.env.DB, account.id);
    if (reloaded === null) throw new ApiError(403, "setup_required");
    account = reloaded;
  }
}

/** The calendar view of this month or last: days done, the month's trophy, and trophy counts over all months. */
export async function getDailyCalendar(c: AuthedContext): Promise<Response> {
  const account = await requireSetUp(c);
  const thisMonth = monthOf(utcDate(c.now));
  const month = query(c, "month") ?? thisMonth;
  if (!isMonth(month)) throw new ApiError(400, "invalid_body", "Expected ?month=YYYY-MM");
  if (month !== thisMonth && month !== previousMonth(thisMonth)) {
    throw new ApiError(400, "wrong_month", "Only this month and last month can be shown");
  }
  const days = await loadDailyDays(c.env.DB, account.id);
  return json(calendar(month, days.map((d) => d.date)));
}
