"""`fetch`: download the raw word lists and build the committed derived lists.

Raw downloads go to data/raw/ (git-ignored). The derived files written to
data/ are small, committed, and are all that generation, validation and the
tests need, so none of those touch the network.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
import tarfile
import urllib.request

from . import paths

SCOWL_VERSION = "2020.12.07"
SCOWL_MAX_LEVEL = 70  # levels 80/95 are not used (obscure words; UKACD terms)

# name -> (url, sha256 of the file as fetched on 2026-10-17)
SOURCES = {
    "enable1.txt": (
        "https://raw.githubusercontent.com/dolph/dictionary/master/enable1.txt",
        "3f16130220645692ed49c7134e24a18504c2ca55b3c012f7290e3e77c63b1a89",
    ),
    "ldnoobw_en.txt": (
        "https://raw.githubusercontent.com/LDNOOBW/"
        "List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words/master/en",
        "af851ecef1d5f212caba17339b12ac39cc2fef7d78c74876f67237644fcee8bd",
    ),
    "ldnoobw_LICENSE.txt": (
        "https://raw.githubusercontent.com/LDNOOBW/"
        "List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words/master/LICENSE",
        "55bfbc1759943f7d19acfc68e35644b7fbe10cd8d39ab3551ce5ecff5dda9979",
    ),
    f"scowl-{SCOWL_VERSION}.tar.gz": (
        f"https://downloads.sourceforge.net/wordlist/scowl-{SCOWL_VERSION}.tar.gz",
        "5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc",
    ),
}

WORD_RE = re.compile(r"^[a-z]{3,8}$")
SCOWL_MEMBER_RE = re.compile(
    rf"^scowl-{re.escape(SCOWL_VERSION)}/final/(english|american)-words\.(\d+)$"
)

# Names (see build_names): an accepted word is a name when SCOWL lists it
# capitalised (a proper name, or another word written with a capital:
# places, nationalities, brands) at level <= NAME_LEVEL, and no SCOWL word
# list for any spelling region has it in lowercase at level <= COMMON_LEVEL.
# So BOSTON, ABIGAIL and BERLIN go (their lowercase senses are level 70+ or
# unlisted), while CHINA, BILL, AMBER, AMAZON and GOOGLE stay. Levels 55 and
# 60 are mostly real words (ANGELICA, CORVETTE, GESTALT), so they stay and
# the few names among them are in names_extra.txt.
NAME_LEVEL = 60
COMMON_LEVEL = 60
SCOWL_NAMES_RE = re.compile(
    rf"^scowl-{re.escape(SCOWL_VERSION)}/final/(english|american)-(proper-names|upper)\.(\d+)$"
)
# Lowercase words in every spelling region, so British spellings count as
# real words too (GREY, ARMOUR, TYRE, SABRE are not in the American lists).
SCOWL_REGION_WORDS_RE = re.compile(
    rf"^scowl-{re.escape(SCOWL_VERSION)}/final/"
    r"(english|american|british|british_z|canadian|australian)-words\.(\d+)$"
)
CAPITALISED_RE = re.compile(r"^[A-Z][a-z]+$")


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: str) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": "wordsmith-puzzlegen/1"})
    tmp = dest + ".part"
    with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "wb") as out:
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            out.write(chunk)
    os.replace(tmp, dest)


def fetch_raw(force: bool = False, log=print) -> bool:
    """Download every source into data/raw/. Returns False on checksum drift."""
    os.makedirs(paths.RAW_DIR, exist_ok=True)
    ok = True
    for name, (url, expected) in SOURCES.items():
        dest = os.path.join(paths.RAW_DIR, name)
        if force or not os.path.exists(dest):
            log(f"downloading {url}")
            download(url, dest)
        digest = sha256_file(dest)
        if digest != expected:
            ok = False
            log(f"WARNING: {name} sha256 {digest} differs from the recorded {expected}")
        else:
            log(f"ok  {name}  sha256 {digest[:16]}...")
    return ok


# ---------------------------------------------------------------- building


def read_enable(path: str) -> set[str]:
    with open(path, encoding="ascii") as f:
        return {w for w in (line.strip().lower() for line in f) if WORD_RE.match(w)}


def read_scowl(path: str) -> tuple[dict[str, int], str]:
    """Return ({word: min size level <= SCOWL_MAX_LEVEL}, Copyright text)."""
    levels: dict[str, int] = {}
    copyright_text = ""
    with tarfile.open(path, "r:gz") as tar:
        for member in tar.getmembers():
            if member.name == f"scowl-{SCOWL_VERSION}/Copyright":
                copyright_text = tar.extractfile(member).read().decode("iso-8859-1")
                continue
            m = SCOWL_MEMBER_RE.match(member.name)
            if not m or not member.isfile():
                continue
            level = int(m.group(2))
            if level > SCOWL_MAX_LEVEL:
                continue
            text = tar.extractfile(member).read().decode("iso-8859-1")
            for line in text.splitlines():
                w = line.strip()
                # Lowercase a-z only: drops possessives, accents, proper names.
                if WORD_RE.match(w):
                    if w not in levels or level < levels[w]:
                        levels[w] = level
    if not copyright_text:
        raise RuntimeError("SCOWL Copyright file not found in tarball")
    return levels, copyright_text


def read_scowl_names(path: str) -> tuple[dict[str, int], set[str]]:
    """Return ({name: min level <= NAME_LEVEL}, common lowercase words).

    Names are the capitalised entries (`Boston`, not `IBM`, `McCoy` or
    `Abe's`) of the proper-names and upper lists, lowercased. Common words
    are lowercase entries at level <= COMMON_LEVEL in any region's list.
    """
    names: dict[str, int] = {}
    common: set[str] = set()
    with tarfile.open(path, "r:gz") as tar:
        for member in tar.getmembers():
            if not member.isfile():
                continue
            m = SCOWL_NAMES_RE.match(member.name)
            if m and int(m.group(3)) <= NAME_LEVEL:
                level = int(m.group(3))
                text = tar.extractfile(member).read().decode("iso-8859-1")
                for line in text.splitlines():
                    w = line.strip()
                    if CAPITALISED_RE.match(w):
                        w = w.lower()
                        names[w] = min(level, names.get(w, level))
                continue
            m = SCOWL_REGION_WORDS_RE.match(member.name)
            if m and int(m.group(2)) <= COMMON_LEVEL:
                text = tar.extractfile(member).read().decode("iso-8859-1")
                common.update(w for w in (line.strip() for line in text.splitlines())
                              if WORD_RE.match(w))
    return names, common


def read_ldnoobw(path: str) -> set[str]:
    """Single lowercase a-z words from the LDNOOBW list (phrases are skipped)."""
    out = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            w = line.strip().lower()
            if re.fullmatch(r"[a-z]+", w):
                out.add(w)
    return out


def read_extra(path: str) -> tuple[set[str], set[str]]:
    """Return (words, substrings) from blocklist_extra.txt (`*stem*` = substring)."""
    words, subs = set(), set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            for tok in line.split("#", 1)[0].lower().split():
                if re.fullmatch(r"\*[a-z]+\*", tok):
                    subs.add(tok[1:-1])
                elif re.fullmatch(r"[a-z]+", tok):
                    words.add(tok)
                else:
                    raise ValueError(f"{path}: bad entry {tok!r}")
    return words, subs


def inflections(word: str) -> set[str]:
    """Obvious plurals / verb forms of a blocked stem (kept deliberately simple)."""
    forms = {word, word + "s", word + "es", word + "ed", word + "ing"}
    if word.endswith("e"):
        forms |= {word + "d", word[:-1] + "ing"}
    if word.endswith("y") and len(word) > 3:
        forms |= {word[:-1] + "ies", word[:-1] + "ied"}
    return forms


def build_blocklist(ldnoobw: set[str], extra: set[str], substrings: set[str],
                    vocabulary: set[str]) -> set[str]:
    blocked: set[str] = set()
    for w in sorted(ldnoobw | extra):
        blocked |= inflections(w)
    for w in vocabulary:
        if any(s in w for s in substrings):
            blocked.add(w)
    return {w for w in blocked if WORD_RE.match(w)}


def read_word_list(path: str) -> set[str]:
    """Lowercase a-z words from a hand-kept list ('#' starts a comment)."""
    out = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            for tok in line.split("#", 1)[0].lower().split():
                if not re.fullmatch(r"[a-z]+", tok):
                    raise ValueError(f"{path}: bad entry {tok!r}")
                out.add(tok)
    return out


def build_names(words: set[str], names: dict[str, int], common: set[str],
                keep: set[str], extra: set[str]) -> set[str]:
    """The words in `words` that count as names, not real words.

    A word is a name if SCOWL has it capitalised (`names`) and not as a
    common lowercase word, or if it is in `extra`. Words in `keep` (and their
    forms) stay. A form of a common word (EASTS, CONCORDS) is not a name. A
    form of a name (BERLINS, ABIGAILS) is, unless it is common in its own
    right (DEE, but DEED) or also a form of another word (LASED is LASE + D,
    not LAS + ED).
    """
    kept = set(keep)
    for w in keep:
        kept |= word_forms(w)
    found = {w for w in words if w in names and w not in common}
    found = {w for w in found if not any(b in common and b in words for b in _bases(w))}
    found |= extra & words
    out = set(found)
    for w in found:
        for f in word_forms(w):
            if (f in words and f not in common
                    and not any(b != w and b in words and b not in found for b in _bases(f))):
                out.add(f)
    return {w for w in out if w not in kept or w in extra}


def word_forms(word: str) -> set[str]:
    """Regular plural and verb forms of `word` (BOSTONS, BURKED, CHEVIES)."""
    forms = {word + "s"}
    if re.search(r"(s|x|z|ch|sh|o)$", word):
        forms.add(word + "es")
    if re.search(r"[^aeiou]y$", word):
        forms |= {word[:-1] + "ies", word[:-1] + "ied"}
    if word.endswith("e"):
        forms |= {word + "d", word[:-1] + "ing"}
    else:
        forms |= {word + "ed", word + "ing"}
    if re.search(r"[^aeiou][aeiou][bdgklmnprt]$", word):
        forms |= {word + word[-1] + "ed", word + word[-1] + "ing"}
    return forms


def _bases(word: str) -> set[str]:
    """The words that `word` is one of the `word_forms` of."""
    cands = {word[:-k] for k in (1, 2, 3) if len(word) > k + 2}
    cands |= {word[:-3] + "e", word[:-3] + "y", word[:-4]}
    return {b for b in cands if b and word in word_forms(b)}


def write_lines(path: str, lines) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for line in lines:
            f.write(line + "\n")


def build(log=print) -> dict:
    raw = paths.RAW_DIR
    enable = read_enable(os.path.join(raw, "enable1.txt"))
    scowl, scowl_copyright = read_scowl(os.path.join(raw, f"scowl-{SCOWL_VERSION}.tar.gz"))
    ldnoobw = read_ldnoobw(os.path.join(raw, "ldnoobw_en.txt"))
    extra, substrings = read_extra(paths.BLOCKLIST_EXTRA)
    vocabulary = enable | set(scowl)
    blocked = build_blocklist(ldnoobw, extra, substrings, vocabulary)

    scowl_names, common = read_scowl_names(os.path.join(raw, f"scowl-{SCOWL_VERSION}.tar.gz"))
    names_keep = read_word_list(paths.NAMES_KEEP)
    names_extra = read_word_list(paths.NAMES_EXTRA)
    names = build_names(vocabulary - blocked, scowl_names, common, names_keep, names_extra)
    unused = sorted(names_keep - build_names(vocabulary - blocked, scowl_names, common,
                                             set(), names_extra))
    if unused:
        log(f"names_keep.txt entries that are not names anyway: {' '.join(unused)}")
    missing = sorted(names_extra - vocabulary)
    if missing:
        log(f"names_extra.txt entries that are not words anyway: {' '.join(missing)}")

    accepted = vocabulary - blocked - names
    levels = {w: lv for w, lv in scowl.items() if w in accepted}
    # Answers must be real dictionary words, so we record which accepted
    # words are SCOWL-only (not in ENABLE): "gonna", "email", "dunno", ...
    scowl_only = sorted(w for w in levels if w not in enable)

    write_lines(paths.BLOCKLIST, sorted(blocked))
    write_lines(paths.NAMES_EXCLUDE, sorted(names))
    write_lines(paths.ACCEPTED, sorted(accepted))
    write_lines(paths.SCOWL_LEVELS, (f"{w}\t{levels[w]}" for w in sorted(levels)))
    write_lines(paths.SCOWL_ONLY, scowl_only)
    write_licenses(scowl_copyright)

    summary = {
        "enable_3_8": len(enable),
        "scowl_3_8_le70": len(scowl),
        "ldnoobw_single_words": len(ldnoobw),
        "blocklist_extra": len(extra) + len(substrings),
        "blocklist_total": len(blocked),
        "names_keep": len(names_keep),
        "names_extra": len(names_extra),
        "names_excluded": len(names),
        "accepted": len(accepted),
        "scowl_levels": len(levels),
        "scowl_only": len(scowl_only),
    }
    for k, v in summary.items():
        log(f"{k:>22}: {v}")
    return summary


LICENSES_HEADER = """\
# Word list sources and licences

