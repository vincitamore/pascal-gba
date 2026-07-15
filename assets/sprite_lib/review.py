"""sprite_lib.review -- agent-forward inspection of baked artifacts.

Every operation returns the path to a viewable PNG/GIF and a JSON record the agent
can read to decide whether to regenerate. The whole point of this module: an agent
can `sprite review inspect foo.inc` and decide "this needs another iteration"
without an operator describing what's on the screen.

Capabilities:
  montage   contact-sheet PNG grid of N images
  gif       loop-detected animated GIF of a frame sequence
  tile      3x3 tiled preview from a tile .inc or a single texture PNG
  inspect   parse a baked .inc, return palette + dims + frames + transparent count
  palette   visualize palette swatches as a side strip PNG
  diff      side-by-side + pixel-delta map of two images (e.g. result vs reference)
"""
from __future__ import annotations
import math
import re
from pathlib import Path
from typing import Sequence

from PIL import Image, ImageChops

from . import util


# ============================================================
# Montage / contact sheet
# ============================================================

def montage(images: Sequence[str | Path],
            out: str | Path,
            *,
            cols: int = 0,
            cell: tuple[int, int] = (0, 0),
            pad: int = 4,
            bg: tuple[int, int, int] = (40, 40, 40)) -> dict:
    """Grid contact-sheet. cols=0 -> sqrt(N) ceil. cell=(0,0) -> derive from first image.

    All inputs are resized to `cell` (BOX filter). Output goes to `out`. Returns
    {op, out, n, cols, rows, cell}.
    """
    paths = [Path(p) for p in images]
    if not paths:
        raise ValueError("montage: no images")
    imgs = [Image.open(p).convert("RGB") for p in paths]
    if cell == (0, 0):
        cell = imgs[0].size
    cw, ch = cell
    n = len(imgs)
    if cols <= 0:
        cols = max(1, math.ceil(math.sqrt(n)))
    rows = math.ceil(n / cols)
    W = cols * cw + (cols + 1) * pad
    H = rows * ch + (rows + 1) * pad
    sheet = Image.new("RGB", (W, H), bg)
    for i, im in enumerate(imgs):
        r, c = divmod(i, cols)
        x = pad + c * (cw + pad)
        y = pad + r * (ch + pad)
        sheet.paste(im.resize((cw, ch), Image.BOX), (x, y))
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    return {"op": "montage", "out": str(out), "n": n,
            "cols": cols, "rows": rows, "cell": list(cell)}


# ============================================================
# Animated GIF preview from a frame sequence
# ============================================================

