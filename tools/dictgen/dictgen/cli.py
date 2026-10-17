"""Command line: python3 -m dictgen <command> ..."""

from __future__ import annotations

import argparse
import gzip
import json
import os
import sys

from . import build, fetch, paths


def load_shards(out_dir: str) -> tuple[dict, dict]:
    entries, forms = {}, {}
    for name in sorted(os.listdir(out_dir)):
        if name.endswith(".json.gz"):
            with gzip.open(os.path.join(out_dir, name), "rt", encoding="utf-8") as f:
                doc = json.load(f)
            entries.update(doc["entries"])
            forms.update(doc["forms"])
    return entries, forms


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="dictgen", description="Wordsmith dictionary generator")
    sub = p.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="download the pinned Open English WordNet release (network)")
    f.add_argument("--raw-dir", default=paths.RAW_DIR, help="download directory (default data/raw/)")
    f.add_argument("--force", action="store_true", help="re-download even if present")

    b = sub.add_parser("build", help="write app/assets/dict/ and the licence text")
    b.add_argument("--raw-dir", default=paths.RAW_DIR, help="where `fetch` put the files")
    b.add_argument("--words", default=paths.ACCEPTED, help="word list (default: puzzlegen accepted.txt)")
    b.add_argument("--out", default=paths.DICT_DIR, help="output directory (default app/assets/dict/)")
    b.add_argument("--filter", default=paths.GLOSS_FILTER, help="gloss filter patterns")
    b.add_argument("--licence-out", default=paths.LICENCE_TXT, help="licence text for the app")
    b.add_argument("--report", default=paths.REPORT, help="build report (counts, missing words)")

    s = sub.add_parser("show", help="print the definitions of words from the built files")
    s.add_argument("words", nargs="+")
    s.add_argument("--dir", default=paths.DICT_DIR)

    args = p.parse_args(argv)
    if args.cmd == "fetch":
        return 0 if fetch.fetch(args.raw_dir, force=args.force) else 1
    if args.cmd == "build":
        problems = fetch.verify(args.raw_dir)
        if problems:
            print("\n".join(problems), file=sys.stderr)
            return 1
        build.run(source=os.path.join(args.raw_dir, fetch.XML_NAME), words_path=args.words,
                  out_dir=args.out, filter_path=args.filter, licence_out=args.licence_out,
                  raw_dir=args.raw_dir, report_path=args.report)
        return 0
    if args.cmd == "show":
        entries, forms = load_shards(args.dir)
        for w in args.words:
            w = w.lower()
            lemma = w if w in entries else forms.get(w)
            if lemma is None:
                print(f"{w}: (no definition)")
                continue
            also = f"  (also a form of {forms[w]})" if lemma == w and w in forms else ""
            print((w if lemma == w else f"{w} -> {lemma}") + also)
            for pos, gloss in entries[lemma]:
                print(f"  {pos}  {gloss}")
        return 0
    return 2
