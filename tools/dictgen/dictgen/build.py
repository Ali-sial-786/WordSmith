"""`build`: pick definitions for every accepted word and write app/assets/dict/.

Output (the contract with the app):

    dict/<letter>.json.gz  gzip (mtime 0) of {"v":1,"entries":{...},"forms":{...}},
                           holding the entry lemmas and form words that start with <letter>
    dict/meta.json         {"v":1,"source":...,"license":...,"entries":N,"forms":M}

    entries: lemma -> [[pos, gloss], ...]   1-3 senses, pos in n/v/a/r
    forms:   inflected word -> lemma        the lemma's entry may be in another shard

Same inputs give byte-identical files (sorted keys, no timestamps).
"""

from __future__ import annotations

import gzip
import json
import os
import re
import string
import textwrap
from collections import Counter, defaultdict
from dataclasses import dataclass

from . import fetch, morphy, oewn, paths

FORMAT_VERSION = 1
MAX_SENSES = 3
MAX_GLOSS = 160
ELLIPSIS = "…"
KEY_RE = re.compile(r"^[a-z]+$")
POS_ORDER = morphy.POS_ORDER


# ------------------------------------------------------------------ glosses
def shorten(text: str, limit: int = MAX_GLOSS) -> str:
    """At most `limit` characters; longer text is cut at a word boundary and ends with an ellipsis."""
    if len(text) <= limit:
        return text
    cut = text[: limit - 1]
    if text[limit - 1] != " ":
        space = cut.rfind(" ")
        if space >= limit // 2:
            cut = cut[:space]
    return cut.rstrip(" ,;:-(") + ELLIPSIS


def clean_gloss(text: str, limit: int = MAX_GLOSS) -> str:
    t = " ".join(text.split())
    t = re.sub(r"\s+([;,])", r"\1", t)  # "a ; b" -> "a; b"
    t = re.sub(r";(\s*;)+", ";", t)  # "a;; b" -> "a; b"
    t = t.strip(" ;,")
    return shorten(t, limit)


@dataclass(frozen=True)
class GlossFilter:
    pattern: re.Pattern
    always: bool  # False: drop only when the word keeps another sense ("[unless-only]")


def load_filter(path: str) -> list[GlossFilter]:
    """data/gloss_filter.txt: regexes under "[always]" and "[unless-only]" headers."""
    out, always = [], True
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line in ("[always]", "[unless-only]"):
                always = line == "[always]"
                continue
            out.append(GlossFilter(re.compile(line, re.IGNORECASE), always))
    return out


