/**
 * Online definitions for words the app's offline lexicon (WordNet, from
 * tools/dictgen) lacks, such as names and rarer words: `GET /v1/define/:word`
 * (src/routes/define.ts). The Free Dictionary API (dictionaryapi.dev) is
 * asked first, then Wiktionary's REST definitions, lowercase title first and
 * then capitalised (names). Both serve Wiktionary's text (CC BY-SA), and the
 * app says which one a meaning came from.
 *
 * Senses are picked the way tools/dictgen picks the lexicon's: at most
 * {@link MAX_SENSES}, round robin across parts of speech (the one with more
 * senses first), duplicates dropped, each gloss at most {@link MAX_GLOSS}
 * characters, and slur and sexual senses left out (the patterns of
 * tools/dictgen/data/gloss_filter.txt, plus Wiktionary's own labels).
 *
 * Tests swap the network with {@link setDictionaryFetcher}.
 */

import { isRecord } from "../http";

export const DICTIONARY_API_URL = "https://api.dictionaryapi.dev/api/v2/entries/en/";
export const WIKTIONARY_URL = "https://en.wiktionary.org/api/rest_v1/page/definition/";

/** Wikimedia's API policy asks clients to say who they are and where to find out more. */
export const USER_AGENT = "WordsmithAPI/1.0 (https://github.com/Ali-sial-786/WordSmith; definitions for a word game)";

export const MAX_SENSES = 3;
export const MAX_GLOSS = 160;

/** Each source gets this long to answer. */
const TIMEOUT_MS = 5000;

/** What the app's `Sense.pos` is: `n`, `v`, `a`, `r` (WordNet's), another part of speech spelled out, or "". */
export interface Sense {
  readonly pos: string;
  readonly gloss: string;
}

export type DefinitionSource = "dictionaryapi.dev" | "wiktionary";

/** The body of `GET /v1/define/:word`. */
export interface Definition {
  readonly word: string;
  readonly senses: readonly Sense[];
  readonly source: DefinitionSource;
}

/** `raw` lowercased if it's 2–15 letters A–Z (either case), else null. */
export function normalizeWord(raw: string): string | null {
  return /^[A-Za-z]{2,15}$/.test(raw) ? raw.toLowerCase() : null;
}

// ---------------------------------------------------------------------------
// Parts of speech and glosses
// ---------------------------------------------------------------------------

/** The four parts of speech WordNet has, as the app's codes. */
const POS_CODES = new Map([
  ["noun", "n"],
  ["verb", "v"],
  ["adjective", "a"],
  ["adverb", "r"],
]);

/** Other parts of speech, which the app shows as they're spelled here. */
const OTHER_POS = new Set([
  "proper noun",
  "pronoun",
  "preposition",
  "conjunction",
  "interjection",
  "exclamation",
  "determiner",
  "article",
  "numeral",
  "particle",
  "prefix",
  "suffix",
  "abbreviation",
  "initialism",
  "acronym",
  "contraction",
  "phrase",
  "idiom",
  "proverb",
  "symbol",
  "letter",
]);

/** A source's part of speech ("Noun", "proper noun", …) as the app labels it; "" if it has none. */
export function posLabel(raw: unknown): string {
  if (typeof raw !== "string") return "";
  const name = raw.trim().toLowerCase().replace(/\s+/g, " ");
  return POS_CODES.get(name) ?? (OTHER_POS.has(name) ? name : "");
}

const ENTITIES = new Map([
  ["amp", "&"],
  ["lt", "<"],
  ["gt", ">"],
  ["quot", '"'],
  ["apos", "'"],
  ["nbsp", " "],
  ["ndash", "–"],
  ["mdash", "—"],
  ["hellip", "…"],
]);

/** Wiktionary's definition HTML as plain text: no tags, inline styles or nested lists, entities decoded. */
export function stripHtml(html: string): string {
  return html
    .replace(/<(style|script)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, "")
    .replace(/<(ol|ul|dl)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, " ")
    .replace(/<[^>]*>/g, "")
    .replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, name: string) => {
      if (name[0] !== "#") return ENTITIES.get(name.toLowerCase()) ?? whole;
      const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
    })
    .replace(/\s+/g, " ")
    .trim();
}

