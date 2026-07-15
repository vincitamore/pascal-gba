"""Font-sheet fixture: pure black/white glyph grid with deterministic patterns."""
from __future__ import annotations

from PIL import Image

BLACK = (0, 0, 0)
WHITE = (255, 255, 255)
CELL = 8


def _glyph_pattern(index: int, size: int = CELL):
    """Return size x size binary grid (1=fg white, 0=bg black)."""
    grid = []
    for _ in range(size):
        grid.append([0] * size)
    # checkerboard phase shifted by index; plus a diagonal tick unique per cell
    phase = index % 2
    for y in range(size):
        for x in range(size):
            if ((x + y + phase) % 2) == 0:
                grid[y][x] = 1
    # unique diagonal mark so glyphs are not pure phase-flip twins
    mark = index % size
    grid[mark][mark] = 1
    grid[mark][(mark + 1) % size] = 0
    return grid


def gen_font_sheet(cols: int = 4, rows: int = 2, path=None):
    """cols*rows grid of 8x8 pure B/W glyphs. Saves if path given."""
    im = Image.new("RGB", (cols * CELL, rows * CELL), BLACK)
    for r in range(rows):
        for c in range(cols):
            idx = r * cols + c
            pat = _glyph_pattern(idx)
            for y in range(CELL):
                for x in range(CELL):
                    color = WHITE if pat[y][x] else BLACK
                    im.putpixel((c * CELL + x, r * CELL + y), color)
    if path is not None:
        im.save(path)
        return path
    return im


def expected_glyph_bitmap(index: int, size: int = CELL):
    """Public: same pattern gen_font_sheet uses for glyph `index`."""
    return _glyph_pattern(index, size)
