/** Bindings and vars from wrangler.jsonc. Keep the two in step. */
export interface Env {
  DB: D1Database;
  LATEST_VERSION: string;
  MIN_SUPPORTED_VERSION: string;
}