/** At most `limit` characters; longer text is cut at a word boundary and ends with an ellipsis (as dictgen's). */
export function shorten(text: string, limit = MAX_GLOSS): string {
  if (text.length <= limit) return text;
  let cut = text.slice(0, limit - 1);
  if (text[limit - 1] !== " ") {
    const space = cut.lastIndexOf(" ");
    if (space >= Math.floor(limit / 2)) cut = cut.slice(0, space);
  }
  return `${cut.replace(/[ ,;:\-(]+$/, "")}…`;
}

/** Whitespace and stray `;` / `,` / a trailing `:` cleaned, then {@link shorten}ed. */
export function cleanGloss(text: string): string {
  const t = text
    .split(/\s+/)
    .join(" ")
    .replace(/\s+([;,])/g, "$1")
    .replace(/;(\s*;)+/g, ";")
    .replace(/^[ ;,]+|[ ;,:]+$/g, "");
  return shorten(t);
}

// ---------------------------------------------------------------------------
// The gloss filter
// ---------------------------------------------------------------------------

/** Always dropped: tools/dictgen/data/gloss_filter.txt's `[always]`, and Wiktionary's slur labels. */
const ALWAYS: readonly RegExp[] = [
  /\bethnic slur\b/i,
  /\boffensive (and (derogatory|disparaging) )?(term|name|word|slang)s?\b/i,
  /\bobscene (term|word)s? for\b/i,
  /\bvulgar (slang|term|expression)s?\b/i,
  /\b(derogatory|disparaging)\b.*\b(white|black|british|english|irish|italian|german|jews?|jewish|christians?|catholics?|muslims?|indians?|asian|african|mexican|latin|chinese|japanese|homosexual|gay|lesbian)\b/i,
  /\bmasturbat/i,
  /\borgasm/i,
  /\bejaculat/i,
  /\bfellatio\b/i,
  /\bcunnilingus\b/i,
  /\b(oral|anal) (sex|copulation|intercourse)\b/i,
  /\bsodom/i,
  /\bpornograph/i,
  /\berotic/i,
  /\bsex acts?\b/i,
  /\bsexually (arous|excit|stimulat|gratif)/i,
  /\bsexual fondling\b/i,
  /\berect penis\b/i,
  // Wiktionary's labels, e.g. "(vulgar, slang)" or "(offensive)".
  /\([^)]*\b(offensive|vulgar|slur|ethnic slur|obscene)s?\b[^)]*\)/i,
];

/** Dropped unless nothing else is left to show: gloss_filter.txt's `[unless-only]`. */
const UNLESS_ONLY: readonly RegExp[] = [
  /\bsexual intercourse\b/i,
  /\bsexual (activity|activities|relations|organs?)\b/i,
  /\bha(ve|s|ving) sex\b/i,
  /\bcopulat/i,
  /\bcoit(us|al)\b/i,
  /\bfornicat/i,
  /\bgenital(s|ia)?\b/i,
  /\bpenis/i,
  /\bvagina/i,
  /\bvulva/i,
  /\bclitor/i,
  /\bpubic hair\b/i,
  /\b(derogatory|disparaging) (term|name|reference)s?\b/i,
  /\([^)]*\b(derogatory|pejorative|disparaging)\b[^)]*\)/i,
];

function blocked(gloss: string, dropUnlessOnly: boolean): boolean {
  return ALWAYS.some((p) => p.test(gloss)) || (dropUnlessOnly && UNLESS_ONLY.some((p) => p.test(gloss)));
}

// ---------------------------------------------------------------------------
// Picking senses
// ---------------------------------------------------------------------------

/**
 * Up to {@link MAX_SENSES} of a source's senses, in its order within a part
 * of speech. Across parts of speech, round robin (the first of each, then the
 * second of each, …); the one with more senses goes first, ties in the order
 * they first appear. Filtered senses are left out; `[unless-only]` ones come
 * back when nothing else would be left.
 */
export function pickSenses(raw: readonly Sense[]): Sense[] {
  const picked = pick(raw, true);
  return picked.length > 0 ? picked : pick(raw, false);
}

