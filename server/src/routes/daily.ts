/**
 * The Daily Commission (shared/daily.md; rules in src/rules/daily.ts):
 *
 * - `GET /v1/daily` → `{date, heat, puzzle, completed, streak, best}`
 * - `POST /v1/daily/complete` `{date, foundWords, bonusWords, hintsUsed, durationMs}`
 *   → `{profile, xp, streak, best, alreadyDone}`; `400 wrong_day`,
 *   `400 incomplete`, `400 too_fast`, `400 invalid_body`
 *
 * Both need a set-up account. `503 daily_unavailable` while the bank has no
 * size-1 puzzles (it was never seeded).
 */

import { loadAccount, profileBody, type Account } from "../db/accounts";
import { loadDailyDates, loadDailyPuzzle, writeDaily, type DailyBankPuzzle } from "../db/daily";
import { ApiError, json, readJsonObject } from "../http";
import { campaignPuzzle } from "../rules/campaign";
import { applyDaily, checkDaily, dailyPuzzleId, isCompletableDay, parseDailyCompletion, streakEndingOn, streaks, utcDate } from "../rules/daily";
import { requireSetUp, type AuthedContext } from "./context";

/** Attempts before giving up on a profile that keeps changing underneath us. */
const MAX_ATTEMPTS = 3;

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

export async function getDaily(c: AuthedContext): Promise<Response> {
  const account = await requireSetUp(c);
  const today = utcDate(c.now);
  const puzzle = await puzzleFor(c, today);
  const days = await loadDailyDates(c.env.DB, account.id);
  return json({
    date: today,
    heat: puzzle.heat,
    puzzle: campaignShape(today, puzzle),
    completed: days.includes(today),
    ...streaks(days, today),
  });
}

export async function postDailyComplete(c: AuthedContext): Promise<Response> {
  let account: Account = await requireSetUp(c);
  const parsed = parseDailyCompletion(await readJsonObject(c.request));
  if (!parsed.ok) throw new ApiError(400, "invalid_body", `Bad or missing ${parsed.detail}`);
  const completion = parsed.completion;
  const { date } = completion;
  if (!isCompletableDay(date, c.now)) throw new ApiError(400, "wrong_day", "Only today's Daily Commission (or yesterday's, in the first hour of today) counts");

  const bank = await puzzleFor(c, date);
  const puzzle = campaignPuzzle(0, bank.data);
  const problem = checkDaily(completion, puzzle);
  if (problem !== null) throw new ApiError(400, problem);

  const today = utcDate(c.now);
  for (let attempt = 1; ; attempt++) {
    const days = new Set(await loadDailyDates(c.env.DB, account.id));
    if (days.has(date)) {
      return json({ profile: profileBody(account), xp: 0, ...streaks(days, today), alreadyDone: true });
    }
    days.add(date);
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
      streakEndingOn(days, date),
    );
    if (await writeDaily(c.env.DB, account, { date, bankPuzzleId: puzzle.id, award }, c.now)) {
      const fresh = (await loadAccount(c.env.DB, account.id))!;
      return json({ profile: profileBody(fresh), xp: award.xp, ...streaks(days, today), alreadyDone: false });
    }
    if (attempt === MAX_ATTEMPTS) throw new ApiError(409, "sync_conflict", "Your profile changed meanwhile; try again");
    const reloaded = await loadAccount(c.env.DB, account.id);
    if (reloaded === null) throw new ApiError(403, "setup_required");
    account = reloaded;
  }
}
