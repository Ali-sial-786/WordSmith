/**
 * `GET /v1/define/:word` → `{word, senses: [{pos, gloss}], source}`: what a
 * word the app's offline lexicon lacks means, from an online dictionary
 * (src/dictionary/define.ts). Open, like `/v1/version`, since meanings work
 * signed out.
 *
 * - `400 invalid_word` unless the word is 2–15 letters A–Z
 * - `404 word_not_found` when no dictionary has it
 * - `502 dictionary_unavailable` when a dictionary couldn't be asked and the
 *   other didn't have it (not cached, so the next ask tries again)
 *
 * Answers are kept in the Workers Cache API (each data centre's own cache):
 * definitions for {@link HIT_TTL_SECONDS}, misses for {@link MISS_TTL_SECONDS}.
 */

import { define, DictionaryUnavailable, normalizeWord, type Definition } from "../dictionary/define";
import { ApiError, errorResponse, json } from "../http";
import type { RequestContext } from "./context";

export const HIT_TTL_SECONDS = 30 * 86_400;
export const MISS_TTL_SECONDS = 86_400;

/** Part of the cache key: bump it when the cached body or the sense picking changes. */
const CACHE_VERSION = 1;

/** What the cache holds for a word: its definition, or null for a miss. */
interface Cached {
  readonly definition: Definition | null;
}

export async function getDefine(c: RequestContext): Promise<Response> {
  const word = normalizeWord(c.params.word ?? "");
  if (word === null) throw new ApiError(400, "invalid_word", "Expected 2–15 letters A–Z");

  const cache = caches.default;
  const key = new Request(new URL(`/v1/define/${word}?v=${CACHE_VERSION}`, c.request.url));
  const hit = await cache.match(key);
  if (hit !== undefined) return answer((await hit.json()) as Cached);

  let definition: Definition | null;
  try {
    definition = await define(word);
  } catch (err) {
    if (!(err instanceof DictionaryUnavailable)) throw err;
    console.warn(`define ${word}: no dictionary could be reached`, err.causes);
    throw new ApiError(502, "dictionary_unavailable");
  }
  const entry: Cached = { definition };
  const ttl = definition === null ? MISS_TTL_SECONDS : HIT_TTL_SECONDS;
  c.ctx.waitUntil(
    cache.put(key, json(entry, 200, { "Cache-Control": `public, max-age=${ttl}` })).catch((err: unknown) => {
      console.warn(`define ${word}: caching failed`, err);
    }),
  );
  return answer(entry);
}

function answer({ definition }: Cached): Response {
  if (definition === null) {
    return errorResponse(404, "word_not_found", undefined, { "Cache-Control": `public, max-age=${MISS_TTL_SECONDS}` });
  }
  return json(definition, 200, { "Cache-Control": `public, max-age=${HIT_TTL_SECONDS}` });
}