This file is written by `python3 -m puzzlegen fetch`; edit the template in
`puzzlegen/fetch.py`, not this file.

The derived files in this directory are built from the sources below by
`python3 -m puzzlegen fetch` (downloads go to `data/raw/`, which is not
committed). Only 3-8 letter, lowercase a-z words are kept.

| Source | Version / URL | Licence | Used for |
|---|---|---|---|
| ENABLE (`enable1.txt`) | https://raw.githubusercontent.com/dolph/dictionary/master/enable1.txt | Public domain | Accepted (bonus) words; grid answers must also be ENABLE words |
| SCOWL | {scowl_version}, https://downloads.sourceforge.net/wordlist/scowl-{scowl_version}.tar.gz | SCOWL copyright notice (below): permissive, keep the notice | Commonness levels for answers, and accepted words: `final/english-words.*` and `final/american-words.*`, levels 10-{scowl_max}. Names: the English and American `proper-names.*` and `upper.*` lists (levels <= {name_level}) against every spelling region's `*-words.*` (levels <= {common_level}) |
| LDNOOBW English list | https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words (file `en`) | CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/), by the LDNOOBW contributors (Shutterstock) | Blocklist (single words only; phrases skipped) |
| `blocklist_extra.txt`, `answer_exclude.txt`, `names_keep.txt`, `names_extra.txt` | written for Wordsmith | same as this repo | Extra blocked words; words kept out of grids; real words kept and extra names dropped by the names list |

