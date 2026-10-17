/** Types for build-campaign-sql.mjs (used by vitest.config.ts and tests). */

export interface CampaignRow {
  readonly stage: number;
  readonly puzzleId: string;
  /** The puzzle's JSON text. */
  readonly data: string;
}

export const DEFAULT_CAMPAIGN_PATH: string;
export const DEFAULT_OUT_PATH: string;
export function campaignRows(campaign: unknown): CampaignRow[];
export function loadCampaignRows(path?: string): CampaignRow[];
export function campaignSql(rows: readonly CampaignRow[]): string;
