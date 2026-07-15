"""sprite_lib.bake -- AI raster -> GBA 4bpp baker.

One module covers two flows: `bake_single` (one image -> sprite) and `bake_anim`
(N frames -> shared-palette, common-canvas animation). Both can emit `.inc` data
in linear (scanline) order OR in GBA OBJ 8x8-tile / 1D-mapping order (`obj=True`).

The OBJ path produces VRAM-ready bytes: copy directly into OBJ character VRAM with
no runtime transpose. The linear path matches the legacy bake_sprite.py output and
is what previews/sheet-assembly want.

Returns a JSON-friendly record for the CLI's --json output and for the asset
registry's manifest. Preview strip + GIF are emitted alongside the .inc.
"""
from __future__ import annotations
import collections
import glob
from pathlib import Path
from typing import Sequence

from PIL import Image

from . import util


# ============================================================
# Single-frame bake
# ============================================================

def bake_single(infile: str | Path,
                out: str | Path,
                name: str,
                *,
                size: tuple[int, int] = (32, 32),
                bg: tuple[int, int, int] | None = None,
                bg_tol: int = 30,
                bg_detect: str = "auto",
                colors: int = 15,
                margin: int = 2,
                autocrop: bool = True,
                obj: bool = True,
                preview: bool = True,
                gif_ms: int = 0,
                resample: str = "nearest",
                chroma: bool = True) -> dict:
    """Bake one source image to a single GBA 4bpp sprite .inc.

    `chroma=True` (default) enables the brightness-invariant magenta detector --
    the standard canonical workflow uses magenta key bg, and the model vignettes
    that bg slightly so distance-only keying leaves pink fringe pixels INSIDE
    the figure. Set `chroma=False` for non-magenta-keyed sources (rare).
    """
    infile = Path(infile)
    out = Path(out)
    W, H = size
    im = Image.open(infile).convert("RGB")
    bg_used, im_cropped, indices, palette = _prepare_single(
        im, W, H, bg, bg_tol, colors, margin, autocrop, resample,
        chroma=chroma, bg_detect=bg_detect)
    tile_bytes = (util.pack_4bpp_obj(indices, W, H)
                  if obj else util.pack_4bpp_linear(indices))
    util.emit_inc(out, name, W, H, palette, tile_bytes,
                  frames=1, obj_order=obj,
                  include_transparent=True,
                  source_note=f"single sprite from {infile.name}; {len(palette)} colors")
    rec = {
        "op": "bake_single",
        "infile": str(infile),
        "out": str(out),
        "name": name,
        "size": [W, H],
        "frames": 1,
        "colors_used": len(palette),
        "obj_order": obj,
        "bg": list(bg_used),
        "preview_strip": None,
        "preview_gif": None,
    }
    if preview:
        prev_path = _write_preview_strip([indices], W, H, palette, out, scale=8)
        rec["preview_strip"] = str(prev_path)
        # Always emit a screen-scale GIF (single-frame static GIF for solo bakes)
        # so the on-screen footprint is visible -- the strip shows palette detail,
        # the gif shows what it'll look like in the game.
        gif_path = _write_preview_gif([indices], W, H, palette, out,
                                      gif_ms if gif_ms > 0 else 1000)
        rec["preview_gif"] = str(gif_path)
    return rec


