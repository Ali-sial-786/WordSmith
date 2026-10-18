import { afterEach, describe, expect, it } from "vitest";
import {
  cleanGloss,
  define,
  DICTIONARY_API_URL,
  DictionaryUnavailable,
  MAX_GLOSS,
  normalizeWord,
  parseDictionaryApi,
  parseWiktionary,
  pickSenses,
  posLabel,
  setDictionaryFetcher,
  shorten,
  stripHtml,
  USER_AGENT,
  WIKTIONARY_URL,
} from "../../src/dictionary/define";

/** The shape of dictionaryapi.dev's answer for "forge", trimmed. */
const FORGE = [
  {
    word: "forge",
    meanings: [
      {
        partOfSpeech: "noun",
        definitions: [
          { definition: "Furnace or hearth where metals are heated prior to hammering them into shape.", synonyms: [] },
          { definition: "Workshop in which metals are shaped by heating and hammering them.", synonyms: [] },
        ],
      },
    ],
  },
  {
    word: "forge",
    meanings: [
      {
        partOfSpeech: "verb",
        definitions: [
          { definition: "To shape a metal by heating and hammering." },
          { definition: "To form or create with concerted effort.", example: "The politician's..." },
          { definition: "To create a forgery of; to make a counterfeit item of." },
        ],
      },
    ],
  },
];

/** The shape of Wiktionary's REST definitions for a name. */
const ALI = {
  en: [
    {
      partOfSpeech: "Proper noun",
      language: "English",
      definitions: [
        {
          definition:
            '<link rel="mw-deduplicated-inline-style" href="mw-data:TemplateStyles:r1"><style data-mw-deduplicate="TemplateStyles:r1">.mw-parser-output .x{color:red}</style>A <a rel="mw:WikiLink" href="/wiki/male" title="male">male</a> <a rel="mw:WikiLink" href="/wiki/given_name" title="given name">given name</a> from <span class="etyl">Arabic</span>.',
          parsedExamples: [],
        },
        { definition: "" },
      ],
    },
  ],
  sw: [{ partOfSpeech: "Noun", language: "Swahili", definitions: [{ definition: "spirit" }] }],
};

interface Call {
  readonly url: string;
  readonly headers: Headers;
}

/** Answers each URL from `pages` (status 404 when missing), recording the calls. */
function fakeNet(pages: Record<string, unknown>, status: Record<string, number> = {}) {
  const calls: Call[] = [];
  const fetchFn: typeof fetch = async (input, init) => {
    const req = new Request(input, init);
    calls.push({ url: req.url, headers: req.headers });
    const code = status[req.url];
    if (code !== undefined) return new Response("busy", { status: code });
    if (!(req.url in pages)) return Response.json({ title: "No Definitions Found" }, { status: 404 });
    return Response.json(pages[req.url]);
  };
  setDictionaryFetcher(fetchFn);
  return calls;
}

afterEach(() => setDictionaryFetcher(null));

describe("normalizeWord", () => {
  it("takes 2–15 letters A–Z, lowercased", () => {
    expect(normalizeWord("Forge")).toBe("forge");
    expect(normalizeWord("OX")).toBe("ox");
    expect(normalizeWord("abcdefghijklmno")).toBe("abcdefghijklmno");
    for (const bad of ["", "a", "abcdefghijklmnop", "forge!", "for ge", "café", "Kelvin", "x1", "__proto__"]) {
      expect(normalizeWord(bad), bad).toBeNull();
    }
  });
});

describe("parts of speech and glosses", () => {
  it("maps parts of speech to the app's labels", () => {
    expect(["noun", "Verb", "Adjective", "adverb"].map(posLabel)).toEqual(["n", "v", "a", "r"]);
    expect(posLabel("Proper noun")).toBe("proper noun");
    expect(posLabel("interjection")).toBe("interjection");
    expect(posLabel("Romanization")).toBe("");
    expect(posLabel("constructor")).toBe("");
    expect(posLabel(undefined)).toBe("");
  });

  it("strips Wiktionary's HTML", () => {
    expect(stripHtml(ALI.en[0]!.definitions[0]!.definition)).toBe("A male given name from Arabic.");
    expect(stripHtml("Tom &amp; Jerry&#39;s &#x263A; &lt;tag&gt;&nbsp;x &bogus;")).toBe("Tom & Jerry's ☺ <tag> x &bogus;");
    expect(stripHtml("A tool.<ol><li>sub-sense</li></ol>")).toBe("A tool.");
  });

  it("cleans and shortens glosses like dictgen", () => {
    expect(cleanGloss("  a\n tool ; for  forging ;; ,")).toBe("a tool; for forging");
    expect(cleanGloss("Introducing:")).toBe("Introducing");
    const long = "word ".repeat(60).trim();
    const short = shorten(long);
    expect(short.length).toBeLessThanOrEqual(MAX_GLOSS);
    expect(short.endsWith("word…")).toBe(true);
    expect(shorten("short")).toBe("short");
  });
});

