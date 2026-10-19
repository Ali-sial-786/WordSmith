/**
 * Ages (shared/age.md). Players give the month and year they were born, not
 * the day, so an age counts a birthday only once its month is over: someone
 * born in October 2013 is 12 for all of October 2026. That errs young, which
 * is the safe side for both the 13+ rule and the under-18 defaults.
 */

/** Online play (an account) is for this age and over. */
export const MIN_AGE = 13;
/**
 * In Quebec, personal information of a child under 14 needs a parent's
 * consent (Law 25, s. 4.1), which Wordsmith doesn't collect, so online play
 * there starts at 14.
 */
export const MIN_AGE_QUEBEC = 14;
/** Under this age, a player gets the defaults for minors (the microphone starts muted). */
export const ADULT_AGE = 18;
/** Oldest birth year accepted, as years before now. */
export const MAX_AGE = 120;

export interface Birth {
  readonly year: number;
  /** 1–12. */
  readonly month: number;
}

/** A `{birthYear, birthMonth}` body's birth, or null if either is missing or impossible at `now` (epoch ms). */
export function parseBirth(year: unknown, month: unknown, now: number): Birth | null {
  if (typeof year !== "number" || typeof month !== "number" || !Number.isInteger(year) || !Number.isInteger(month)) return null;
  if (month < 1 || month > 12) return null;
  const today = new Date(now);
  const thisYear = today.getUTCFullYear();
  if (year < thisYear - MAX_AGE || year > thisYear) return null;
  if (year === thisYear && month > today.getUTCMonth() + 1) return null;
  return { year, month };
}

/** Whole years old at `now`, counting a birthday only after its month is over (UTC). */
export function ageAt(birth: Birth, now: number): number {
  const today = new Date(now);
  const month = today.getUTCMonth() + 1;
  return today.getUTCFullYear() - birth.year - (month <= birth.month ? 1 : 0);
}
