"""Pick-sequence fixture: grayscale frames with known loop period."""
from __future__ import annotations

from pathlib import Path

from PIL import Image

SIZE = 32


def gen_pick_sequence(period: int = 8, cycles: int = 3, out_dir=None):
    """period*cycles frames of 32x32 grayscale; value repeats every `period`.

    Frame i is solid gray level = 20 + 20 * (i % period), so loop detection
    has a ground-truth period to recover.
    """
    n = period * cycles
    frames = []
    for i in range(n):
        level = 20 + 20 * (i % period)
        im = Image.new("L", (SIZE, SIZE), level).convert("RGB")
        frames.append(im)
    if out_dir is not None:
        out_dir = Path(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        paths = []
        for i, im in enumerate(frames):
            p = out_dir / f"pk_{i:03d}.png"
            im.save(p)
            paths.append(p)
        return paths
    return frames