describe("pickSenses", () => {
  it("takes at most three, round robin, the part of speech with more senses first", () => {
    expect(pickSenses(parseDictionaryApi(FORGE))).toEqual([
      { pos: "v", gloss: "To shape a metal by heating and hammering." },
      { pos: "n", gloss: "Furnace or hearth where metals are heated prior to hammering them into shape." },
      { pos: "v", gloss: "To form or create with concerted effort." },
    ]);
  });

  it("drops duplicates, empty glosses, slurs and sexual senses", () => {
    expect(
      pickSenses([
        { pos: "n", gloss: "(vulgar, slang) Something rude." },
        { pos: "n", gloss: "(ethnic slur) Something worse." },
        { pos: "n", gloss: "A kind of hat." },
        { pos: "n", gloss: " A kind of  hat. " },
        { pos: "n", gloss: "  " },
        { pos: "n", gloss: "(derogatory) A clumsy person." },
      ]),
    ).toEqual([{ pos: "n", gloss: "A kind of hat." }]);
  });

  it("keeps an [unless-only] sense when it's all there is", () => {
    expect(pickSenses([{ pos: "n", gloss: "(derogatory) A clumsy person." }])).toEqual([
      { pos: "n", gloss: "(derogatory) A clumsy person." },
    ]);
    expect(pickSenses([{ pos: "n", gloss: "(offensive) Never shown." }])).toEqual([]);
  });

  it("reads only English entries from Wiktionary", () => {
    expect(parseWiktionary(ALI)).toEqual([
      { pos: "proper noun", gloss: "A male given name from Arabic." },
      { pos: "proper noun", gloss: "" },
    ]);
    expect(parseWiktionary({ sw: ALI.sw })).toEqual([]);
    expect(parseWiktionary({ en: [{ language: "Translingual", partOfSpeech: "Symbol", definitions: [{ definition: "x" }] }] })).toEqual([]);
    for (const junk of [null, [], "x", { en: "x" }, { en: [null, { definitions: "x" }] }]) expect(parseWiktionary(junk)).toEqual([]);
    for (const junk of [null, {}, [null, { meanings: [null, { definitions: [null, { definition: 3 }] }] }]]) {
      expect(parseDictionaryApi(junk)).toEqual([]);
    }
  });
});

describe("define", () => {
  it("asks the Free Dictionary API first, saying who's asking", async () => {
    const calls = fakeNet({ [`${DICTIONARY_API_URL}forge`]: FORGE });
    const found = await define("forge");
    expect(found?.source).toBe("dictionaryapi.dev");
    expect(found?.word).toBe("forge");
    expect(found?.senses).toHaveLength(3);
    expect(calls.map((c) => c.url)).toEqual([`${DICTIONARY_API_URL}forge`]);
    expect(calls[0]!.headers.get("user-agent")).toBe(USER_AGENT);
  });

  it("falls back to Wiktionary, trying a capitalised title for names", async () => {
    const calls = fakeNet({ [`${WIKTIONARY_URL}Ali`]: ALI });
    expect(await define("ali")).toEqual({
      word: "ali",
      senses: [{ pos: "proper noun", gloss: "A male given name from Arabic." }],
      source: "wiktionary",
    });
    expect(calls.map((c) => c.url)).toEqual([`${DICTIONARY_API_URL}ali`, `${WIKTIONARY_URL}ali`, `${WIKTIONARY_URL}Ali`]);
    expect(calls.every((c) => c.headers.get("user-agent") === USER_AGENT)).toBe(true);
  });

  it("uses Wiktionary when the Free Dictionary API has only filtered senses", async () => {
    fakeNet({
      [`${DICTIONARY_API_URL}zzxq`]: [{ meanings: [{ partOfSpeech: "noun", definitions: [{ definition: "(vulgar) rude" }] }] }],
      [`${WIKTIONARY_URL}zzxq`]: { en: [{ partOfSpeech: "Noun", language: "English", definitions: [{ definition: "A <b>polite</b> thing." }] }] },
    });
    expect(await define("zzxq")).toMatchObject({ source: "wiktionary", senses: [{ pos: "n", gloss: "A polite thing." }] });
  });

  it("is null when neither has the word", async () => {
    const calls = fakeNet({});
    expect(await define("qwzx")).toBeNull();
    expect(calls).toHaveLength(3);
  });

  it("still finds the word when one source is down", async () => {
    fakeNet({ [`${WIKTIONARY_URL}ali`]: ALI }, { [`${DICTIONARY_API_URL}ali`]: 503 });
    expect((await define("ali"))?.source).toBe("wiktionary");
  });

  it("throws when a source couldn't be asked and the other doesn't have it", async () => {
    fakeNet({}, { [`${DICTIONARY_API_URL}qwzx`]: 429 });
    await expect(define("qwzx")).rejects.toBeInstanceOf(DictionaryUnavailable);
    setDictionaryFetcher(async () => {
      throw new TypeError("network down");
    });
    await expect(define("qwzx")).rejects.toBeInstanceOf(DictionaryUnavailable);
    setDictionaryFetcher(async () => new Response("<html>not json</html>", { status: 200 }));
    await expect(define("qwzx")).rejects.toBeInstanceOf(DictionaryUnavailable);
  });
});
