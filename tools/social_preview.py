#!/usr/bin/env python3
"""Draw the GitHub social preview: a frame of the game with the four players'
trails spelling TRON.

GitHub's recommended size is 1280x640. Everything is drawn the way the chip
draws it: 16 px cells, RGB222 colours, a dark blue line on each cell's first
row and column, trails filling whole cells and white heads. Each letter is
one player's trail, a legal one: right angle turns only (diagonals are
staircases) and never crossing itself, so each is checked as it is walked.

    tools/social_preview.py [out.png]
"""

import struct
import sys
import zlib

W, H, CELL = 1280, 640, 16
GW, GH = W // CELL, H // CELL  # 80 x 40 cells; the last row is the score strip


def rgb222(r, g, b):
    return (r * 85, g * 85, b * 85)


COLOURS = [rgb222(0, 3, 3), rgb222(3, 2, 0), rgb222(3, 0, 3), rgb222(2, 3, 0)]
WHITE, GRID, BLACK = rgb222(3, 3, 3), rgb222(0, 0, 1), rgb222(0, 0, 0)


def stairs(dx, dy):
    """Runs for a staircase dx right and dy down, steps spread evenly,
    starting with a step right."""
    out, y = [], 0
    for i in range(1, dx + 1):
        out.append((1, 0))
        down = round(dy * i / dx) - y
        if down:
            out.append((0, down))
            y += down
    return out


def walk(start, moves):
    """Cells of a trail from start, following (dx, dy) runs along one axis."""
    x, y = start
    cells = [(x, y)]
    for dx, dy in moves:
        assert (dx == 0) != (dy == 0), "runs are horizontal or vertical"
        sx, sy = (dx > 0) - (dx < 0), (dy > 0) - (dy < 0)
        for _ in range(abs(dx) + abs(dy)):
            x, y = x + sx, y + sy
            cells.append((x, y))
    assert len(cells) == len(set(cells)), "a trail crossed itself"
    return cells


TOP, BOT = 8, 30  # letter rows: 23, centred in the 39 above the score strip
LW = 14           # letter width
GAP = 5


def letter_t(x0):
    # Up the stem, the bar as a loop, the head stopping short of the stem.
    stem = x0 + LW // 2
    return walk((stem, BOT), [(0, -(BOT - TOP - 2)), (x0 - stem, 0), (0, -2),
                              (LW - 1, 0), (0, 2), (stem + 2 - (x0 + LW - 1), 0)])


def letter_r(x0):
    # Up the stem, round the bowl, then the leg as a 45 degree staircase.
    bowl = BOT - (LW - 3) - 2
    return walk((x0, BOT), [(0, TOP - BOT), (LW - 2, 0), (0, bowl - TOP),
                            (-(LW - 4), 0), (0, 2)] +
                stairs(LW - 3, BOT - bowl - 2))


def letter_o(x0):
    # Round the outside, the head one cell short of the tail.
    return walk((x0, BOT), [(0, TOP - BOT), (LW - 1, 0), (0, BOT - TOP), (-(LW - 3), 0)])


def letter_n(x0):
    # Up, a 45 degree staircase meeting the right stem halfway down, then the
    # right stem as a loop like the T's bar (a trail can't draw a full stem
    # with a branch halfway), the head stopping short of the staircase.
    d = LW - 4
    return walk((x0, BOT), [(0, TOP - BOT)] + stairs(d, d) +
                [(1, 0), (0, -d), (2, 0), (0, BOT - TOP), (-2, 0), (0, -(BOT - TOP - d - 2))])


_x0 = (GW - (4 * LW + 3 * GAP)) // 2
LETTERS = [letter_t(_x0), letter_r(_x0 + LW + GAP), letter_o(_x0 + 2 * (LW + GAP)),
           letter_n(_x0 + 3 * (LW + GAP))]

SCORES = [3, 1, 2, 2]


def render():
    px = [[BLACK] * W for _ in range(H)]
    for y in range(H - CELL):
        for x in range(W):
            if x % CELL == 0 or y % CELL == 0:
                px[y][x] = GRID
    owner = {}
    for p, cells in enumerate(LETTERS):
        for c in cells:
            assert c not in owner, f"trails {owner[c]} and {p} cross at {c}"
            assert 0 <= c[0] < GW and 0 <= c[1] < GH - 1
            owner[c] = p
    for p, cells in enumerate(LETTERS):
        for i, (cx, cy) in enumerate(cells):
            colour = WHITE if i == len(cells) - 1 else COLOURS[p]
            for y in range(cy * CELL, (cy + 1) * CELL):
                for x in range(cx * CELL, (cx + 1) * CELL):
                    px[y][x] = colour
    # Score strip, as on the chip: a quarter of the width each, 12 x 4 px pips.
    strip = H - CELL
    for p, score in enumerate(SCORES):
        for k in range(score):
            x0 = p * (W // 4) + k * CELL + 2
            for y in range(strip + 6, strip + 10):
                for x in range(x0, x0 + 12):
                    px[y][x] = COLOURS[p]
    return px


def write_png(path, px):
    raw = b"".join(b"\x00" + bytes(c for p in row for c in p) for row in px)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


if __name__ == "__main__":
    write_png(sys.argv[1] if len(sys.argv) > 1 else "docs/social_preview.png", render())
