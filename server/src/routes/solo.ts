/** `POST /v1/solo/sync` (docs/TECH.md §8; rules in src/rules/sync.ts). */

import { ensureAccount, loadAccount, profileBody } from "../db/accounts";
import { campaignStageCount, loadCampaignPuzzles } from "../db/campaign";
import { loadSoloState, writeSync } from "../db/sync";
import { ApiError, isRecord, json, readJsonObject } from "../http";
import { evaluateSync, MAX_SYNC_ENTRIES } from "../rules/sync";
import type { AuthedContext } from "./context";

/** Enough for MAX_SYNC_ENTRIES entries with long bonus lists. */
const MAX_SYNC_BODY_BYTES = 1024 * 1024;

/** Attempts before giving up on a profile that keeps changing underneath us. */
const MAX_ATTEMPTS = 3;

/**
 * `{entries: [...]}` → `{profile, results}`. `results[i]` is the outcome of
 * `entries[i]`. Every result is final: the app can drop every entry it sent,
 * accepted or not, and replace its local profile with `profile`.
 */
export async function postSync(c: AuthedContext): Promise<Response> {
  const body = await readJsonObject(c.request, MAX_SYNC_BODY_BYTES);
  const entries = body.entries;
  if (!Array.isArray(entries)) throw new ApiError(400, "invalid_body", "Expected {entries: [...]}");
  if (entries.length > MAX_SYNC_ENTRIES) {
    throw new ApiError(400, "too_many_entries", `Send at most ${MAX_SYNC_ENTRIES} entries per request`);
  }

  const db = c.env.DB;
  const stages = entries.flatMap((e) => (isRecord(e) && Number.isSafeInteger(e.stage) ? [e.stage as number] : []));
  const puzzles = await loadCampaignPuzzles(db, stages);
  if (puzzles.size < new Set(stages).size && (await campaignStageCount(db)) === 0) {
    // Not the player's fault: don't let the app throw its queue away.
    throw new ApiError(503, "campaign_unavailable", "The campaign hasn't been loaded on the server");
  }

  let account = await ensureAccount(db, c.uid, c.now);
  for (let attempt = 1; ; attempt++) {
    const state = await loadSoloState(db, account, stages);
    const outcome = evaluateSync({ uid: c.uid, now: c.now, state, entries, puzzles });
    if (outcome.accepted.length === 0 || (await writeSync(db, account, outcome, c.now))) {
      const fresh = outcome.accepted.length === 0 ? account : (await loadAccount(db, c.uid))!;
      return json({ profile: profileBody(fresh), results: outcome.results });
    }
    if (attempt === MAX_ATTEMPTS) throw new ApiError(409, "sync_conflict", "Your profile changed during the sync; try again");
    account = (await loadAccount(db, c.uid)) ?? (await ensureAccount(db, c.uid, c.now));
  }
}