# ------------------------------------------------------------------ selection
class Dictionary:
    """Sense selection and base-form lookup over a loaded WordNet."""

    def __init__(self, wn: oewn.WordNet, filters: list[GlossFilter]):
        self.defs = wn.definitions
        self.instances = wn.instances
        self.filters = filters
        self.filter_hits: Counter = Counter()  # pattern -> senses dropped
        self.by_key: dict[str, list[oewn.Entry]] = defaultdict(list)
        exceptions = defaultdict(list)  # irregular form -> [(base key, pos)]
        for e in wn.entries:
            key = e.written.lower()
            self.by_key[key].append(e)
            for form in e.forms:
                exceptions[form.lower()].append((key, e.pos))
        for key, es in self.by_key.items():
            es.sort(key=lambda e, k=key: e.written != k)  # "march" before "March" (stable)
        self.exceptions = {f: sorted(c, key=lambda kp: POS_ORDER.index(kp[1]))
                           for f, c in exceptions.items()}
        self._senses: dict[str, list[list[str]]] = {}

    def blocked(self, gloss: str, drop_unless_only: bool) -> str | None:
        """The first filter pattern the gloss matches ([unless-only] ones only if asked)."""
        for f in self.filters:
            if (f.always or drop_unless_only) and f.pattern.search(gloss):
                return f.pattern.pattern
        return None

    def senses(self, key: str) -> list[list[str]]:
        """Up to MAX_SENSES [pos, gloss] pairs for a lemma (case-insensitive), most common first.

        The lowercase spelling's senses come first; capitalised spellings
        (March, Turkey) only fill slots left over, and then not with names
        of individuals. A word with only capitalised spellings (alaska) uses
        those, names of individuals last. See select() for the order.
        Filtered senses are left out; "[unless-only]" ones come back when
        the word would otherwise have no definition.
        """
        if key not in self._senses:
            hits: Counter = Counter()
            out = self._pick(key, True, hits)
            if not out:
                hits = Counter()
                out = self._pick(key, False, hits)
            self.filter_hits.update(hits)
            self._senses[key] = out
        return self._senses[key]

    def _pick(self, key: str, drop_unless_only: bool, hits: Counter) -> list[list[str]]:
        es = self.by_key.get(key, ())
        lower = [e for e in es if e.written == key]
        out = self.select(lower, True, drop_unless_only, hits)
        if len(out) < MAX_SENSES:
            seen = {g for _p, g in out}
            other = [e for e in es if e.written != key]
            extra = [s for s in self.select(other, not lower, drop_unless_only, hits) if s[1] not in seen]
            out += extra[: MAX_SENSES - len(out)]
        return out

    def select(self, entries: list[oewn.Entry], keep_instances: bool, drop_unless_only: bool,
               hits: Counter) -> list[list[str]]:
        """Within a part of speech, WordNet's sense order (names of individuals
        last). Across parts of speech, round robin: the first sense of each,
        then the second of each, ...; the part of speech with more senses goes
        first (ties: n, v, a, r)."""
        ranked: dict[str, list[tuple[bool, int, str]]] = {}
        seen = set()
        for e in entries:
            for sid in e.synsets:
                raw = self.defs.get(sid)
                instance = sid in self.instances
                if not raw or (instance and not keep_instances):
                    continue
                hit = self.blocked(" ".join(raw.split()), drop_unless_only)
                if hit:
                    hits[hit] += 1
                    continue
                gloss = clean_gloss(raw)
                if gloss and gloss not in seen:
                    seen.add(gloss)
                    ranked.setdefault(e.pos, []).append((instance, len(seen), gloss))
        groups = {pos: [g for *_rank, g in sorted(items)] for pos, items in ranked.items()}
        order = sorted(groups, key=lambda p: (-len(groups[p]), POS_ORDER.index(p)))
        out: list[list[str]] = []
        depth = max((len(g) for g in groups.values()), default=0)
        for i in range(depth):
            for p in order:
                if i < len(groups[p]) and len(out) < MAX_SENSES:
                    out.append([p, groups[p][i]])
        return out

    def has_lowercase_lemma(self, key: str, pos: str | None = None) -> bool:
        return any(e.written == key and (pos is None or e.pos == pos) for e in self.by_key.get(key, ()))

    def base_form(self, word: str, lowercase_only: bool = True, strict: bool = True,
                  rule_pos: tuple[str, ...] = POS_ORDER) -> str | None:
        """The lemma `word` inflects: exception list first, then suffix rules (n, v, a).

        strict: the base must be a lemma of the rule's part of speech (WordNet's
        morphy). Otherwise a noun or verb inflection may also land on a lemma
        of another part of speech (guested -> guest n, exotics -> exotic a).
        lowercase_only=False also accepts capitalised lemmas (amanitas ->
        Amanita), but not names of individuals (amens -> Amen, the god) or
        bases under three letters (mes -> ME, Maine). rule_pos limits the
        suffix rules to those parts of speech (exceptions always apply).
        """
        cands = list(self.exceptions.get(word, ()))
        for pos in rule_pos:
            cands += [(b, pos) for b in morphy.rule_bases(word, pos)]
        for base, pos in cands:
            if base == word or not KEY_RE.match(base):
                continue
            if not strict and pos == "a":
                continue  # -er/-est on a non-adjective is more often an agent noun (linker)
            if lowercase_only:
                ok = self.has_lowercase_lemma(base, pos if strict else None)
            else:
                ok = len(base) >= 3 and any(
                    (e.pos == pos or not strict) and any(sid not in self.instances for sid in e.synsets)
                    for e in self.by_key.get(base, ()))
            if ok and self.senses(base):
                return base
        return None

    def plural_only(self, word: str) -> str | None:
        """tong -> tongs, eave -> eaves: the singular of a noun WordNet only has in the plural."""
        base = word + "s"
        return base if self.has_lowercase_lemma(base, "n") and self.senses(base) else None

    def build(self, words: list[str]) -> tuple[dict, dict, list[str]]:
        """(entries, forms, missing) for the given lowercase words.

        A word that is a lemma gets an entry; if it is also an inflection of
        another lemma (forged, found, glasses) it gets a form too, so look
        words up in entries first. A word that only matches a capitalised
        lemma (mars ~ Mars, burns ~ Burns) is linked to a lowercase base form
        instead when morphy finds one (mar, burn). Otherwise an inflected word
        is linked to its base form, trying in turn: morphy with lowercase
        lemmas, the same allowing another part of speech, morphy allowing
        capitalised lemmas, and finally a plural-only noun (tong -> tongs).
        The rest are missing.
        """
        entries: dict[str, list] = {}
        forms: dict[str, str] = {}
        missing: list[str] = []
        for w in words:
            own = self.senses(w)
            if own and self.has_lowercase_lemma(w):
                entries[w] = own
                # Also an inflection of another lemma (forged: own entry "reproduced
                # fraudulently", and a form of forge): link it too. Exception lists
                # and noun/verb rules only; adjective -er rules misfire here (blither).
                base = self.base_form(w, rule_pos=("n", "v"))
                if base is not None:
                    forms[w] = base
                    entries.setdefault(base, self.senses(base))
                continue
            base = self.base_form(w, lowercase_only=True)
            if base is None and not own:
                base = (self.base_form(w, lowercase_only=True, strict=False)
                        or self.base_form(w, lowercase_only=False)
                        or self.plural_only(w))
            if base is not None:
                forms[w] = base
                entries.setdefault(base, self.senses(base))
            elif own:
                entries[w] = own
            else:
                missing.append(w)
        return entries, forms, missing


