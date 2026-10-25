"""ASCII rendering (`show`) and summaries (`stats`)."""

from __future__ import annotations

import json
import os
from collections import defaultdict

from . import paths
from .rules import grid_cells
from .tiers import HEAT_NAMES


def render(p: dict, show_bonus: bool = True) -> str:
    cells, _ = grid_cells(p["words"])
    cols, rows = p["cols"], p["rows"]
    head = f"{p['id'] or '(new)'}  heat {p['heat']} {HEAT_NAMES.get(p['heat'], '?')}"
    if "size" in p:
        head += f"  size {p['size']}"
    head += f"  {cols}x{rows}  letters: {' '.join(p['letters'])}"
    lines = [head]
    border = "+" + "-" * (cols * 2 + 1) + "+"
    lines.append(border)
    for y in range(rows):
        row = " ".join(cells.get((x, y), ".") for x in range(cols))
        lines.append("| " + row + " |")
    lines.append(border)
    ws = sorted((pw["w"] for pw in p["words"]), key=lambda w: (len(w), w))
    lines.append(f"words ({len(ws)}): " + " ".join(ws))
    if show_bonus:
        lines.append(f"bonus ({len(p['bonus'])}): " + " ".join(p["bonus"]))
    return "\n".join(lines)


def load_file(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def show(path: str, ids: list[str]) -> int:
    data = load_file(path)
    by_id = {p["id"]: p for p in data["puzzles"]}
    rc = 0
    for pid in ids:
        if pid not in by_id:
            print(f"no puzzle {pid} in {path}")
            rc = 1
            continue
        print(render(by_id[pid]))
        print()
    return rc


def _avg(xs) -> str:
    return f"{sum(xs) / len(xs):.1f}" if xs else "-"


def _summary_rows(groups):
    out = []
    for key, ps in groups:
        nw = [len(p["words"]) for p in ps]
        nl = [len(p["letters"]) for p in ps]
        area = [p["cols"] * p["rows"] for p in ps]
        nb = [len(p["bonus"]) for p in ps]
        cols = [p["cols"] for p in ps]
        rows = [p["rows"] for p in ps]
        out.append((key, len(ps), f"{min(nw)}-{max(nw)}", _avg(nw), _avg(nl),
                    f"{_avg(cols)}x{_avg(rows)}", f"{max(cols)}x{max(rows)}", _avg(area), _avg(nb)))
    return out


def _print_table(header, rows):
    widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
    fmt = "  ".join("{:<%d}" % w for w in widths)
    print(fmt.format(*header))
    for r in rows:
        print(fmt.format(*[str(c) for c in r]))


def report_path(path: str) -> str:
    """Where the generation report for an output file lives.

    The committed outputs keep theirs in reports/; any other output gets one
    beside it (so scratch runs never touch reports/).
    """
    for canonical in (paths.CAMPAIGN_JSON, paths.MP_BANK_JSON):
        if os.path.abspath(path) == os.path.abspath(canonical):
            base = os.path.splitext(os.path.basename(canonical))[0]
            return os.path.join(paths.REPORTS_DIR, base + ".gen.json")
    return os.path.splitext(os.path.abspath(path))[0] + ".gen.json"


def print_quality(puzzles: list[dict], data: dict) -> None:
    """Answer-quality metrics (metrics.py) for the whole file, per chapter and per heat."""
    from . import metrics
    from .words import load
    lex = load()
    rows = [metrics.summary_row("all", puzzles, lex)]
    if "chapters" in data:
        for ch in data["chapters"]:
            rows.append(metrics.summary_row(
                ch["name"], puzzles[ch["first"] - 1: ch["first"] - 1 + ch["count"]], lex))
    by_heat = defaultdict(list)
    for p in puzzles:
        by_heat[p["heat"]].append(p)
    rows += [metrics.summary_row(f"heat {h} {HEAT_NAMES[h]}", by_heat[h], lex)
             for h in sorted(by_heat)]
    by_size = defaultdict(list)
    for p in puzzles:
        if "size" in p:
            by_size[(p["heat"], p["size"])].append(p)
    rows += [metrics.summary_row(f"heat {h} size {s}", by_size[(h, s)], lex)
             for (h, s) in sorted(by_size)]
    print("\nanswer quality (metrics.py: left4 / left3 / left2.5 = good words (quality 4.0+, "
          "3.0+, 2.5+) that could be grid answers left in the bonus list, per puzzle, max4 / "
          "max3 the most in one; inv = bonus words clearly better than the worst grid word, "
          "missed = very common words left out, infl = inflected grid words):")
    _print_table(metrics.SUMMARY_HEADER, rows)


def stats(path: str) -> int:
    data = load_file(path)
    puzzles = data["puzzles"]
    header = ("group", "n", "words", "avg words", "avg letters", "avg grid", "max grid",
              "avg area", "avg bonus")
    if "chapters" in data:
        groups = []
        for ch in data["chapters"]:
            ps = puzzles[ch["first"] - 1: ch["first"] - 1 + ch["count"]]
            groups.append((ch["name"], ps))
        print(f"{path}: {len(puzzles)} campaign puzzles\n")
        _print_table(header, _summary_rows(groups))
        print()
    by_heat = defaultdict(list)
    for p in puzzles:
        by_heat[p["heat"]].append(p)
    groups = [(f"heat {h} {HEAT_NAMES[h]}", by_heat[h]) for h in sorted(by_heat)]
    _print_table(header, _summary_rows(groups))
    if any("size" in p for p in puzzles):
        print()
        by_hs = defaultdict(list)
        for p in puzzles:
            by_hs[(p["heat"], p.get("size", 1))].append(p)
        groups = [(f"heat {h} size {s}", by_hs[(h, s)]) for (h, s) in sorted(by_hs)]
        _print_table(header, _summary_rows(groups))
    print_quality(puzzles, data)
    rep = report_path(path)
    if os.path.exists(rep):
        gen = load_file(rep)
        print(f"\ngeneration report ({os.path.relpath(rep)}):")
        print(f"  seed {gen.get('seed')}")
        for name, g in gen.get("groups", {}).items():
            rej = g.get("rejections", {})
            rej_s = ", ".join(f"{k}: {v}" for k, v in sorted(rej.items())) or "none"
            extra = ""
            if "difficulty" in g:
                extra = f" difficulty {g['difficulty'][0]}-{g['difficulty'][1]}"
            print(f"  {name:<22} rejections: {rej_s}{extra}")
        for note in gen.get("notes", []):
            print(f"  note: {note}")
    return 0