def _prepare_single(im: Image.Image, W: int, H: int,
                    bg: tuple[int, int, int] | None,
                    bg_tol: int, colors: int, margin: int,
                    autocrop: bool, resample: str, chroma: bool,
                    bg_detect: str = "auto",
                    ) -> tuple[tuple[int, int, int], Image.Image, list[int], list[tuple[int, int, int]]]:
    """Shared: detect bg, autocrop, downscale, quantize, build indices+palette."""
    filt = {"nearest": Image.NEAREST,
            "box": Image.BOX,
            "lanczos": Image.LANCZOS}[resample]
    if bg is None:
        bg = util.detect_bg(im, method=bg_detect)
    if autocrop:
        box = util.subject_bbox(im, bg, bg_tol, chroma=chroma, thr_pct=0.0)
        if box:
            x0, y0, x1, y1 = box
            crop = util.aspect_pad_box((x0, y0, x1, y1), im.size, (W, H), margin)
            im = im.crop(crop)
    small = im.resize((W, H), filt)
    q = small.quantize(colors=colors, method=Image.MEDIANCUT).convert("RGB")
    is_bg = util.make_bg_test(bg, bg_tol, chroma=chroma)
    palette: list[tuple[int, int, int]] = []
    idx: dict[tuple[int, int, int], int] = {}
    indices: list[int] = []
    sp = small.load()
    qp = q.load()
    for y in range(H):
        for x in range(W):
            if is_bg(sp[x, y]):
                indices.append(0)
                continue
            c = qp[x, y]
            slot = idx.get(c)
            if slot is None:
                if len(palette) >= 15:
                    # snap to nearest existing slot rather than overflow
                    slot = 1 + min(range(len(palette)),
                                   key=lambda i: sum((palette[i][k] - c[k]) ** 2 for k in range(3)))
                else:
                    palette.append(c)
                    slot = len(palette)
                    idx[c] = slot
            indices.append(slot)
    return bg, small, indices, palette


# ============================================================
# Multi-frame bake (animation)
# ============================================================

def bake_anim(frames: Sequence[str | Path],
              out: str | Path,
              name: str,
              *,
              size: tuple[int, int] = (32, 64),
              bg: tuple[int, int, int] | None = None,
              bg_tol: int = 40,
              bg_detect: str = "auto",
              colors: int = 15,
              margin: int = 2,
              chroma: bool = True,
              obj: bool = True,
              preview: bool = True,
              gif_ms: int = 110) -> dict:
    """Bake N frames to a single GBA 4bpp animation .inc.

    Shared-palette + common-canvas guarantees: every frame quantizes through the
    same <=15-color palette (no flicker), and every frame is cropped to the union
    bbox aspect-padded to target (no jitter).
    """
    out = Path(out)
    W, H = size
    paths = _expand_paths(frames)
    if not paths:
        raise ValueError("bake_anim: no frames matched")
    imgs = [Image.open(p).convert("RGB") for p in paths]

    bg_used = bg or util.detect_bg(imgs[0], method=bg_detect)
    is_bg = util.make_bg_test(bg_used, bg_tol, chroma=chroma)

    # 1. union bbox (threshold-based to ignore border noise)
    sw, sh = imgs[0].size
    U = [sw, sh, 0, 0]
    for im in imgs:
        box = util.subject_bbox(im, bg_used, bg_tol, chroma=chroma, thr_pct=0.02)
        if not box:
            continue
        x0, y0, x1, y1 = box
        U[0] = min(U[0], x0); U[1] = min(U[1], y0)
        U[2] = max(U[2], x1); U[3] = max(U[3], y1)
    if U[2] <= U[0] or U[3] <= U[1]:
        raise ValueError("bake_anim: no foreground pixels detected; bg_tol too high?")
    canvas = util.aspect_pad_box(tuple(U), imgs[0].size, (W, H), margin)

    smalls = [im.crop(canvas).resize((W, H), Image.NEAREST) for im in imgs]

    rec = _quantize_and_pack(
        smalls, W, H, name, out,
        bg_used=bg_used, is_bg=is_bg,
        colors=colors, obj=obj,
        source_note=f"{len(smalls)} frames from {paths[0].parent.name}; "
                    f"{{n_colors}} colors shared palette",
        extra_const=None,
        preview=preview, gif_ms=gif_ms,
        op_name="bake_anim")
    rec["infile"] = [str(p) for p in paths]
    rec["canvas"] = list(canvas)
    return rec


# ============================================================
# Nine-slice bake (UI panel chrome)
# ============================================================

