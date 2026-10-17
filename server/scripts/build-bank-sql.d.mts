/** Types for build-bank-sql.mjs (used by vitest.config.ts and tests). */

export interface BankRow {
  readonly id: string;
  readonly heat: number;
  readonly size: number;
  readonly letters: string;
  /** The puzzle's JSON text. */
  readonly data: string;
}

export const DEFAULT_BANK_PATH: string;
export const DEFAULT_OUT_PATH: string;
export function bankRows(bank: unknown): BankRow[];
export function loadBankRows(path?: string): BankRow[];
export function bankSql(rows: readonly BankRow[]): string;