def gif(frames: Sequence[str | Path],
        out: str | Path,
        *,
        frame_ms: int = 110,
        scale: int = 0,
        loop: int = 0) -> dict:
    """Looping GIF from a frame sequence. scale=0 auto-scales to ~192px max side."""
    paths = [Path(p) for p in frames]
    if not paths:
        raise ValueError("gif: no frames")
    imgs = [Image.open(p).convert("RGB") for p in paths]
    if scale <= 0:
        w, h = imgs[0].size
        scale = max(1, 192 // max(w, h))
    if scale > 1:
        imgs = [im.resize((im.width * scale, im.height * scale), Image.NEAREST)
                for im in imgs]
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    # Windows-Photos-friendly: no disposal flag (disposal=2 refuses to loop there),
    # shared adaptive palette so per-frame quantize does not freeze motion.
    w, h = imgs[0].size
    stack = Image.new("RGB", (w * len(imgs), h))
    for i, im in enumerate(imgs):
        stack.paste(im, (i * w, 0))
    q_stack = stack.quantize(colors=255, method=Image.MEDIANCUT, dither=Image.NONE)
    q_frames = [q_stack.crop((i * w, 0, (i + 1) * w, h)) for i in range(len(imgs))]
    q_frames[0].save(out, save_all=True, append_images=q_frames[1:],
                     duration=frame_ms, loop=loop, optimize=False)
    return {"op": "gif", "out": str(out), "frames": len(imgs),
            "frame_ms": frame_ms, "scale": scale}


# ============================================================
# 3x3 tile preview (from PNG OR from a baked .inc)
# ============================================================

def tile3x3(src: str | Path,
            out: str | Path,
            *,
            scale: int = 4) -> dict:
    """Render a 3x3 tiled preview. src can be a PNG/JPG or a baked .inc."""
    src = Path(src)
    if src.suffix.lower() in (".png", ".jpg", ".jpeg", ".webp", ".bmp"):
        tile = Image.open(src).convert("RGB")
    elif src.suffix.lower() == ".inc":
        tile = _render_inc_frame(src, frame=0)
    else:
        raise ValueError(f"tile3x3: unsupported src extension {src.suffix!r}")
    W, H = tile.size
    grid = Image.new("RGB", (W * 3, H * 3))
    for gy in range(3):
        for gx in range(3):
            grid.paste(tile, (gx * W, gy * H))
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    grid.resize((W * 3 * scale, H * 3 * scale), Image.NEAREST).save(out)
    return {"op": "tile3x3", "out": str(out), "tile_size": [W, H], "scale": scale}


# ============================================================
# Inspect / palette / diff
# ============================================================

def inspect(inc_path: str | Path) -> dict:
    """Parse a baked .inc and return its metadata + per-frame transparent counts."""
    inc_path = Path(inc_path)
    text = inc_path.read_text()
    parsed = _parse_inc(text)
    # transparent-pixel counts (palette index 0 in each frame)
    W, H, frames, obj_order = parsed["W"], parsed["H"], parsed["frames"], parsed["obj_order"]
    palette = parsed["palette_rgb"]
    bytes_per_frame = (W * H) // 2
    frame_stats = []
    for f in range(frames):
        start = f * bytes_per_frame
        chunk = parsed["bytes"][start:start + bytes_per_frame]
        ix = _unpack_4bpp(chunk)
        if obj_order:
            ix = _untranspose_obj(ix, W, H)
        transp = sum(1 for v in ix if v == 0)
        used = {v for v in ix if v != 0}
        frame_stats.append({"frame": f, "transparent_px": transp,
                            "colors_used": sorted(used)})
    return {"op": "inspect", "inc": str(inc_path), "name": parsed["name"],
            "size": [W, H], "frames": frames, "obj_order": obj_order,
            "palette": [{"slot": i, "rgb": list(c)} for i, c in enumerate(palette)],
            "frame_stats": frame_stats}


def palette_strip(inc_path: str | Path,
                  out: str | Path,
                  *,
                  swatch: int = 32) -> dict:
    """Render a strip of palette swatches with index labels (no text -- color only).

    A border separates each swatch; slot 0 is shown as a hatched 'transparent' tile
    so the agent can see at a glance which colors actually contribute.
    """
    parsed = _parse_inc(Path(inc_path).read_text())
    pal = parsed["palette_rgb"]
    N = len(pal)
    W = N * swatch + (N + 1)  # 1px borders
    H = swatch + 2
    im = Image.new("RGB", (W, H), (0, 0, 0))
    for i, c in enumerate(pal):
        x0 = 1 + i * (swatch + 1)
        if i == 0:
            # hatch pattern for transparent
            for y in range(swatch):
                for x in range(swatch):
                    base = (200, 200, 200) if ((x // 4 + y // 4) & 1) else (140, 140, 140)
                    im.putpixel((x0 + x, 1 + y), base)
        else:
            for y in range(swatch):
                for x in range(swatch):
                    im.putpixel((x0 + x, 1 + y), c)
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    im.resize((W * 2, H * 2), Image.NEAREST).save(out)
    return {"op": "palette_strip", "out": str(out), "swatches": N}


def diff(a: str | Path, b: str | Path,
         out: str | Path,
         *,
         delta_amp: int = 4) -> dict:
    """Side-by-side + delta map of two images. delta_amp >=1 brightens the delta."""
    ai = Image.open(a).convert("RGB")
    bi = Image.open(b).convert("RGB")
    # resize b to a's dims if they differ
    if ai.size != bi.size:
        bi = bi.resize(ai.size, Image.NEAREST)
    delta = ImageChops.difference(ai, bi)
    if delta_amp > 1:
        # amplify per-pixel
        dp = delta.load()
        for y in range(delta.height):
            for x in range(delta.width):
                r, g, bb = dp[x, y]
                dp[x, y] = (min(255, r * delta_amp),
                            min(255, g * delta_amp),
                            min(255, bb * delta_amp))
    W, H = ai.size
    sheet = Image.new("RGB", (W * 3 + 4, H), (20, 20, 20))
    sheet.paste(ai, (0, 0))
    sheet.paste(bi, (W + 2, 0))
    sheet.paste(delta, (W * 2 + 4, 0))
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    # summary stats
    dvals = list(delta.getdata())
    total_delta = sum(sum(p) for p in dvals)
    max_delta = max(sum(p) for p in dvals) if dvals else 0
    return {"op": "diff", "out": str(out),
            "a": str(a), "b": str(b),
            "size": [W, H],
            "total_channel_delta": total_delta,
            "max_pixel_delta": max_delta,
            "avg_pixel_delta": round(total_delta / (W * H * 3), 3)}


# ============================================================
# .inc parser (shared with emulate)
# ============================================================

_HEX = r"\$([0-9A-Fa-f]+)"


def _parse_inc(text: str) -> dict:
    """Pull NAME, W, H, FRAMES, OBJ_ORDER, palette words, tile bytes from a baked .inc.

    The schema is the one util.emit_inc produces, but we also tolerate older bakes
    that don't have NAME_FRAMES / NAME_OBJ_ORDER (defaults: 1 frame, linear).
    """
    m = re.search(r"const\s+(\w+)_W\s*=\s*(\d+)", text)
    if not m:
        raise ValueError("no NAME_W const found")
    name, W = m.group(1), int(m.group(2))
    H = int(re.search(rf"{name}_H\s*=\s*(\d+)", text).group(1))
    fm = re.search(rf"{name}_FRAMES\s*=\s*(\d+)", text)
    frames = int(fm.group(1)) if fm else 1
    om = re.search(rf"{name}_OBJ_ORDER\s*=\s*(\d+)", text)
    obj_order = bool(int(om.group(1))) if om else False
    # palette
    pal_block = re.search(rf"{name}_PAL[^=]*=\s*\(([^)]*)\)", text, flags=re.S)
    if not pal_block:
        raise ValueError("no NAME_PAL block found")
    words = [int(h, 16) for h in re.findall(_HEX, pal_block.group(1))]
    palette_rgb = [_bgr555_to_rgb(w) for w in words]
    # tiles
    tile_block = re.search(rf"{name}_TILES[^=]*=\s*\(([^)]*)\)", text, flags=re.S)
    if not tile_block:
        raise ValueError("no NAME_TILES block found")
    tiles = [int(h, 16) for h in re.findall(_HEX, tile_block.group(1))]
    return {"name": name, "W": W, "H": H, "frames": frames, "obj_order": obj_order,
            "palette_rgb": palette_rgb, "bytes": tiles}


def _bgr555_to_rgb(w: int) -> tuple[int, int, int]:
    r = (w & 0x1F) << 3
    g = ((w >> 5) & 0x1F) << 3
    b = ((w >> 10) & 0x1F) << 3
    return r, g, b


def _unpack_4bpp(packed: list[int]) -> list[int]:
    out: list[int] = []
    for b in packed:
        out.append(b & 0xF)
        out.append((b >> 4) & 0xF)
    return out


def _untranspose_obj(indices: list[int], W: int, H: int) -> list[int]:
    """Reverse pack_4bpp_obj: take OBJ-ordered pixel indices, return scanline order."""
    if W % 8 or H % 8:
        raise ValueError("untranspose_obj needs W,H multiple of 8")
    tilesW = W // 8
    scan = [0] * (W * H)
    for y in range(H):
        for x in range(W):
            tx, ty = x >> 3, y >> 3
            tileNo = ty * tilesW + tx
            row, col = y & 7, x & 7
            obj_px_idx = tileNo * 64 + row * 8 + col  # pixel index within OBJ order
            scan[y * W + x] = indices[obj_px_idx]
    return scan


def _render_inc_frame(inc_path: Path, *, frame: int = 0) -> Image.Image:
    """Render one frame of an .inc back to a PIL image (scanline order). Transparent
    pixels (palette index 0) render as a neutral gray so they read as 'transparent'."""
    parsed = _parse_inc(Path(inc_path).read_text())
    W, H, obj_order = parsed["W"], parsed["H"], parsed["obj_order"]
    pal = parsed["palette_rgb"]
    bpf = (W * H) // 2
    chunk = parsed["bytes"][frame * bpf:(frame + 1) * bpf]
    indices = _unpack_4bpp(chunk)
    if obj_order:
        indices = _untranspose_obj(indices, W, H)
    TRANSP = (60, 60, 60)
    data = [TRANSP if v == 0 else pal[v] for v in indices]
    im = Image.new("RGB", (W, H))
    im.putdata(data)
    return im


def render_inc_frames(inc_path: str | Path) -> list[Image.Image]:
    """Public: render every frame in a baked .inc as a list of PIL RGB images."""
    parsed = _parse_inc(Path(inc_path).read_text())
    return [_render_inc_frame(Path(inc_path), frame=f) for f in range(parsed["frames"])]
