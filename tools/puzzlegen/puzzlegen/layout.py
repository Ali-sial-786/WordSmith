"""Crossword layout: greedy interlocking placement with randomized restarts.

The grid is kept valid after every placement (proper crossword spacing, see
shared/puzzle-format.md rule 5), so a finished layout never needs repair.
The independent checker in `rules.py` re-verifies every puzzle anyway.
"""

from __future__ import annotations

import random
from dataclasses import dataclass

ACROSS = 1
DOWN = 2
MAX_SIDE = 10

# A bit wider than tall (the mold area on a phone in portrait is wider than
# tall).
ASPECT_LO = 0.8
ASPECT_HI = 1.6
ASPECT_IDEAL = 1.15


class Grid:
    """A partial crossword. Coordinates may go negative while building."""

    __slots__ = ("cells", "dirs", "by_letter", "words", "minx", "maxx", "miny", "maxy")

    def __init__(self) -> None:
        self.cells: dict[tuple[int, int], str] = {}
        self.dirs: dict[tuple[int, int], int] = {}
        self.by_letter: dict[str, list[tuple[int, int]]] = {}
        self.words: list[tuple[str, int, int, int]] = []
        self.minx = self.miny = 1 << 30
        self.maxx = self.maxy = -(1 << 30)

    @property
    def width(self) -> int:
        return self.maxx - self.minx + 1 if self.words else 0

    @property
    def height(self) -> int:
        return self.maxy - self.miny + 1 if self.words else 0

    def crossings(self) -> int:
        return sum(1 for v in self.dirs.values() if v == ACROSS | DOWN)

    def local_check(self, word: str, x: int, y: int, d: int):
        """Crossings if `word` fits at (x, y, d) by the spacing rules, else None.

        Ignores the size limit. Letters are only ever added, so a position
        that fails here can never become valid later.
        """
        cells = self.cells
        dirs = self.dirs
        n = len(word)
        cross = 0
        if d == ACROSS:
            if (x - 1, y) in cells or (x + n, y) in cells:
                return None
            for k in range(n):
                c = (x + k, y)
                got = cells.get(c)
                if got is not None:
                    if got != word[k] or dirs[c] & ACROSS:
                        return None
                    cross += 1
                elif (x + k, y - 1) in cells or (x + k, y + 1) in cells:
                    return None
        else:
            if (x, y - 1) in cells or (x, y + n) in cells:
                return None
            for k in range(n):
                c = (x, y + k)
                got = cells.get(c)
                if got is not None:
                    if got != word[k] or dirs[c] & DOWN:
                        return None
                    cross += 1
                elif (x - 1, y + k) in cells or (x + 1, y + k) in cells:
                    return None
        if self.words and (cross == 0 or cross == n):
            return None
        return cross

    def bbox_with(self, word: str, x: int, y: int, d: int):
        n = len(word)
        x2, y2 = (x + n - 1, y) if d == ACROSS else (x, y + n - 1)
        return (min(self.minx, x), max(self.maxx, x2), min(self.miny, y), max(self.maxy, y2))

    def check(self, word: str, x: int, y: int, d: int, max_w: int = MAX_SIDE,
              max_h: int = MAX_SIDE):
        """Return (crossings, new bbox) if `word` can go at (x, y, d), else None."""
        cross = self.local_check(word, x, y, d)
        if cross is None:
            return None
        minx, maxx, miny, maxy = self.bbox_with(word, x, y, d)
        if maxx - minx + 1 > max_w or maxy - miny + 1 > max_h:
            return None
        return cross, (minx, maxx, miny, maxy)

    def candidates(self, word: str):
        """Distinct (x, y, d) positions where `word` crosses an existing letter."""
        out = set()
        dirs = self.dirs
        for i, ch in enumerate(word):
            for (cx, cy) in self.by_letter.get(ch, ()):
                dv = dirs[(cx, cy)]
                if dv == DOWN:
                    out.add((cx - i, cy, ACROSS))
                elif dv == ACROSS:
                    out.add((cx, cy - i, DOWN))
        return sorted(out)

    def place(self, word: str, x: int, y: int, d: int) -> None:
        dx, dy = (1, 0) if d == ACROSS else (0, 1)
        for k, ch in enumerate(word):
            c = (x + k * dx, y + k * dy)
            if c in self.cells:
                self.dirs[c] |= d
            else:
                self.cells[c] = ch
                self.dirs[c] = d
                self.by_letter.setdefault(ch, []).append(c)
        self.words.append((word, x, y, d))
        self.minx = min(self.minx, x)
        self.miny = min(self.miny, y)
        self.maxx = max(self.maxx, x + (len(word) - 1) * dx)
        self.maxy = max(self.maxy, y + (len(word) - 1) * dy)

    def cropped(self) -> list[tuple[str, int, int, str]]:
        """Placed words shifted so the bounding box starts at (0, 0)."""
        return [
            (w, x - self.minx, y - self.miny, "a" if d == ACROSS else "d")
            for (w, x, y, d) in self.words
        ]


