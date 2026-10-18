"""Command line: python3 -m puzzlegen <command> ..."""

from __future__ import annotations

import argparse

from . import paths


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="puzzlegen", description="Wordsmith puzzle generator")
    sub = p.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="download word lists and rebuild data/*.txt")
    f.add_argument("--force", action="store_true", help="re-download even if present")
    f.add_argument("--allow-changed", action="store_true",
                   help="build even if a source's checksum changed")

    c = sub.add_parser("campaign", help="generate the solo campaign")
    c.add_argument("--seed", type=int, default=1)
    c.add_argument("--out", default=paths.CAMPAIGN_JSON)

    m = sub.add_parser("mp", help="generate the multiplayer bank")
    m.add_argument("--seed", type=int, default=2)
    m.add_argument("--per", type=int, default=40, help="puzzles per heat and size")
    m.add_argument("--out", default=paths.MP_BANK_JSON)
    m.add_argument("--campaign", default=paths.CAMPAIGN_JSON,
                   help="campaign file whose letter sets must not be reused")

    g = sub.add_parser("grow", help="add a part of new puzzles to the multiplayer bank")
    g.add_argument("--seed", type=int, required=True, help="a seed no earlier part used")
    g.add_argument("--bank", default=paths.MP_BANK_JSON, help="the bank to grow")
    g.add_argument("--out", default=paths.MP_BANK_JSON)
    g.add_argument("--campaign", default=paths.CAMPAIGN_JSON,
                   help="campaign file whose letter sets must not be reused")

    r = sub.add_parser("refresh", help="recompute the bonus lists of a campaign file or bank "
                                       "after the word lists change (grids stay as they are)")
    r.add_argument("file")

    v = sub.add_parser("validate", help="check a campaign file or multiplayer bank")
    v.add_argument("file")
    v.add_argument("--campaign", default=None,
                   help="(bank only) also check no letter set repeats this campaign")
    v.add_argument("--per", type=int, default=None,
                   help="(bank without parts only) expected puzzles per heat and size")

    s = sub.add_parser("show", help="ASCII render of puzzles")
    s.add_argument("file")
    s.add_argument("ids", nargs="+", help="puzzle ids, e.g. c-0001 m-00042")

    st = sub.add_parser("stats", help="summary per chapter / heat")
    st.add_argument("file")

    args = p.parse_args(argv)
    if args.cmd == "fetch":
        from . import fetch
        return fetch.main(args)
    if args.cmd == "campaign":
        from . import campaign
        return campaign.main_campaign(args)
    if args.cmd == "mp":
        from . import campaign
        return campaign.main_mp(args)
    if args.cmd == "grow":
        from . import campaign
        return campaign.main_grow(args)
    if args.cmd == "refresh":
        from . import campaign
        return campaign.main_refresh(args)
    if args.cmd == "validate":
        from . import validate
        return validate.main(args)
    if args.cmd == "show":
        from . import render
        return render.show(args.file, args.ids)
    if args.cmd == "stats":
        from . import render
        return render.stats(args.file)
    return 1
