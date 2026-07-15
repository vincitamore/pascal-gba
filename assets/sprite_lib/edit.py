"""sprite_lib.edit -- programmatic editing of sprites without manual pixel work.

Four capabilities, all returning JSON-friendly records the CLI can pass through:

  variant(refs, prompt, out)
      Reference-based generation via /v1/images/edits. The coherence engine for
      deriving the rest of a roster from one canonical unit: pose variants, attack
      frames, weapon swaps, faction-recolors via reference + 'red faction palette'
      prompt etc. Up to 3 refs.

  recolor(inc, map, out, name)
      Palette-swap in a baked .inc -- no pixel work, just rewriting the BGR555
      words. Cheapest possible faction-recolor when the silhouette stays identical.

  rekey(png, new_bg, old_bg, tol, out)
      Replace the chroma-key background with another solid color (or transparent
      pixels via near-white). Used to standardize sources from different prompt
      variants before feeding through the baker.

  sheet(incs, out, name, cols=)
      Assemble multiple baked sprites into a single tile bank + per-OBJ metadata
      table the game can use to spawn each unit. Keeps frame counts AND per-unit
      palettes intact (each unit references its own palette bank slot).
"""
from __future__ import annotations
from pathlib import Path
from typing import Sequence

from PIL import Image

from . import util, review, xai


# ============================================================
# 1. Reference-based variant (the coherence engine)
# ============================================================

def variant(refs: Sequence[str | Path],
            prompt: str,
            out: str | Path,
            *,
            client: xai.XaiClient | None = None,
            resolution: str = "1k",
            aspect_ratio: str = "1:1",
            no_cache: bool = False) -> dict:
    """Generate a variant of `refs[0]` guided by `prompt`. Returns the xai.edit_image record.

    Typical use:
        variant(['canonical_daemon.jpg'],
                'same character but attacking pose, sword raised',
                'attack_pose.jpg')

    For roster derivation, see sprite_lib.xai.sprite_prompt to build the prompt
    with pinned colors so the reference identity is preserved.
    """
    c = client or xai.XaiClient()
    return c.edit_image(prompt, refs, out,
                        resolution=resolution,
                        aspect_ratio=aspect_ratio,
                        no_cache=no_cache)


# ============================================================
# 2. Palette swap (recolor without pixel work)
# ============================================================

def recolor(inc_path: str | Path,
            out: str | Path,
            color_map: dict[int, tuple[int, int, int]],
            *,
            name: str | None = None) -> dict:
    """Rewrite specific palette slots in a baked .inc.

    `color_map` is { slot_index -> new_rgb }. Slot 0 is the transparent index; do
    NOT remap it (skipped if present). The tile bytes are copied verbatim -- only
    the palette words change. This is the cheapest possible faction recolor.

    Use review.inspect first to see which slots carry which roles in the sprite.
    """
    parsed = review._parse_inc(Path(inc_path).read_text())
    if name is None:
        name = parsed["name"]
    new_pal = list(parsed["palette_rgb"])
    for slot, rgb in color_map.items():
        if slot < 0 or slot >= len(new_pal):
            raise ValueError(f"palette slot {slot} out of range (have {len(new_pal)})")
        if slot == 0:
            continue  # transparent stays $0000
        new_pal[slot] = rgb
    # write back -- emit_inc expects the visible palette only (slot 0 prepended by it)
    visible = new_pal[1:]
    util.emit_inc(out, name, parsed["W"], parsed["H"], visible,
                  parsed["bytes"], frames=parsed["frames"],
                  obj_order=parsed["obj_order"],
                  include_transparent=True,
                  source_note=f"recolor of {Path(inc_path).name}; {len(color_map)} slot(s) remapped")
    return {"op": "recolor", "in": str(inc_path), "out": str(out),
            "name": name, "remapped_slots": sorted(color_map.keys()),
            "frames": parsed["frames"], "size": [parsed["W"], parsed["H"]],
            "obj_order": parsed["obj_order"]}


# ============================================================
# 3. Background re-key
# ============================================================

def rekey(infile: str | Path,
          out: str | Path,
          *,
          old_bg: tuple[int, int, int] | None = None,
          new_bg: tuple[int, int, int] = (255, 0, 255),
          tol: int = 40,
          bg_detect: str = "auto",
          chroma: bool = True) -> dict:
    """Swap the background of `infile` from `old_bg` (auto-detect modal if None) to `new_bg`.

    Useful when refining a prompt revision against a reference that used a different
    key color, OR to standardize sources before baking. The chroma test catches
    magenta vignettes the model emits; set chroma=False for non-magenta sources.
    """
    im = Image.open(infile).convert("RGB")
    if old_bg is None:
        old_bg = util.detect_bg(im, method=bg_detect)
    is_bg = util.make_bg_test(old_bg, tol, chroma=chroma)
    out_im = Image.new("RGB", im.size)
    dst = out_im.load()
    src = im.load()
    W, H = im.size
    replaced = 0
    for y in range(H):
        for x in range(W):
            c = src[x, y]
            if is_bg(c):
                dst[x, y] = new_bg
                replaced += 1
            else:
                dst[x, y] = c
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out_im.save(out)
    return {"op": "rekey", "in": str(infile), "out": str(out),
            "old_bg": list(old_bg), "new_bg": list(new_bg),
            "tol": tol, "chroma": chroma,
            "replaced_px": replaced, "total_px": W * H}


