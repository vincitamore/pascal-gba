"""sprite_lib.tile -- uniform-texture -> seamless GBA terrain tile.

The pipeline insight: the model can't honor wrap-around prompts ("make a tileable
texture") directly, but it CAN produce a uniform, stationary, focal-point-free
texture that a trivial post-process wraps cleanly. Two wrap methods:

  - offset (default): blend the four half-rolled copies with sine weights at the
    seams. Toroidal continuity guaranteed; great on stationary noise; ghosts on
    sharp localized features.
  - mirror: 2x2 flip-quadrants. Zero blend; sometimes mirror-symmetric in a way
    that's fine for water/static-noise, bad for directional content.

Renders a 3x3 tiled preview (so seams are obvious), and (with --out) bakes the
tile to a GBA 4bpp .inc -- terrain BG tiles, so palette slot 0 is opaque (no
reserved transparent slot).
"""
from __future__ import annotations
import math
from pathlib import Path

from PIL import Image

from . import util


def make_seamless_offset(im: Image.Image) -> Image.Image:
    """4-way half-roll blend at sine-weighted seams. Pure-PIL, operates at tile res."""
    W, H = im.size
    src = im.load()

    def Rx(x, y): return src[(x + W // 2) % W, y % H]
    def Ry(x, y): return src[x % W, (y + H // 2) % H]
    def Rxy(x, y): return src[(x + W // 2) % W, (y + H // 2) % H]

    out = Image.new("RGB", (W, H))
    dst = out.load()
    for y in range(H):
        wy = math.sin(math.pi * (y + 0.5) / H)
        for x in range(W):
            wx = math.sin(math.pi * (x + 0.5) / W)
            a, b, c, d = src[x, y], Rx(x, y), Ry(x, y), Rxy(x, y)
            wa, wb, wc, wd = wx * wy, (1 - wx) * wy, wx * (1 - wy), (1 - wx) * (1 - wy)
            dst[x, y] = (
                int(a[0] * wa + b[0] * wb + c[0] * wc + d[0] * wd),
                int(a[1] * wa + b[1] * wb + c[1] * wc + d[1] * wd),
                int(a[2] * wa + b[2] * wb + c[2] * wc + d[2] * wd),
            )
    return out


def make_seamless_mirror(im: Image.Image) -> Image.Image:
    """2x2 mirror tile arrangement. Guaranteed seamless, but reflects."""
    W, H = im.size
    hw, hh = W // 2, H // 2
    q = im.resize((hw, hh), Image.BOX)
    out = Image.new("RGB", (W, H))
    out.paste(q, (0, 0))
    out.paste(q.transpose(Image.FLIP_LEFT_RIGHT), (hw, 0))
    out.paste(q.transpose(Image.FLIP_TOP_BOTTOM), (0, hh))
    out.paste(q.transpose(Image.ROTATE_180), (hw, hh))
    return out


def make_tile(infile: str | Path,
              out: str | Path,
              name: str,
              *,
              size: tuple[int, int] = (32, 32),
              method: str = "offset",
              colors: int = 15,
              preview_3x3: bool = True) -> dict:
    """Turn `infile` into a seamless GBA 4bpp tile and emit the .inc.

    Unlike sprites, BG terrain tiles don't need a reserved transparent slot, so
    we use all `colors` palette entries (default 15 + slot 0 = 16 total).

    Returns a JSON-friendly record. 3x3 tiled preview goes to <out>.3x3.png; the
    raw tile goes to <out>.tile.png.
    """
    infile = Path(infile)
    out = Path(out)
    W, H = size
    im = Image.open(infile).convert("RGB").resize((W, H), Image.BOX)
    tile_im = (make_seamless_offset(im) if method == "offset"
               else make_seamless_mirror(im))

    # quantize -- all slots opaque
    q = tile_im.quantize(colors=colors, method=Image.MEDIANCUT)
    qrgb = q.convert("RGB")
    palette: list[tuple[int, int, int]] = []
    idx: dict[tuple[int, int, int], int] = {}
    indices: list[int] = []
    for c in qrgb.getdata():
        if c not in idx:
            idx[c] = len(palette)
            palette.append(c)
        indices.append(idx[c])

    tile_bytes = util.pack_4bpp_linear(indices)
    util.emit_inc(out, name, W, H, palette, tile_bytes,
                  frames=1, obj_order=False,
                  include_transparent=False,
                  source_note=f"seamless {method} tile {W}x{H} from {infile.name}; {len(palette)} colors")
    rec = {
        "op": "make_tile",
        "infile": str(infile),
        "out": str(out),
        "name": name,
        "size": [W, H],
        "method": method,
        "colors_used": len(palette),
        "obj_order": False,
        "preview_tile": None,
        "preview_3x3": None,
    }
    if preview_3x3:
        tile_path = out.with_suffix(out.suffix + ".tile.png")
        qrgb.resize((W * 8, H * 8), Image.NEAREST).save(tile_path)
        rec["preview_tile"] = str(tile_path)
        grid = Image.new("RGB", (W * 3, H * 3))
        for gy in range(3):
            for gx in range(3):
                grid.paste(qrgb, (gx * W, gy * H))
        grid_path = out.with_suffix(out.suffix + ".3x3.png")
        grid.resize((W * 3 * 4, H * 3 * 4), Image.NEAREST).save(grid_path)
        rec["preview_3x3"] = str(grid_path)
    return rec
