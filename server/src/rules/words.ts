/**
 * Word shape checks shared by every mode (docs/TECH.md §6 "Checking a word").
 *
 * These checks don't use a dictionary. Whether a word is an answer or a bonus
 * word is looked up in the puzzle's precomputed sets (see coop.ts).
 */

/** Words shorter than this are never accepted. */
export const MIN_WORD_LENGTH = 3;

const LATIN_LETTERS = /^[A-Za-z]+$/;

/**
 * Normalises a submitted word to uppercase A–Z.
 *
 * Surrounding whitespace is trimmed. Anything else that isn't an ASCII letter
 * (digits, punctuation, accented letters, inner spaces) makes the word
 * invalid and returns `null`; nothing is stripped out. The anvil only has
 * A–Z tiles, so a well-behaved client never sends anything else.
 */
export function normalizeWord(raw: string): string | null {
  const trimmed = raw.trim();
  if (!LATIN_LETTERS.test(trimmed)) return null;
  return trimmed.toUpperCase();
}

/**
 * Whether `word` can be spelled from the anvil `letters`, using each tile no
 * more often than it appears. Both arguments must already be normalised
 * (uppercase A–Z).
 */
export function canBeMadeFrom(word: string, letters: string): boolean {
  if (word.length > letters.length) return false;
  const available = new Map<string, number>();
  for (const ch of letters) available.set(ch, (available.get(ch) ?? 0) + 1);
  for (const ch of word) {
    const left = available.get(ch) ?? 0;
    if (left === 0) return false;
    available.set(ch, left - 1);
  }
  return true;
}

/**
 * Full shape check for a guess: normalise it, require at least
 * {@link MIN_WORD_LENGTH} letters, and require that it can be made from the
 * anvil letters. Returns the normalised word, or `null` if the guess fails
 * any of these.
 *
 * `letters` must already be normalised (puzzles store them uppercase).
 */
export function checkGuess(raw: string, letters: string): string | null {
  const word = normalizeWord(raw);
  if (word === null || word.length < MIN_WORD_LENGTH) return null;
  return canBeMadeFrom(word, letters) ? word : null;
}