# ============================================================
# 4. Sheet assembly
# ============================================================

def sheet(inc_paths: Sequence[str | Path],
          out: str | Path,
          name: str,
          *,
          cols: int = 0) -> dict:
    """Concatenate N baked sprites into one .inc with a per-unit metadata table.

    Output schema:
      const <NAME>_UNITS = N;
            <NAME>_PAL_SIZE = 16;             (each unit's palette occupies 16 words)
      <NAME>_UNIT_W:        array[0..N-1] of Byte = ( w0, w1, ..., );
      <NAME>_UNIT_H:        array[0..N-1] of Byte = ( h0, h1, ..., );
      <NAME>_UNIT_FRAMES:   array[0..N-1] of Byte = ( f0, f1, ..., );
      <NAME>_UNIT_TILE_OFF: array[0..N-1] of Word = ( byte offsets into <NAME>_TILES );
      <NAME>_UNIT_PAL_OFF:  array[0..N-1] of Word = ( word offsets into <NAME>_PAL );
      <NAME>_PAL: array[0..N*16-1] of Word = ( unit-0 palette, unit-1 palette, ... );
      <NAME>_TILES: array[0..total-1] of Byte = ( unit-0 tiles, unit-1 tiles, ... );

    Each unit's palette occupies a 16-word stride (slot 0 = $0000 transparent +
    15 visible). All unit tile data shares ORDER: ALL units must use the same
    obj_order (we assert it).
    """
    paths = [Path(p) for p in inc_paths]
    parsed = [review._parse_inc(p.read_text()) for p in paths]
    if not parsed:
        raise ValueError("sheet: no inputs")
    orders = {p["obj_order"] for p in parsed}
    if len(orders) > 1:
        raise ValueError("sheet: all units must share obj_order (mixed input)")
    order = parsed[0]["obj_order"]

    pal_words: list[int] = []
    pal_offsets: list[int] = []
    tile_bytes: list[int] = []
    tile_offsets: list[int] = []
    unit_w, unit_h, unit_frames = [], [], []
    for p in parsed:
        pal_offsets.append(len(pal_words))
        # write slot 0 transparent + 15 visible (pad with zeros if fewer)
        pal_words.append(0x0000)
        for c in p["palette_rgb"][1:]:
            pal_words.append(util.bgr555(c))
        while len(pal_words) - pal_offsets[-1] < 16:
            pal_words.append(0x0000)
        tile_offsets.append(len(tile_bytes))
        tile_bytes.extend(p["bytes"])
        unit_w.append(p["W"])
        unit_h.append(p["H"])
        unit_frames.append(p["frames"])

    n = len(parsed)
    out = Path(out)
    L: list[str] = []
    L.append(f"{{ sprite sheet: {n} units; obj_order={1 if order else 0} }}")
    L.append(f"const {name}_UNITS = {n};")
    L.append(f"  {name}_PAL_SIZE = 16;")
    L.append(f"  {name}_OBJ_ORDER = {1 if order else 0};")

    def emit_byte_arr(label: str, arr: list[int]):
        L.append(f"  {name}_{label}: array[0..{len(arr) - 1}] of Byte = (")
        rows = [", ".join(f"${b:02X}" for b in arr[i:i + 16]) for i in range(0, len(arr), 16)]
        L.append("    " + ",\n    ".join(rows) + ");")

    def emit_word_arr(label: str, arr: list[int]):
        L.append(f"  {name}_{label}: array[0..{len(arr) - 1}] of Word = (")
        rows = [", ".join(f"${b:04X}" for b in arr[i:i + 12]) for i in range(0, len(arr), 12)]
        L.append("    " + ",\n    ".join(rows) + ");")

    emit_byte_arr("UNIT_W", unit_w)
    emit_byte_arr("UNIT_H", unit_h)
    emit_byte_arr("UNIT_FRAMES", unit_frames)
    emit_word_arr("UNIT_TILE_OFF", tile_offsets)
    emit_word_arr("UNIT_PAL_OFF", pal_offsets)
    emit_word_arr("PAL", pal_words)
    emit_byte_arr("TILES", tile_bytes)

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(L) + "\n")
    return {"op": "sheet", "out": str(out), "name": name,
            "units": n, "obj_order": order,
            "tile_bytes": len(tile_bytes), "pal_words": len(pal_words),
            "per_unit": [{"src": str(p), "W": p2["W"], "H": p2["H"],
                          "frames": p2["frames"], "tile_off": tile_offsets[i],
                          "pal_off": pal_offsets[i]}
                         for i, (p, p2) in enumerate(zip(paths, parsed))]}
