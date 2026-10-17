"""Checks for every rule in shared/puzzle-format.md, one puzzle at a time.

This is deliberately written independently of layout.py: it rebuilds the grid
from the JSON and checks it from scratch.
"""

from __future__ import annotations

import re
from collections import Counter

from .words import Lexicon, signature

UPPER_RE = re.compile(r"^[A-Z]+$")
MAX_SIDE = 10


def _formable(word: str, have: Counter) -> bool:
    need = Counter(word)
    return all(have[c] >= n for c, n in need.items())


def grid_cells(words) -> tuple[dict, list[str]]:
    """Rebuild {(x, y): letter} from placed words; report letter clashes."""
    cells: dict[tuple[int, int], str] = {}
    errors = []
    for pw in words:
        w, x, y, d = pw["w"], pw["x"], pw["y"], pw["d"]
        dx, dy = (1, 0) if d == "a" else (0, 1)
        for k, ch in enumerate(w):
            c = (x + k * dx, y + k * dy)
            if c in cells and cells[c] != ch:
                errors.append(
                    f"rule 4: {w} puts {ch} at {c} where another word has {cells[c]}")
            cells.setdefault(c, ch)
    return cells, errors


def runs(cells: dict, cols: int, rows: int):
    """Maximal runs of >= 2 letters: [(x, y, 'a'|'d', text)]."""
    out = []
    for y in range(rows):
        x = 0
        while x < cols:
            if (x, y) in cells:
                x0 = x
                while (x, y) in cells:
                    x += 1
                if x - x0 >= 2:
                    out.append((x0, y, "a", "".join(cells[(i, y)] for i in range(x0, x))))
            else:
                x += 1
    for x in range(cols):
        y = 0
        while y < rows:
            if (x, y) in cells:
                y0 = y
                while (x, y) in cells:
                    y += 1
                if y - y0 >= 2:
                    out.append((x, y0, "d", "".join(cells[(x, i)] for i in range(y0, y))))
            else:
                y += 1
    return out


def check_layout(words, cols: int, rows: int) -> list[str]:
    """Rules 4, 5 and 6 plus the bounding-box rules for a list of placed words."""
    errors = []
    if not isinstance(cols, int) or not isinstance(rows, int):
        return ["cols/rows must be integers"]
    if not (1 <= cols <= MAX_SIDE and 1 <= rows <= MAX_SIDE):
        errors.append(f"grid {cols}x{rows} exceeds {MAX_SIDE}x{MAX_SIDE}")
    for pw in words:
        w, x, y, d = pw["w"], pw["x"], pw["y"], pw["d"]
        end_x = x + (len(w) - 1 if d == "a" else 0)
        end_y = y + (len(w) - 1 if d == "d" else 0)
        if x < 0 or y < 0 or end_x >= cols or end_y >= rows:
            errors.append(f"{w} at ({x},{y},{d}) runs outside the {cols}x{rows} grid")
    if errors:
        return errors
    cells, clash = grid_cells(words)
    errors += clash
    # Tight crop: every row and column holds a letter.
    used_cols = {x for (x, _) in cells}
    used_rows = {y for (_, y) in cells}
    for x in range(cols):
        if x not in used_cols:
            errors.append(f"column {x} is empty (grid not cropped)")
    for y in range(rows):
        if y not in used_rows:
            errors.append(f"row {y} is empty (grid not cropped)")
    # Rule 5: the runs are exactly the placed words.
    placed = Counter((pw["x"], pw["y"], pw["d"], pw["w"]) for pw in words)
    found = Counter(runs(cells, cols, rows))
    for key in placed:
        if placed[key] > 1:
            errors.append(f"rule 5: {key[3]} is placed twice at the same spot")
    for key in found:
        if key not in placed:
            x, y, d, text = key
            errors.append(
                f"rule 5: stray run {text} at ({x},{y},{d}) is not exactly one grid word")
    for key in placed:
        if key not in found:
            x, y, d, w = key
            errors.append(
                f"rule 5: {w} at ({x},{y},{d}) is not a maximal run "
                "(touches another letter before/after, or overlaps a word)")
    # Rule 6: connected through crossings.
    if words:
        owner: dict[tuple[int, int], list[int]] = {}
        for i, pw in enumerate(words):
            dx, dy = (1, 0) if pw["d"] == "a" else (0, 1)
            for k in range(len(pw["w"])):
                owner.setdefault((pw["x"] + k * dx, pw["y"] + k * dy), []).append(i)
        adj = {i: set() for i in range(len(words))}
        for idx in owner.values():
            for i in idx:
                adj[i].update(idx)
        seen = {0}
        stack = [0]
        while stack:
            for j in adj[stack.pop()]:
                if j not in seen:
                    seen.add(j)
                    stack.append(j)
        if len(seen) != len(words):
            loose = sorted(words[i]["w"] for i in range(len(words)) if i not in seen)
            errors.append(f"rule 6: words not connected to the rest: {', '.join(loose)}")
    return errors