def bake_nine_slice(infile: str | Path,
                    out: str | Path,
                    name: str,
                    *,
                    cell_size: tuple[int, int] = (8, 8),
                    bg: tuple[int, int, int] | None = None,
                    bg_tol: int = 30,
                    bg_detect: str = "auto",
                    colors: int = 15,
                    chroma: bool = True,
                    obj: bool = True,
                    preview: bool = True,
                    gif_ms: int = 0) -> dict:
    """Bake a 3x3 source image into a 9-tile nine-slice .inc for UI panel chrome.

    The source is divided into a 3x3 grid of equal-size cells. Each cell is
    downscaled to `cell_size` (e.g. 8x8) and baked into the same .inc as a
    separate tile, sharing one <=15-color palette across all 9 tiles. Cells
    are emitted in reading order (row-major):

        0: TL  1: T   2: TR
        3: L   4: C   5: R
        6: BL  7: B   8: BR

    The UI renderer composes arbitrary-sized panel chrome by cherry-picking
    these 9 tiles. The .inc carries slicing constants `<NAME>_NS_TL`...`_NS_BR`
    (values 0..8) so the consumer can address tiles by slice position name
    rather than hard-coding indices.

    Args:
      infile:      source image (a 3x3-layout panel, ideally square; the
                   exact split is `W // 3` by `H // 3`).
      cell_size:   per-cell target tile size (default 8x8 -- the GBA UI
                   convention; 16x16 also common for thicker chrome).
      bg/bg_tol/bg_detect/chroma:  same semantics as bake_single.
      obj=True:    OBJ tile order (default; pass linear=False CLI for BG-tile
                   layout if the UI ships on the BG layer instead of OBJ).
    """
    cw, ch = cell_size
    im = Image.open(infile).convert("RGB")
    sw, sh = im.size
    csw, csh = sw // 3, sh // 3
    if csw == 0 or csh == 0:
        raise ValueError(
            f"bake_nine_slice: source {sw}x{sh} too small for 3x3 split")
    bg_used = bg or util.detect_bg(im, method=bg_detect)
    is_bg = util.make_bg_test(bg_used, bg_tol, chroma=chroma)
    smalls: list[Image.Image] = []
    for row in range(3):
        for col in range(3):
            box = (col * csw, row * csh, (col + 1) * csw, (row + 1) * csh)
            cell = im.crop(box).resize((cw, ch), Image.NEAREST)
            smalls.append(cell)
    extra = {
        "NS_TL": 0, "NS_T": 1, "NS_TR": 2,
        "NS_L": 3,  "NS_C": 4, "NS_R": 5,
        "NS_BL": 6, "NS_B": 7, "NS_BR": 8,
    }
    rec = _quantize_and_pack(
        smalls, cw, ch, name, Path(out),
        bg_used=bg_used, is_bg=is_bg,
        colors=colors, obj=obj,
        source_note=f"nine-slice from {Path(infile).name}; 9 cells x {cw}x{ch}; "
                    f"row-major TL..BR",
        extra_const=extra,
        preview=preview, gif_ms=gif_ms,
        op_name="bake_nine_slice")
    rec["infile"] = str(infile)
    rec["source_grid"] = [3, 3]
    rec["cell_size"] = [cw, ch]
    rec["slice_index"] = extra
    return rec


# ============================================================
# Font-sheet ingestion (existing pixel fonts -> GBA glyph bank)
# ============================================================

