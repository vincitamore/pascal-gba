"""Animation-frame fixture: translating solid square on magenta."""
from __future__ import annotations

from pathlib import Path

from PIL import Image

MAGENTA = (255, 0, 255)
FG = (32, 160, 220)
SIZE = 64
SQ = 16


def gen_anim_frames(n: int = 4, out_dir=None):
    """n 64x64 frames; solid square translates linearly within a fixed canvas.

    Returns list of PIL Images, or list of saved paths when out_dir is set.
    """
    frames = []
    for i in range(n):
        im = Image.new("RGB", (SIZE, SIZE), MAGENTA)
        # keep subject inside a stable union bbox (margin >= 8 all sides)
        x = 8 + i * 6
        y = 20
        for yy in range(y, y + SQ):
            for xx in range(x, x + SQ):
                im.putpixel((xx, yy), FG)
        frames.append(im)
    if out_dir is not None:
        out_dir = Path(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        paths = []
        for i, im in enumerate(frames):
            p = out_dir / f"af_{i:02d}.png"
            im.save(p)
            paths.append(p)
        return paths
    return frames