# ------------------------------------------------------------------ output
def shard_files(entries: dict, forms: dict) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    for letter in string.ascii_lowercase:
        doc = {
            "v": FORMAT_VERSION,
            "entries": {k: entries[k] for k in sorted(entries) if k[0] == letter},
            "forms": {k: forms[k] for k in sorted(forms) if k[0] == letter},
        }
        data = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        files[f"{letter}.json.gz"] = gzip.compress(data, compresslevel=9, mtime=0)
    meta = {"v": FORMAT_VERSION, "source": fetch.SOURCE_NAME, "license": fetch.LICENSE_NAME,
            "entries": len(entries), "forms": len(forms)}
    files["meta.json"] = (json.dumps(meta, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    return files


def write_files(out_dir: str, files: dict[str, bytes]) -> None:
    os.makedirs(out_dir, exist_ok=True)
    for name in sorted(os.listdir(out_dir)):
        if name.endswith(".json.gz") and name not in files:  # e.g. an old lexicon.json.gz
            os.remove(os.path.join(out_dir, name))
    for name, data in files.items():
        path = os.path.join(out_dir, name)
        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)


def licence_text(raw_dir: str) -> str:
    """The licence file shipped in the app: attribution, then OEWN's licence files."""
    with open(os.path.join(raw_dir, "LICENSE.md"), encoding="utf-8") as f:
        oewn_licence = f.read().strip("\n")
    with open(os.path.join(raw_dir, "WNDB_License.txt"), encoding="utf-8") as f:
        # The upstream file carries editor line numbers ("  7 Permission to use ...").
        wndb = "\n".join(re.sub(r"^\s*\d+ ?", "", line).rstrip() for line in f.read().splitlines())
    paragraphs = [
        f"{fetch.SOURCE_NAME}\n{fetch.HOME_URL}",
        f"The word definitions in Wordsmith (assets/dict/) are adapted from {fetch.SOURCE_NAME}, "
        "Copyright (c) 2019-present, The Open English WordNet Team, licensed under the Creative "
        "Commons Attribution 4.0 International License (https://creativecommons.org/licenses/by/4.0/). "
        "Open English WordNet is derived from Princeton WordNet 3.1, WordNet 3.1 Copyright 2011 by "
        "Princeton University. All rights reserved.",
        "Changes made for Wordsmith: at most three definitions per word, shortened to 160 characters, "
        "example sentences and a few offensive senses left out, and inflected words linked to their "
        "base word.",
        "The upstream licence files follow (WNDB_License.txt without its line numbers).",
    ]
    head = "\n\n".join(p if "\n" in p else textwrap.fill(p, 72) for p in paragraphs)
    sep = "=" * 71
    return (f"{head}\n\n{sep}\nLICENSE.md\n{sep}\n\n{oewn_licence}\n\n"
            f"{sep}\nWNDB_License.txt\n{sep}\n\n{wndb.strip()}\n")


def read_levels(path: str) -> dict[str, int]:
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return {w: int(lv) for w, lv in (line.split("\t") for line in f if "\t" in line)}


def read_words(path: str) -> list[str]:
    with open(path, encoding="utf-8") as f:
        return sorted({w.strip().lower() for w in f if w.strip() and not w.startswith("#")})


def run(source: str, words_path: str, out_dir: str, filter_path: str, licence_out: str | None,
        raw_dir: str | None, report_path: str | None, log=print) -> dict:
    words = read_words(words_path)
    wn = oewn.load(source)
    d = Dictionary(wn, load_filter(filter_path))
    entries, forms, missing = d.build(words)
    files = shard_files(entries, forms)
    write_files(out_dir, files)
    if licence_out and raw_dir:
        os.makedirs(os.path.dirname(licence_out), exist_ok=True)
        with open(licence_out, "w", encoding="utf-8") as f:
            f.write(licence_text(raw_dir))
    accepted = set(words)
    sizes = {name: len(data) for name, data in files.items()}
    stats = {
        "source": fetch.SOURCE_NAME,
        "source_file": os.path.basename(source),
        "source_sha256": fetch.sha256_file(source),
        "words": len(words),
        "defined_directly": sum(1 for w in words if w in entries),
        "defined_via_forms": sum(1 for w in words if w in forms and w not in entries),
        "entry_and_form": sum(1 for w in words if w in forms and w in entries),
        "missing": len(missing),
        "entries": len(entries),
        "entries_not_in_word_list": sum(1 for k in entries if k not in accepted),
        "forms": len(forms),
        "senses": sum(len(v) for v in entries.values()),
        "bytes_total": sum(sizes.values()),
        "bytes": sizes,
        "filtered_senses": dict(sorted(d.filter_hits.items())),
    }
    levels = read_levels(paths.SCOWL_LEVELS)
    if levels:
        # SCOWL size level: 10 = most common words ... 70; 99 = not in SCOWL (ENABLE only).
        tiers = (10, 20, 35, 50, 70, 99)
        tier = {w: next(t for t in tiers if levels.get(w, 99) <= t) for w in words}
        stats["missing_by_scowl_level"] = {
            str(t): f"{sum(1 for w in missing if tier[w] == t)} of {sum(1 for w in words if tier[w] == t)}"
            for t in tiers}
        stats["missing_common_words"] = [w for w in missing if tier[w] <= 35]
    if report_path:
        os.makedirs(os.path.dirname(report_path), exist_ok=True)
        with open(report_path, "w", encoding="utf-8") as f:
            json.dump(stats, f, ensure_ascii=False, indent=1, sort_keys=False)
            f.write("\n")
    n = stats["words"]
    log(f"{n} words: {stats['defined_directly']} defined directly "
        f"({100 * stats['defined_directly'] / n:.1f}%), {stats['defined_via_forms']} via forms "
        f"({100 * stats['defined_via_forms'] / n:.1f}%), {stats['missing']} missing "
        f"({100 * stats['missing'] / n:.1f}%)")
    log(f"{stats['entries']} entries ({stats['entries_not_in_word_list']} base lemmas not in the word list), "
        f"{stats['forms']} forms ({stats['entry_and_form']} words have both), {stats['senses']} senses, "
        f"{sum(d.filter_hits.values())} senses filtered")
    log(f"wrote {len(files)} files to {out_dir}: {stats['bytes_total']:,} bytes "
        f"({stats['bytes_total'] / 1e6:.2f} MB)")
    return stats