def bake_font_sheet(infile: str | Path,
                    out: str | Path,
                    name: str,
                    *,
                    grid: tuple[int, int],
                    glyph_size: tuple[int, int] = (8, 8),
                    start_codepoint: int = 0x20,
                    end_codepoint: int | None = None,
                    bg: tuple[int, int, int] | None = None,
                    bg_tol: int = 30,
                    bg_detect: str = "auto",
                    colors: int = 3,
                    chroma: bool = True,
                    obj: bool = True,
                    preview: bool = True) -> dict:
    """Ingest an EXISTING pixel-font sheet and emit a GBA-baked glyph bank.

    AI font generation is a deliberate non-goal of this pipeline -- existing
    free pixel fonts (Pixel Operator, Press Start 2P, FCEUX 6x8, etc.) ship at
    higher fidelity than the diffusion model produces, and glyph count /
    ordering reliability is the killer constraint AI gen cannot meet. This
    utility is the canonical replacement: take a sheet, slice it, bake it.

    Sheet convention: a `cols x rows` regular grid; each cell is one glyph.
    Source per-cell pixels: `sheet.width // cols` by `sheet.height // rows`.
    Each cell is nearest-neighbor downscaled to `glyph_size`.

    Codepoint -> tile lookup at the consumer side:
        tile_index = codepoint - <NAME>_GLYPH_START
    if codepoint is in [GLYPH_START, GLYPH_END], else fall back to a marker
    glyph (e.g. '?' at 0x3F) chosen by the consumer.

    Args:
      infile:           font-sheet image path.
      grid:             (cols, rows) -- number of glyph cells across/down.
      glyph_size:       target (W, H) per glyph (default 8x8 -- GBA convention).
      start_codepoint:  ASCII codepoint of the FIRST glyph in reading order
                        (default 0x20 = space; pass 0x00 for full-table fonts).
      end_codepoint:    OPTIONAL explicit end; defaults to start + cols*rows - 1.
      bg/bg_tol/bg_detect/chroma:  bg detection (most font sheets are black-on-
                        white or white-on-black; defaults work for both).
      colors:           shared palette size (default 3: transparent + fg +
                        anti-alias/outline. Pure monochrome fonts use 2).
    """
    cols, rows = grid
    if cols < 1 or rows < 1:
        raise ValueError(f"bake_font_sheet: bad grid {grid!r}; expect (cols, rows) >= (1, 1)")
    gw, gh = glyph_size
    im = Image.open(infile).convert("RGB")
    sw, sh = im.size
    csw, csh = sw // cols, sh // rows
    if csw == 0 or csh == 0:
        raise ValueError(
            f"bake_font_sheet: source {sw}x{sh} too small for {cols}x{rows} grid")
    bg_used = bg or util.detect_bg(im, method=bg_detect)
    is_bg = util.make_bg_test(bg_used, bg_tol, chroma=chroma)
    smalls: list[Image.Image] = []
    for row in range(rows):
        for col in range(cols):
            box = (col * csw, row * csh, (col + 1) * csw, (row + 1) * csh)
            cell = im.crop(box).resize((gw, gh), Image.NEAREST)
            smalls.append(cell)
    n_glyphs = cols * rows
    end_cp = end_codepoint if end_codepoint is not None else (start_codepoint + n_glyphs - 1)
    extra = {
        "GLYPH_START": start_codepoint,
        "GLYPH_END": end_cp,
        "GLYPH_COUNT": n_glyphs,
        "GLYPH_COLS": cols,
        "GLYPH_ROWS": rows,
    }
    rec = _quantize_and_pack(
        smalls, gw, gh, name, Path(out),
        bg_used=bg_used, is_bg=is_bg,
        colors=colors, obj=obj,
        source_note=(f"font sheet from {Path(infile).name}; {cols}x{rows} grid; "
                     f"glyphs {start_codepoint:#x}..{end_cp:#x} ({n_glyphs} total) "
                     f"at {gw}x{gh}"),
        extra_const=extra,
        preview=preview, gif_ms=0,  # fonts are static; no animated preview
        op_name="bake_font_sheet")
    rec["infile"] = str(infile)
    rec["grid"] = [cols, rows]
    rec["glyph_size"] = [gw, gh]
    rec["start_codepoint"] = start_codepoint
    rec["end_codepoint"] = end_cp
    rec["glyph_count"] = n_glyphs
    return rec


