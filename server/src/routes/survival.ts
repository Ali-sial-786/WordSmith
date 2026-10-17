/**
 * `POST /v1/survival/solo` (shared/survival.md "Solo: The Crucible"; rules
 * in src/rules/survival.ts): a run the app played offline, sent once from
 * its queue.
 *
 * `{runId, startedAt, endedAt, saved, puzzles: [{stage, puzzleId, foundWords, hintsUsed, cleared}]}`
 * → `{profile, xp: {xp, level, levelUps, rewards}, best, newBest, duplicate?}`.
 *
 * - `400 invalid_run` (with a `message` saying what's wrong) for a run that
 *   can't count; the app should drop it.
 * - A `runId` already recorded answers `200` with `duplicate: true`.
 * - `503 campaign_unavailable` while the campaign table is empty, and
 *   `409 sync_conflict` if the profile kept changing meanwhile: keep the
 *   run and retry.
 *
 * Signed-in players only, but like solo sync it doesn't need a set-up account.
 */

import { ensureAccount, loadAccount, profileBody, type Account } from "../db/accounts";
import { campaignStageCount, loadCampaignPuzzles } from "../db/campaign";
import { loadRunContext, writeSurvivalRun, type RecordedRun } from "../db/survival";
import { ApiError, json, readJsonObject } from "../http";
import { levelFromTotalXp, noHints } from "../rules/progression";
import { applySurvivalRun, checkSurvivalRun, parseSurvivalRun } from "../rules/survival";
import type { AuthedContext } from "./context";

/** Enough for 50 puzzles with every word typed. */
const MAX_RUN_BODY_BYTES = 128 * 1024;

/** Attempts before giving up on a profile that keeps changing underneath us. */
const MAX_ATTEMPTS = 3;

/**
 * The answer to a run sent again: the XP it was given (its level-ups were
 * paid the first time), the best run now, and whether this run is it.
 */
function duplicateBody(account: Account, run: RecordedRun): Record<string, unknown> {
  const best = account.survivalBest;
  const isBest = best !== null && best.at === run.at && best.puzzles === run.puzzles && best.words === run.words && best.saved === run.saved;
  return {
    profile: profileBody(account),
    xp: { xp: run.xp, level: levelFromTotalXp(account.totalXp), levelUps: 0, rewards: noHints() },
    best,
    newBest: isBest,
    duplicate: true,
  };
}

export async function postSurvivalSolo(c: AuthedContext): Promise<Response> {
  const parsed = parseSurvivalRun(await readJsonObject(c.request, MAX_RUN_BODY_BYTES));
  if (!parsed.ok) throw new ApiError(400, "invalid_run", `Bad or missing ${parsed.detail}`);
  const run = parsed.run;
  const db = c.env.DB;

  let account = await ensureAccount(db, c.uid, c.now);
  let context = await loadRunContext(db, c.uid, run.runId);
  if (context.recorded !== null) return json(duplicateBody(account, context.recorded));

  const stages = run.puzzles.map((p) => p.stage);
  const puzzles = await loadCampaignPuzzles(db, stages);
  if (puzzles.size < new Set(stages).size && (await campaignStageCount(db)) === 0) {
    // Not the player's fault: don't let the app throw the run away.
    throw new ApiError(503, "campaign_unavailable", "The campaign hasn't been loaded on the server");
  }
  const problem = checkSurvivalRun(run, puzzles, context.highestSoloStage, c.now);
  if (problem !== null) throw new ApiError(400, "invalid_run", problem);

  for (let attempt = 1; ; attempt++) {
    const award = applySurvivalRun(
      {
        totalXp: account.totalXp,
        hints: account.hints,
        wordsForged: account.stats.wordsForged,
        longestWord: account.stats.longestWord,
        best: account.survivalBest,
      },
      run,
    );
    if (await writeSurvivalRun(db, account, run, award, c.now)) {
      const fresh = (await loadAccount(db, account.id))!;
      return json({
        profile: profileBody(fresh),
        xp: { xp: award.xp, level: award.award.level, levelUps: award.award.levelsGained, rewards: award.award.rewards },
        best: award.state.best,
        newBest: award.newBest,
      });
    }
    if (attempt === MAX_ATTEMPTS) throw new ApiError(409, "sync_conflict", "Your profile changed meanwhile; try again");
    account = (await loadAccount(db, c.uid)) ?? (await ensureAccount(db, c.uid, c.now));
    // The same run may have been recorded by a request that got in first.
    context = await loadRunContext(db, c.uid, run.runId);
    if (context.recorded !== null) return json(duplicateBody(account, context.recorded));
  }
}
