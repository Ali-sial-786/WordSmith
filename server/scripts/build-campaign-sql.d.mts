/** Types for build-campaign-sql.mjs (used by vitest.config.ts and tests). */

export interface CampaignRow {
  readonly stage: number;
  readonly puzzleId: string;
  /** The puzzle's JSON text. */
  readonly data: string;
}

export const DEFAULT_CAMPAIGN_PATH: string;
export const DEFAULT_OUT_PATH: string;
/** A stage of an earlier campaign edition (the `campaign_previous` table). */
export interface EarlierCampaignRow extends CampaignRow {
  /** 1 for the oldest edition kept. */
  readonly edition: number;
}

export interface EarlierEdition {
  readonly edition: number;
  /** The app version that has it built in. */
  readonly app: string;
  readonly path: string;
}

export const EARLIER_EDITIONS: readonly EarlierEdition[];
export function campaignRows(campaign: unknown): CampaignRow[];
export function loadCampaignRows(path?: string): CampaignRow[];
export function loadEarlierCampaignRows(editions?: readonly EarlierEdition[]): EarlierCampaignRow[];
export function campaignSql(rows: readonly CampaignRow[], earlier?: readonly EarlierCampaignRow[]): string;