def _quantize_and_pack(smalls: list[Image.Image], W: int, H: int, name: str,
                       out: Path,
                       *,
                       bg_used: tuple[int, int, int],
                       is_bg,
                       colors: int,
                       obj: bool,
                       source_note: str,
                       extra_const: dict[str, int] | None,
                       preview: bool,
                       gif_ms: int,
                       op_name: str) -> dict:
    """Shared body: shared-palette quantize + per-frame index + pack + emit + preview.

    `smalls` are PIL.Image instances ALREADY downscaled to (W, H). `bg_used`
    and `is_bg` are detected/built by the caller. Returns the record dict
    that callers extend with op-specific fields (infile, canvas, etc.).
    """
    # 1. shared palette over NON-bg pixels.
    fg_pixels: list[tuple[int, int, int]] = []
    for s in smalls:
        for c in s.getdata():
            if not is_bg(c):
                fg_pixels.append(c)
    if not fg_pixels:
        raise ValueError(f"{op_name}: no foreground pixels after canvas/cell crop")
    pal_strip = Image.new("RGB", (len(fg_pixels), 1))
    pal_strip.putdata(fg_pixels)
    qstrip = pal_strip.quantize(colors=colors, method=Image.MEDIANCUT).convert("RGB")
    palette: list[tuple[int, int, int]] = []
    idx: dict[tuple[int, int, int], int] = {}
    for c in qstrip.getdata():
        if c not in idx and len(palette) < 15:
            palette.append(c)
            idx[c] = len(palette)

    def map_color(c: tuple[int, int, int]) -> int:
        slot = idx.get(c)
        if slot is not None:
            return slot
        return 1 + min(range(len(palette)),
                       key=lambda i: sum((palette[i][k] - c[k]) ** 2 for k in range(3)))

    # 2. bake each frame to indices in the shared palette.
    frames_indices: list[list[int]] = []
    for s in smalls:
        out_idx: list[int] = []
        sp = s.load()
        for y in range(H):
            for x in range(W):
                c = sp[x, y]
                out_idx.append(0 if is_bg(c) else map_color(c))
        frames_indices.append(out_idx)

    # 3. pack tile bytes (per-frame; OBJ-mode reorders within each frame).
    all_bytes: list[int] = []
    for fi in frames_indices:
        all_bytes.extend(util.pack_4bpp_obj(fi, W, H) if obj
                         else util.pack_4bpp_linear(fi))

    util.emit_inc(out, name, W, H, palette, all_bytes,
                  frames=len(frames_indices), obj_order=obj,
                  include_transparent=True,
                  source_note=source_note.format(n_colors=len(palette)) if "{n_colors}" in source_note else source_note,
                  extra_const=extra_const)

    rec: dict = {
        "op": op_name,
        "out": str(out),
        "name": name,
        "size": [W, H],
        "frames": len(frames_indices),
        "colors_used": len(palette),
        "obj_order": obj,
        "bg": list(bg_used),
        "preview_strip": None,
        "preview_gif": None,
        "preview_zoom_gif": None,
    }
    if preview:
        strip = _write_preview_strip(frames_indices, W, H, palette, out, scale=6)
        rec["preview_strip"] = str(strip)
        if gif_ms > 0:
            gif = _write_preview_gif(frames_indices, W, H, palette, out, gif_ms)
            rec["preview_gif"] = str(gif)
            zoom = _write_zoom_gif(frames_indices, W, H, palette, out, gif_ms)
            rec["preview_zoom_gif"] = str(zoom)
    return rec


# ============================================================
# Preview emitters (shared)
# ============================================================

TRANSP_PREVIEW = (60, 60, 60)


def _frame_image(indices: list[int], W: int, H: int,
                 palette: list[tuple[int, int, int]]) -> Image.Image:
    data = [TRANSP_PREVIEW if v == 0 else palette[v - 1] for v in indices]
    im = Image.new("RGB", (W, H))
    im.putdata(data)
    return im


def _write_preview_strip(frames_indices: list[list[int]], W: int, H: int,
                         palette: list[tuple[int, int, int]],
                         out_inc: Path, scale: int = 6) -> Path:
    """Side-by-side strip preview at upscale; .strip.png alongside the .inc."""
    N = len(frames_indices)
    imgs = [_frame_image(fi, W, H, palette) for fi in frames_indices]
    strip = Image.new("RGB", (W * N, H))
    for i, im in enumerate(imgs):
        strip.paste(im, (i * W, 0))
    out_path = out_inc.with_suffix(out_inc.suffix + ".strip.png")
    strip.resize((W * N * scale, H * scale), Image.NEAREST).save(out_path)
    return out_path


# GBA screen dimensions: 240x160. Validation GIFs render at this scale so the
# operator/agent sees the sprite at its actual on-screen footprint, not zoomed
# in isolation. The whole composition is NN-upscaled by SCREEN_GIF_SCALE for
# viewability while keeping ratios true.
GBA_SCREEN_W = 240
GBA_SCREEN_H = 160
SCREEN_GIF_SCALE = 3                # 720x480 final -- viewable but truthful
SCREEN_GIF_BACKDROP = (33, 49, 49)  # matches sprite_smoke.pas backdrop for parity