def aspect_penalty(w: int, h: int) -> float:
    if h == 0:
        return 0.0
    r = w / h
    if r < ASPECT_LO:
        return (ASPECT_LO - r) * 4.0
    if r > ASPECT_HI:
        return (r - ASPECT_HI) * 2.0
    return abs(r - ASPECT_IDEAL) * 0.5


@dataclass
class LayoutOptions:
    max_w: int = MAX_SIDE
    max_h: int = MAX_SIDE
    restarts: int = 24
    window: int = 12  # how many top-priority unplaced words compete each step
    across_first: float = 0.65  # chance the main word goes across
    # placement scoring
    w_cross: float = 6.0  # per crossing beyond the first
    w_growth: float = 0.3  # per cell of bounding-box growth
    w_aspect: float = 2.5
    w_noise: float = 0.8
    jitter: float = 1.5
    # final layout scoring
    f_cross: float = 4.0
    f_density: float = 25.0
    f_aspect: float = 10.0
    f_area: float = 0.25
    f_center: float = 15.0
    f_out_of_shape: float = 40.0  # aspect outside ASPECT_LO..ASPECT_HI
    f_priority: float = 3.0  # prefer layouts using higher-priority (commoner) words


@dataclass
class Layout:
    grid: Grid
    score: float

    @property
    def words(self) -> list[str]:
        return [w for (w, _, _, _) in self.grid.words]


def _touches(x: int, y: int, d: int, n: int, px1: int, py1: int, px2: int, py2: int) -> bool:
    """Could cells in [px1..px2] x [py1..py2] change whether a placement is valid?

    A placement depends on its own cells, the cells just before and after it,
    and the cells beside it.
    """
    if d == ACROSS:
        if py1 <= y <= py2 and px1 <= x + n and px2 >= x - 1:
            return True
        return py1 <= y + 1 and py2 >= y - 1 and px1 <= x + n - 1 and px2 >= x
    if px1 <= x <= px2 and py1 <= y + n and py2 >= y - 1:
        return True
    return px1 <= x + 1 and px2 >= x - 1 and py1 <= y + n - 1 and py2 >= y