Derived files:

- `accepted.txt`: ENABLE + SCOWL (levels <= {scowl_max}), minus `blocklist.txt` and
  `names_exclude.txt`. Every bonus word comes from here.
- `names_exclude.txt`: words that are names, places, brands or nationalities
  rather than real words (`boston`, `abigail`, `berlin`). SCOWL lists them
  capitalised at level <= {name_level}, and in lowercase at no level <= {common_level} in
  any spelling region; plus `names_extra.txt`, minus `names_keep.txt`, with
  their plural and verb forms.
- `scowl_levels.tsv`: `word<TAB>smallest SCOWL size level` for accepted
  SCOWL words (10 = most common ... {scowl_max}).
- `scowl_only.txt`: accepted SCOWL words that are not in ENABLE (`gonna`,
  `email`, ...). They can be bonus words but never grid answers.
- `blocklist.txt`: a modified version of the LDNOOBW English list, under
  CC BY 4.0: its single words plus `blocklist_extra.txt`, with simple
  inflections (-s, -es, -ies, -d, -ed, -ing) added, plus every ENABLE/SCOWL
  word containing one of the `*stem*` entries in `blocklist_extra.txt`.

The generated puzzles (`app/assets/campaign/campaign.json`,
`server/data/mp_bank.json`) contain words from ENABLE and SCOWL, so the
SCOWL notice below should also appear in the app's licences screen.

## SCOWL copyright notice (verbatim `Copyright` file from scowl-{scowl_version})

```
"""

LICENSES_FOOTER = """\
```
"""


def write_licenses(scowl_copyright: str) -> None:
    text = LICENSES_HEADER.format(scowl_version=SCOWL_VERSION, scowl_max=SCOWL_MAX_LEVEL,
                                  name_level=NAME_LEVEL, common_level=COMMON_LEVEL)
    text += scowl_copyright.rstrip("\n") + "\n" + LICENSES_FOOTER
    with open(paths.LICENSES, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def main(args) -> int:
    ok = fetch_raw(force=args.force)
    if not ok and not args.allow_changed:
        print("source checksums changed; re-run with --allow-changed to build anyway",
              file=sys.stderr)
        return 2
    build()
    return 0