def _save_gif(frames: list[Image.Image], out_path: Path, gif_ms: int) -> Path:
    """Save a looping GIF. Windows-Photos-friendly settings:
    - no `disposal` flag (Windows Photos refuses to loop disposal=2 GIFs).
    - `loop=0` for infinite loop.
    - frames quantized to a shared adaptive palette so per-frame quantize doesn't
      create flicker between frames in the saved GIF.
    """
    if not frames:
        raise ValueError("_save_gif: no frames")
    # Build a shared palette from all frames pooled, so the GIF stream uses ONE
    # global color table -- avoids the "static-looking" effect where PIL gives
    # each frame its own slightly-different palette and disposal flags eat the
    # actual motion. We do this by horizontally stacking the frames, quantizing
    # the stack to 255 colors, then splitting back.
    W, H = frames[0].size
    stack = Image.new("RGB", (W * len(frames), H))
    for i, f in enumerate(frames):
        stack.paste(f, (i * W, 0))
    q_stack = stack.quantize(colors=255, method=Image.MEDIANCUT, dither=Image.NONE)
    q_frames = [q_stack.crop((i * W, 0, (i + 1) * W, H)) for i in range(len(frames))]
    q_frames[0].save(out_path, save_all=True, append_images=q_frames[1:],
                     duration=gif_ms, loop=0, optimize=False)
    return out_path


def _write_preview_gif(frames_indices: list[list[int]], W: int, H: int,
                       palette: list[tuple[int, int, int]],
                       out_inc: Path, gif_ms: int) -> Path:
    """Looping GIF at GBA on-screen scale: 240x160 backdrop + sprite at TRUE size,
    whole composition NN-upscaled (default 3x -> 720x480). Tells the operator
    what the sprite will actually look like in-game, not what it looks like
    zoomed into isolation. (For zoomed-isolation, see _write_zoom_gif companion.)
    """
    sprite_imgs = [_frame_image(fi, W, H, palette) for fi in frames_indices]
    sx = (GBA_SCREEN_W - W) // 2
    sy = (GBA_SCREEN_H - H) // 2
    target_w = GBA_SCREEN_W * SCREEN_GIF_SCALE
    target_h = GBA_SCREEN_H * SCREEN_GIF_SCALE
    gif_frames: list[Image.Image] = []
    for i, sprite in enumerate(sprite_imgs):
        canvas = Image.new("RGB", (GBA_SCREEN_W, GBA_SCREEN_H), SCREEN_GIF_BACKDROP)
        idx = frames_indices[i]
        mask = Image.new("L", (W, H))
        mask.putdata([0 if v == 0 else 255 for v in idx])
        canvas.paste(sprite, (sx, sy), mask)
        gif_frames.append(canvas.resize((target_w, target_h), Image.NEAREST))
    out_path = out_inc.with_suffix(out_inc.suffix + ".gif")
    return _save_gif(gif_frames, out_path, gif_ms)


def _write_zoom_gif(frames_indices: list[list[int]], W: int, H: int,
                    palette: list[tuple[int, int, int]],
                    out_inc: Path, gif_ms: int) -> Path:
    """Looping GIF, sprite-only, NN-upscaled large (~192-256 px max side). On the
    sprite_smoke backdrop. Motion-obvious view -- the companion to the
    screen-scale .gif. Saves to <inc>.zoom.gif.
    """
    sprite_imgs = [_frame_image(fi, W, H, palette) for fi in frames_indices]
    zoom = max(1, 240 // max(W, H))
    target_w = W * zoom
    target_h = H * zoom
    gif_frames: list[Image.Image] = []
    for i, sprite in enumerate(sprite_imgs):
        # backdrop matches screen-gif for visual continuity
        canvas = Image.new("RGB", (W, H), SCREEN_GIF_BACKDROP)
        idx = frames_indices[i]
        mask = Image.new("L", (W, H))
        mask.putdata([0 if v == 0 else 255 for v in idx])
        canvas.paste(sprite, (0, 0), mask)
        gif_frames.append(canvas.resize((target_w, target_h), Image.NEAREST))
    out_path = out_inc.with_suffix(out_inc.suffix + ".zoom.gif")
    return _save_gif(gif_frames, out_path, gif_ms)


# ============================================================
# Small helpers
# ============================================================

def _expand_paths(frames: Sequence[str | Path]) -> list[Path]:
    """Glob each entry; preserve order; sort each glob result."""
    out: list[Path] = []
    for f in frames:
        s = str(f)
        if any(c in s for c in "*?["):
            out.extend(Path(p) for p in sorted(glob.glob(s)))
        else:
            out.append(Path(s))
    return out