def check_puzzle(p: dict, lex: Lexicon | None = None) -> list[str]:
    """All format rules for one puzzle. With `lex`, dictionary rules too."""
    errors: list[str] = []
    for key in ("id", "letters", "heat", "cols", "rows", "words", "bonus"):
        if key not in p:
            errors.append(f"missing field {key!r}")
    if errors:
        return errors
    letters = p["letters"]
    if not isinstance(letters, str) or not UPPER_RE.match(letters) or not 4 <= len(letters) <= 8:
        return [f"letters {letters!r} must be 4-8 uppercase A-Z"]
    if p["heat"] not in (1, 2, 3, 4, 5, 6):
        errors.append(f"heat {p['heat']!r} not in 1-6")
    words = p["words"]
    bonus = p["bonus"]
    if not isinstance(words, list) or not words:
        return errors + ["words must be a non-empty list"]
    if not isinstance(bonus, list):
        return errors + ["bonus must be a list"]
    for pw in words:
        if (not isinstance(pw, dict) or set(pw) != {"w", "x", "y", "d"}
                or not isinstance(pw["w"], str) or not UPPER_RE.match(pw["w"])
                or not isinstance(pw["x"], int) or not isinstance(pw["y"], int)
                or pw["d"] not in ("a", "d")):
            return errors + [f"malformed word entry {pw!r}"]
    for b in bonus:
        if not isinstance(b, str) or not UPPER_RE.match(b):
            return errors + [f"malformed bonus word {b!r}"]

    have = Counter(letters)
    grid_words = [pw["w"] for pw in words]
    # Rule 1
    for w in grid_words + bonus:
        if len(w) < 3:
            errors.append(f"rule 1: {w} is shorter than 3 letters")
        elif not _formable(w, have):
            errors.append(f"rule 1: {w} can't be made from {letters}")
    # Rule 2
    full = [w for w in grid_words if len(w) == len(letters) and signature(w) == signature(letters)]
    if not full:
        errors.append("rule 2: no grid word uses all the letters")
    # Letters order never spells the longest word (nor any all-letter word).
    longest = max(grid_words, key=len)
    if letters == longest or letters in full:
        errors.append(f"letters {letters} spell a grid word")
    # Rule 3
    dup = [w for w, n in Counter(grid_words + bonus).items() if n > 1]
    if dup:
        errors.append(f"rule 3: repeated words: {', '.join(sorted(dup))}")
    if bonus != sorted(bonus):
        errors.append("bonus list is not sorted")
    # Rules 4-6 and the crop
    errors += check_layout(words, p["cols"], p["rows"])
    # Rule 7 and dictionary membership
    if lex is not None:
        for w in grid_words + bonus:
            lw = w.lower()
            if lw in lex.blocked:
                errors.append(f"rule 7: blocked word {w}")
            elif lw not in lex.accepted:
                errors.append(f"{w} is not an accepted word")
        expected = sorted(w.upper() for w in lex.subwords(letters) if w.upper() not in set(grid_words))
        if expected != bonus:
            missing = sorted(set(expected) - set(bonus))
            extra = sorted(set(bonus) - set(expected))
            msg = "bonus list differs from every accepted word formable from the letters"
            if missing:
                msg += f"; missing {', '.join(missing[:10])}"
            if extra:
                msg += f"; unexpected {', '.join(extra[:10])}"
            errors.append(msg)
    return errors
