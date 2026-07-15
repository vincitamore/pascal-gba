#!/usr/bin/env python3
"""Regenerate test/font8.inc: an 8x8 glyph bank covering codepoints $20..$5F.

Draws a compact 3x5 pixel font (digits, A-Z, basic punctuation; unassigned
codepoints stay blank) onto a 16x4-cell sheet, then bakes it through the
asset pipeline's real font-bake path -- so the committed glyph bank is also
a standing exercise of that path. The .inc is committed; rerun this only
when the glyph set changes.

Usage (from the repo root):
    python tools/gen-test-font.py
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "assets"))

from PIL import Image                     # noqa: E402
from sprite_lib import bake               # noqa: E402

# 3x5 glyph rows, msb = left pixel of the 3-wide row.
GLYPHS: dict[str, tuple[str, ...]] = {
    "0": ("111", "101", "101", "101", "111"),
    "1": ("010", "110", "010", "010", "111"),
    "2": ("111", "001", "111", "100", "111"),
    "3": ("111", "001", "111", "001", "111"),
    "4": ("101", "101", "111", "001", "001"),
    "5": ("111", "100", "111", "001", "111"),
    "6": ("111", "100", "111", "101", "111"),
    "7": ("111", "001", "001", "010", "010"),
    "8": ("111", "101", "111", "101", "111"),
    "9": ("111", "101", "111", "001", "111"),
    "A": ("010", "101", "111", "101", "101"),
    "B": ("110", "101", "110", "101", "110"),
    "C": ("011", "100", "100", "100", "011"),
    "D": ("110", "101", "101", "101", "110"),
    "E": ("111", "100", "110", "100", "111"),
    "F": ("111", "100", "110", "100", "100"),
    "G": ("011", "100", "101", "101", "011"),
    "H": ("101", "101", "111", "101", "101"),
    "I": ("111", "010", "010", "010", "111"),
    "J": ("011", "001", "001", "101", "010"),
    "K": ("101", "110", "100", "110", "101"),
    "L": ("100", "100", "100", "100", "111"),
    "M": ("101", "111", "111", "101", "101"),
    "N": ("110", "101", "101", "101", "101"),
    "O": ("010", "101", "101", "101", "010"),
    "P": ("110", "101", "110", "100", "100"),
    "Q": ("010", "101", "101", "110", "011"),
    "R": ("110", "101", "110", "110", "101"),
    "S": ("011", "100", "010", "001", "110"),
    "T": ("111", "010", "010", "010", "010"),
    "U": ("101", "101", "101", "101", "111"),
    "V": ("101", "101", "101", "101", "010"),
    "W": ("101", "101", "111", "111", "101"),
    "X": ("101", "101", "010", "101", "101"),
    "Y": ("101", "101", "010", "010", "010"),
    "Z": ("111", "001", "010", "100", "111"),
    "!": ("010", "010", "010", "000", "010"),
    "'": ("010", "010", "000", "000", "000"),
    "-": ("000", "000", "111", "000", "000"),
    ".": ("000", "000", "000", "000", "010"),
    ":": ("000", "010", "000", "010", "000"),
    "?": ("110", "001", "010", "000", "010"),
}

COLS, ROWS = 16, 4          # codepoints $20..$5F in reading order
CELL = 8
START = 0x20


def main() -> None:
    sheet = Image.new("RGB", (COLS * CELL, ROWS * CELL), (0, 0, 0))
    px = sheet.load()
    for idx in range(COLS * ROWS):
        ch = chr(START + idx)
        rows = GLYPHS.get(ch)
        if rows is None:
            continue
        cx = (idx % COLS) * CELL + 2       # 3x5 glyph sits at (2,1) in its cell
        cy = (idx // COLS) * CELL + 1
        for ry, bits in enumerate(rows):
            for rx, b in enumerate(bits):
                if b == "1":
                    px[cx + rx, cy + ry] = (255, 255, 255)
    tmp = ROOT / "test" / "font8_sheet.png"
    sheet.save(tmp)
    rec = bake.bake_font_sheet(tmp, ROOT / "test" / "font8.inc", "FONT8",
                               grid=(COLS, ROWS), glyph_size=(CELL, CELL),
                               start_codepoint=START,
                               bg=(0, 0, 0), chroma=False, preview=False)
    tmp.unlink()                           # the sheet is scratch; the .inc ships
    print(f"font8.inc: {rec['glyph_count']} glyphs, "
          f"{rec['colors_used']} colors, codepoints "
          f"{rec['start_codepoint']:#x}..{rec['end_codepoint']:#x}")


if __name__ == "__main__":
    main()