def _grow(grid: Grid, pool: list[str], priority: dict[str, float], target: int,
          rng: random.Random, opts: LayoutOptions) -> None:
    """Greedily add words from `pool` (best first) until `target` are placed.

    Each word's valid positions are tracked incrementally and lazily: every
    placement is logged as an event, and a word catches up on the events it
    hasn't seen only when it is considered. Catching up re-checks the
    positions near the new word and adds the positions crossing its letters.
    """
    remaining = list(pool)
    jitter = {w: rng.random() * opts.jitter for w in remaining}
    remaining.sort(key=lambda w: -(priority[w] + jitter[w]))
    max_w, max_h = opts.max_w, opts.max_h
    valid: dict[str, dict[tuple[int, int, int], int]] = {w: {} for w in remaining}
    dead: dict[str, set] = {w: set() for w in remaining}
    seen = {w: 0 for w in remaining}
    letter_at = {w: [(i, ch) for i, ch in enumerate(w)] for w in remaining}
    events: list[tuple[tuple[int, int, int, int], list]] = []

    def log_event(word: str, x: int, y: int, d: int, new_cells) -> None:
        n = len(word)
        x2, y2 = (x + n - 1, y) if d == ACROSS else (x, y + n - 1)
        events.append(((x, y, x2, y2), new_cells))

    def catch_up(w: str) -> None:
        k = seen[w]
        if k == len(events):
            return
        vw, dw = valid[w], dead[w]
        n = len(w)
        todo = events[k:]
        seen[w] = len(events)
        if vw:
            stale = [pos for pos in vw
                     if any(_touches(pos[0], pos[1], pos[2], n, *ext) for ext, _ in todo)]
            for pos in stale:
                cross = grid.local_check(w, *pos)
                if cross is None:
                    del vw[pos]
                    dw.add(pos)
                else:
                    vw[pos] = cross
        for _, new_cells in todo:
            for (cx, cy, ch, dv) in new_cells:
                for i, c in letter_at[w]:
                    if c != ch:
                        continue
                    pos = (cx - i, cy, ACROSS) if dv == DOWN else (cx, cy - i, DOWN)
                    if pos in vw or pos in dw:
                        continue
                    cross = grid.local_check(w, *pos)
                    if cross is None:
                        dw.add(pos)
                    else:
                        vw[pos] = cross

    (mw, mx, my, md) = grid.words[0]
    sx, sy = (1, 0) if md == ACROSS else (0, 1)
    log_event(mw, mx, my, md, [(mx + k * sx, my + k * sy, ch, md) for k, ch in enumerate(mw)])

    while len(grid.words) < target and remaining:
        best = None
        considered = 0
        area = grid.width * grid.height
        gminx, gmaxx, gminy, gmaxy = grid.minx, grid.maxx, grid.miny, grid.maxy
        for w in remaining:
            if considered >= opts.window:
                break
            catch_up(w)
            vw = valid[w]
            if not vw:
                continue
            n = len(w)
            pw = priority[w] + jitter[w]
            drop = []
            for pos, cross in vw.items():
                x, y, d = pos
                if d == ACROSS:
                    minx, maxx = min(gminx, x), max(gmaxx, x + n - 1)
                    miny, maxy = min(gminy, y), max(gmaxy, y)
                else:
                    minx, maxx = min(gminx, x), max(gmaxx, x)
                    miny, maxy = min(gminy, y), max(gmaxy, y + n - 1)
                bw, bh = maxx - minx + 1, maxy - miny + 1
                if bw > max_w or bh > max_h:
                    drop.append(pos)  # the box only grows: never fits again
                    continue
                s = (
                    pw
                    + opts.w_cross * (cross - 1)
                    - opts.w_growth * (bw * bh - area)
                    - opts.w_aspect * aspect_penalty(bw, bh)
                    + rng.random() * opts.w_noise
                )
                if best is None or s > best[0]:
                    best = (s, w, x, y, d)
            for pos in drop:
                del vw[pos]
                dead[w].add(pos)
            if vw:
                considered += 1
        if best is None:
            return
        _, w, x, y, d = best
        dx, dy = (1, 0) if d == ACROSS else (0, 1)
        new_cells = [(x + k * dx, y + k * dy, ch, d) for k, ch in enumerate(w)
                     if (x + k * dx, y + k * dy) not in grid.cells]
        grid.place(w, x, y, d)
        remaining.remove(w)
        log_event(w, x, y, d, new_cells)


def score_layout(grid: Grid, main: str, priority: dict[str, float], target: int,
                 opts: LayoutOptions) -> float:
    n = len(grid.words)
    w, h = grid.width, grid.height
    cells = len(grid.cells)
    cross = grid.crossings()
    density = cells / (w * h)
    s = 0.0
    s += 100.0 * min(n, target)
    s += opts.f_cross * cross
    s += opts.f_density * density
    s -= opts.f_aspect * aspect_penalty(w, h)
    if not ASPECT_LO <= w / h <= ASPECT_HI:
        s -= opts.f_out_of_shape
    s -= opts.f_area * w * h
    s += opts.f_priority * sum(priority[x] for (x, _, _, _) in grid.words[1:])
    # Longest word central: penalize its midpoint's distance from the centre.
    for (word, x, y, d) in grid.words:
        if word == main:
            n_ = len(word)
            mx = (x - grid.minx) + ((n_ - 1) / 2 if d == ACROSS else 0)
            my = (y - grid.miny) + ((n_ - 1) / 2 if d == DOWN else 0)
            s -= opts.f_center * (abs(mx - (w - 1) / 2) / max(w, 1)
                                  + abs(my - (h - 1) / 2) / max(h, 1))
            break
    return s


def build(main: str, others: list[str], priority: dict[str, float], target: int,
          rng: random.Random, opts: LayoutOptions | None = None) -> Layout | None:
    """Best layout over `opts.restarts` randomized greedy runs."""
    opts = opts or LayoutOptions()
    best: Layout | None = None
    pool = [w for w in others if w != main]
    for _ in range(opts.restarts):
        grid = Grid()
        d = ACROSS if rng.random() < opts.across_first else DOWN
        if len(main) > (opts.max_w if d == ACROSS else opts.max_h):
            d = DOWN if d == ACROSS else ACROSS
        grid.place(main, 0, 0, d)
        _grow(grid, pool, priority, target, rng, opts)
        s = score_layout(grid, main, priority, target, opts)
        if best is None or s > best.score:
            best = Layout(grid, s)
    return best