function pick(raw: readonly Sense[], dropUnlessOnly: boolean): Sense[] {
  const groups = new Map<string, string[]>();
  const seen = new Set<string>();
  for (const sense of raw) {
    if (blocked(sense.gloss, dropUnlessOnly)) continue;
    const gloss = cleanGloss(sense.gloss);
    if (gloss === "" || seen.has(gloss)) continue;
    seen.add(gloss);
    const group = groups.get(sense.pos);
    if (group === undefined) groups.set(sense.pos, [gloss]);
    else group.push(gloss);
  }
  // Array.prototype.sort is stable, so ties keep their first appearance.
  const order = [...groups.entries()].sort((a, b) => b[1].length - a[1].length);
  const out: Sense[] = [];
  for (let i = 0; out.length < MAX_SENSES && order.some(([, glosses]) => i < glosses.length); i++) {
    for (const [pos, glosses] of order) {
      if (i < glosses.length && out.length < MAX_SENSES) out.push({ pos, gloss: glosses[i]! });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// The sources
// ---------------------------------------------------------------------------

/** Every sense in a Free Dictionary API answer (an array of entries, each with `meanings`). */
export function parseDictionaryApi(body: unknown): Sense[] {
  const out: Sense[] = [];
  if (!Array.isArray(body)) return out;
  for (const entry of body) {
    if (!isRecord(entry) || !Array.isArray(entry.meanings)) continue;
    for (const meaning of entry.meanings) {
      if (!isRecord(meaning) || !Array.isArray(meaning.definitions)) continue;
      const pos = posLabel(meaning.partOfSpeech);
      for (const d of meaning.definitions) {
        if (isRecord(d) && typeof d.definition === "string") out.push({ pos, gloss: d.definition });
      }
    }
  }
  return out;
}

/** Every English sense in a Wiktionary REST definitions answer (`{en: [{partOfSpeech, language, definitions}], …}`). */
export function parseWiktionary(body: unknown): Sense[] {
  const out: Sense[] = [];
  if (!isRecord(body) || !Array.isArray(body.en)) return out;
  for (const entry of body.en) {
    if (!isRecord(entry) || !Array.isArray(entry.definitions)) continue;
    if (typeof entry.language === "string" && entry.language !== "English") continue;
    const pos = posLabel(entry.partOfSpeech);
    for (const d of entry.definitions) {
      if (isRecord(d) && typeof d.definition === "string") out.push({ pos, gloss: stripHtml(d.definition) });
    }
  }
  return out;
}

const defaultFetch: typeof fetch = (input, init) => fetch(input, init);
let fetcher: typeof fetch = defaultFetch;

/** For tests: where requests to the dictionaries go instead of `fetch` (`null` restores it). */
export function setDictionaryFetcher(fn: typeof fetch | null): void {
  fetcher = fn ?? defaultFetch;
}

/** A source's JSON, or null when it has no such page (404). Throws when it couldn't be asked. */
async function getJson(url: string): Promise<unknown> {
  const res = await fetcher(url, {
    headers: { "User-Agent": USER_AGENT, Accept: "application/json" },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (res.status === 404) {
    await res.body?.cancel();
    return null;
  }
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`${url} answered ${res.status}`);
  }
  return res.json();
}

async function fromDictionaryApi(word: string): Promise<Sense[]> {
  return pickSenses(parseDictionaryApi(await getJson(DICTIONARY_API_URL + word)));
}

async function fromWiktionary(word: string): Promise<Sense[]> {
  // Titles are case-sensitive: "ali" is a different page from "Ali".
  for (const title of [word, word[0]!.toUpperCase() + word.slice(1)]) {
    const senses = pickSenses(parseWiktionary(await getJson(WIKTIONARY_URL + encodeURIComponent(title))));
    if (senses.length > 0) return senses;
  }
  return [];
}

const SOURCES: readonly { readonly name: DefinitionSource; readonly lookUp: (word: string) => Promise<Sense[]> }[] = [
  { name: "dictionaryapi.dev", lookUp: fromDictionaryApi },
  { name: "wiktionary", lookUp: fromWiktionary },
];

/** Thrown by {@link define} when a source couldn't be asked and none of the others had the word. */
export class DictionaryUnavailable extends Error {
  constructor(readonly causes: readonly unknown[]) {
    super("no dictionary could be reached");
    this.name = "DictionaryUnavailable";
  }
}

/**
 * What `word` (already {@link normalizeWord}ed) means, from the first source
 * that has it; null when every source answered that it doesn't.
 */
export async function define(word: string): Promise<Definition | null> {
  const failures: unknown[] = [];
  for (const source of SOURCES) {
    try {
      const senses = await source.lookUp(word);
      if (senses.length > 0) return { word, senses, source: source.name };
    } catch (err) {
      failures.push(err);
    }
  }
  if (failures.length > 0) throw new DictionaryUnavailable(failures);
  return null;
}
