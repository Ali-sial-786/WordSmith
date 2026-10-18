import { afterEach, describe, expect, it } from "vitest";
import {
  cleanGloss,
  define,
  DICTIONARY_API_URL,
  DictionaryUnavailable,
  isProperNoun,
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

/** The shape of Wiktionary's REST definitions for a word the Free Dictionary API lacks. */
const TUYERE = {
  en: [
    {
      partOfSpeech: "Noun",
      language: "English",
      definitions: [
        {
          definition:
            '<link rel="mw-deduplicated-inline-style" href="mw-data:TemplateStyles:r1"><style data-mw-deduplicate="TemplateStyles:r1">.mw-parser-output .x{color:red}</style>A <a rel="mw:WikiLink" href="/wiki/nozzle" title="nozzle">nozzle</a> through which air is blown into a <a rel="mw:WikiLink" href="/wiki/furnace" title="furnace">furnace</a> or <span class="x">forge</span>.',
          parsedExamples: [],
        },
        { definition: "" },
      ],
    },
  ],
  fr: [{ partOfSpeech: "Noun", language: "French", definitions: [{ definition: "tuyère" }] }],
};

/** Wiktionary's lowercase page for a name: only a proper noun, with a given-name sense. */
const OMAR = {
  en: [
    {
      partOfSpeech: "Proper noun",
      language: "English",
      definitions: [{ definition: 'A <a href="/wiki/male">male</a> <a href="/wiki/given_name">given name</a> from Arabic.' }],
    },
  ],
};

/** The Free Dictionary API's answer for a name: a capitalised entry. */
const OMAR_API = [{ word: "Omar", meanings: [{ partOfSpeech: "noun", definitions: [{ definition: "A male given name from Arabic." }] }] }];

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
    expect(posLabel("interjection")).toBe("interjection");
    expect(posLabel("Proper noun")).toBe("");
    expect([" Proper  noun", "proper noun"].map(isProperNoun)).toEqual([true, true]);
    expect(["noun", undefined].map(isProperNoun)).toEqual([false, false]);
    expect(posLabel("Romanization")).toBe("");
    expect(posLabel("constructor")).toBe("");
    expect(posLabel(undefined)).toBe("");
  });

  it("strips Wiktionary's HTML", () => {
    expect(stripHtml(TUYERE.en[0]!.definitions[0]!.definition)).toBe("A nozzle through which air is blown into a furnace or forge.");
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

  it("drops given names and surnames, even when they're all there is", () => {
    const names = [
      "A male given name from Arabic.",
      " A surname. ",
      "An English surname, from Old English.",
      "A diminutive of the female given name Abigail.",
      "A unisex given name.",
      "Surnames of Irish origin.",
    ];
    expect(pickSenses(names.map((gloss) => ({ pos: "n", gloss })))).toEqual([]);
    expect(pickSenses([...names, "A name that precedes the family name.", "A person's surname."].map((gloss) => ({ pos: "n", gloss })))).toEqual([
      { pos: "n", gloss: "A name that precedes the family name." },
      { pos: "n", gloss: "A person's surname." },
    ]);
  });

  it("reads only English entries from Wiktionary, and no proper nouns", () => {
    expect(parseWiktionary(TUYERE)).toEqual([
      { pos: "n", gloss: "A nozzle through which air is blown into a furnace or forge." },
      { pos: "n", gloss: "" },
    ]);
    expect(parseWiktionary({ fr: TUYERE.fr })).toEqual([]);
    expect(parseWiktionary(OMAR)).toEqual([]);
    expect(parseWiktionary({ en: [...OMAR.en, ...TUYERE.en] })).toHaveLength(2);
    expect(parseWiktionary({ en: [{ language: "Translingual", partOfSpeech: "Symbol", definitions: [{ definition: "x" }] }] })).toEqual([]);
    for (const junk of [null, [], "x", { en: "x" }, { en: [null, { definitions: "x" }] }]) expect(parseWiktionary(junk)).toEqual([]);
    for (const junk of [null, {}, [null, { meanings: [null, { definitions: [null, { definition: 3 }] }] }]]) {
      expect(parseDictionaryApi(junk)).toEqual([]);
    }
  });

  it("leaves out the Free Dictionary API's capitalised entries and proper nouns", () => {
    expect(parseDictionaryApi(OMAR_API)).toEqual([]);
    const china = [
      { word: "China", meanings: [{ partOfSpeech: "noun", definitions: [{ definition: "A country in East Asia." }] }] },
      {
        word: "china",
        meanings: [
          { partOfSpeech: "proper noun", definitions: [{ definition: "A surname." }] },
          { partOfSpeech: "noun", definitions: [{ definition: "Porcelain, a fine ceramic." }] },
        ],
      },
    ];
    expect(parseDictionaryApi(china)).toEqual([{ pos: "n", gloss: "Porcelain, a fine ceramic." }]);
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

  it("falls back to Wiktionary's lowercase title", async () => {
    const calls = fakeNet({ [`${WIKTIONARY_URL}tuyere`]: TUYERE });
    expect(await define("tuyere")).toEqual({
      word: "tuyere",
      senses: [{ pos: "n", gloss: "A nozzle through which air is blown into a furnace or forge." }],
      source: "wiktionary",
    });
    expect(calls.map((c) => c.url)).toEqual([`${DICTIONARY_API_URL}tuyere`, `${WIKTIONARY_URL}tuyere`]);
    expect(calls.every((c) => c.headers.get("user-agent") === USER_AGENT)).toBe(true);
  });

  it("is null for a name, without asking for a capitalised title", async () => {
    const calls = fakeNet({
      [`${DICTIONARY_API_URL}omar`]: OMAR_API,
      [`${WIKTIONARY_URL}omar`]: OMAR,
      [`${WIKTIONARY_URL}Omar`]: OMAR,
    });
    expect(await define("omar")).toBeNull();
    expect(calls.map((c) => c.url)).toEqual([`${DICTIONARY_API_URL}omar`, `${WIKTIONARY_URL}omar`]);
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
    expect(calls).toHaveLength(2);
  });

  it("still finds the word when one source is down", async () => {
    fakeNet({ [`${WIKTIONARY_URL}tuyere`]: TUYERE }, { [`${DICTIONARY_API_URL}tuyere`]: 503 });
    expect((await define("tuyere"))?.source).toBe("wiktionary");
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
