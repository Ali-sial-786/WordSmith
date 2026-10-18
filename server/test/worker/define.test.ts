/**
 * `GET /v1/define/:word`: open to everyone, answered from a stand-in for the
 * Free Dictionary API and Wiktionary (setDictionaryFetcher), and cached in the
 * Workers Cache API. Each test uses its own words, since the cache outlives a test.
 */

import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it } from "vitest";
import { DICTIONARY_API_URL, setDictionaryFetcher, USER_AGENT, WIKTIONARY_URL } from "../../src/dictionary/define";
import { HIT_TTL_SECONDS, MISS_TTL_SECONDS } from "../../src/routes/define";
import worker from "../../src/index";
import { BASE, body } from "./helpers";

const PLAY = "https://play.wordsmith-forge.workers.dev";

/** The dictionaries, answering from `pages` (404 for anything else) and recording each URL asked. */
function fakeDictionaries(pages: Record<string, unknown>, status: Record<string, number> = {}) {
  const asked: { url: string; userAgent: string | null }[] = [];
  setDictionaryFetcher(async (input, init) => {
    const req = new Request(input, init);
    asked.push({ url: req.url, userAgent: req.headers.get("user-agent") });
    const code = status[req.url];
    if (code !== undefined) return new Response("try later", { status: code });
    if (!(req.url in pages)) return Response.json({ title: "Not found." }, { status: 404 });
    return Response.json(pages[req.url]);
  });
  return asked;
}

const IncomingRequest = Request<unknown, IncomingRequestCfProperties>;

/** A request through the Worker, waiting for what it does after answering (the cache write). */
async function get(path: string, init?: RequestInit<IncomingRequestCfProperties>): Promise<Response> {
  const ctx = createExecutionContext();
  const res = await worker.fetch(new IncomingRequest(BASE + path, init), env, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

const dictionaryApi = (gloss: string, partOfSpeech = "noun") => [{ meanings: [{ partOfSpeech, definitions: [{ definition: gloss }] }] }];
const wiktionary = (html: string, partOfSpeech = "Proper noun") => ({
  en: [{ partOfSpeech, language: "English", definitions: [{ definition: html }] }],
});

afterEach(() => setDictionaryFetcher(null));

describe("GET /v1/define/:word", () => {
  it("needs no sign-in and answers from the Free Dictionary API, lowercased", async () => {
    const asked = fakeDictionaries({
      [`${DICTIONARY_API_URL}quench`]: [
        {
          meanings: [
            { partOfSpeech: "verb", definitions: [{ definition: "To cool hot metal in water." }, { definition: "To satisfy thirst." }] },
            { partOfSpeech: "noun", definitions: [{ definition: "The act of quenching." }] },
          ],
        },
      ],
    });
    const res = await get("/v1/define/QUENCH");
    expect(res.status).toBe(200);
    expect(await body(res)).toEqual({
      word: "quench",
      senses: [
        { pos: "v", gloss: "To cool hot metal in water." },
        { pos: "n", gloss: "The act of quenching." },
        { pos: "v", gloss: "To satisfy thirst." },
      ],
      source: "dictionaryapi.dev",
    });
    expect(res.headers.get("cache-control")).toBe(`public, max-age=${HIT_TTL_SECONDS}`);
    expect(asked).toEqual([{ url: `${DICTIONARY_API_URL}quench`, userAgent: USER_AGENT }]);
  });

  it("falls back to Wiktionary for names, with its HTML stripped", async () => {
    const asked = fakeDictionaries({
      [`${WIKTIONARY_URL}Omari`]: wiktionary('A <a rel="mw:WikiLink" href="/wiki/male">male</a> given name.'),
    });
    const res = await get("/v1/define/omari");
    expect(res.status).toBe(200);
    expect(await body(res)).toEqual({ word: "omari", senses: [{ pos: "proper noun", gloss: "A male given name." }], source: "wiktionary" });
    expect(asked.map((a) => a.url)).toEqual([`${DICTIONARY_API_URL}omari`, `${WIKTIONARY_URL}omari`, `${WIKTIONARY_URL}Omari`]);
    expect(asked.every((a) => a.userAgent === USER_AGENT)).toBe(true);
  });

  it("is a 404 when neither dictionary has the word", async () => {
    fakeDictionaries({});
    const res = await get("/v1/define/zqxjv");
    expect(res.status).toBe(404);
    expect(await body(res)).toEqual({ error: "word_not_found" });
    expect(res.headers.get("cache-control")).toBe(`public, max-age=${MISS_TTL_SECONDS}`);
  });

  it("keeps hits and misses in the cache", async () => {
    const asked = fakeDictionaries({ [`${DICTIONARY_API_URL}tempered`]: dictionaryApi("Hardened by heating and cooling.", "adjective") });
    const first = await body(await get("/v1/define/tempered"));
    const again = await get("/v1/define/Tempered");
    expect(again.status).toBe(200);
    expect(await body(again)).toEqual(first);
    expect(first).toMatchObject({ senses: [{ pos: "a", gloss: "Hardened by heating and cooling." }] });

    expect((await get("/v1/define/qqzzx")).status).toBe(404);
    const miss = await get("/v1/define/qqzzx");
    expect(miss.status).toBe(404);
    expect(await body(miss)).toEqual({ error: "word_not_found" });
    // One ask for the hit; three (one source, then two Wiktionary titles) for the miss.
    expect(asked.map((a) => a.url)).toEqual([
      `${DICTIONARY_API_URL}tempered`,
      `${DICTIONARY_API_URL}qqzzx`,
      `${WIKTIONARY_URL}qqzzx`,
      `${WIKTIONARY_URL}Qqzzx`,
    ]);
  });

  it("is a 502 when a dictionary can't be asked, and asks again next time", async () => {
    let asked = fakeDictionaries({}, { [`${DICTIONARY_API_URL}bellows`]: 503 });
    const res = await get("/v1/define/bellows");
    expect(res.status).toBe(502);
    expect(await body(res)).toEqual({ error: "dictionary_unavailable" });
    expect(asked).toHaveLength(3);

    asked = fakeDictionaries({ [`${DICTIONARY_API_URL}bellows`]: dictionaryApi("A device for blowing air into a fire.") });
    const later = await get("/v1/define/bellows");
    expect(later.status).toBe(200);
    expect(await body(later)).toMatchObject({ senses: [{ pos: "n", gloss: "A device for blowing air into a fire." }] });
    expect(asked).toHaveLength(1);
  });

  it("refuses anything but 2–15 letters A–Z, without asking", async () => {
    const asked = fakeDictionaries({});
    for (const word of ["a", "abcdefghijklmnop", "forge1", "for%20ge", "caf%C3%A9", "%E2%84%AAelvin", "__proto__", "%ZZ"]) {
      const res = await get(`/v1/define/${word}`);
      expect(res.status, word).toBe(word === "%ZZ" ? 404 : 400);
      if (word !== "%ZZ") expect(await body(res), word).toEqual({ error: "invalid_word", message: "Expected 2–15 letters A–Z" });
    }
    expect(asked).toEqual([]);
  });

  it("lets the browser version read it", async () => {
    fakeDictionaries({ [`${DICTIONARY_API_URL}anvil`]: dictionaryApi("A heavy iron block on which metal is hammered.") });
    const res = await get("/v1/define/anvil", { headers: { Origin: PLAY } });
    expect(res.status).toBe(200);
    expect(res.headers.get("access-control-allow-origin")).toBe(PLAY);
  });
});
