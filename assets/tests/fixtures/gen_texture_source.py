"""Texture fixtures for seamless-tile method checks."""
from __future__ import annotations

from PIL import Image

SIZE = 32


def gen_texture_source(path=None, size: int = SIZE):
    """Hard left-to-right gradient: large wrap seam discontinuity before tiling.

    Pixel R channel = x * 255 // (size-1); G/B fixed. Wrap boundary jumps
    from near-white to black -- offset method has something measurable to fix.
    """
    im = Image.new("RGB", (size, size))
    for y in range(size):
        for x in range(size):
            r = x * 255 // max(1, size - 1)
            im.putpixel((x, y), (r, 80, 120))
    if path is not None:
        im.save(path)
        return path
    return im


def gen_mirror_texture(path=None, size: int = SIZE):
    """Diagonal stripe pattern with exact half-quadrant structure for mirror check.

    Built so after mirror-method 2x2 flip the documented flip relations hold.
    Source itself is a simple two-tone diagonal -- the method enforces symmetry.
    """
    im = Image.new("RGB", (size, size))
    for y in range(size):
        for x in range(size):
            band = ((x + y) // 4) % 2
            im.putpixel((x, y), (200, 40, 40) if band else (40, 40, 200))
    if path is not None:
        im.save(path)
        return path
    return im
