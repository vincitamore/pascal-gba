"""sprite_lib.bgbake -- full-image BG bake: tiles + tilemap + palette(s).

Covers the text-BG (mode 0-1) asset path: a full image becomes a deduplicated
8x8 tile set, a row-major tilemap whose entries carry the hardware flip and
palette-bank bits, and one or more 16-color palette banks.

Two palette models, selected by `palettes`:

  palettes=1  (default)  One shared <=15-color palette for the whole image.
                         Cheap and fine for images with one coherent color
                         region. Output format matches the original bg-bake.

  palettes=N  (2..16)    Tiles are clustered into up to N palette banks, each
                         quantized independently to <=15 colors. This is the
                         fix for region bleed: a night sky and a gold banner
                         stop competing for the same 15 slots. Map entries
                         carry the bank in bits 12-15 (mode-0 native; the
                         hardware applies it per tile for free). The palette
                         array is emitted as N contiguous 16-slot banks
                         (slot 0 of each bank is $0000 -- in 4bpp text modes
                         pixel index 0 always shows the backdrop), so a
                         loader copies the whole array straight into BG
                         palette RAM.

Bank assignment is a greedy set-cover: tiles are reduced to their color sets,
processed largest-first, and each set lands in the bank that absorbs it with
the fewest new colors (never exceeding the per-bank budget). When every bank
is full and none can absorb a set, the set is force-merged into the closest
bank and that bank is re-quantized at the end -- the bake degrades gracefully
instead of failing, and reports how many tiles took that path.

Tile dedup is bank-agnostic by construction: tile data holds palette indices,
the map entry holds the bank, so two tiles with the same index pattern share
storage even across different banks.
"""
from __future__ import annotations
from pathlib import Path

from PIL import Image

from . import util


def _flip_tile(t: list[int], hf: bool, vf: bool) -> list[int]:
    out_t = []
    for y in range(8):
        sy = 7 - y if vf else y
        for x in range(8):
            sx = 7 - x if hf else x
            out_t.append(t[sy * 8 + sx])
    return out_t


def bake_bg(infile: str | Path,
            out: str | Path,
            name: str,
            *,
            colors: int = 15,
            palettes: int = 1,
            dedup_flips: bool = True,
            preview: bool = True) -> dict:
    """Full-image BG bake: image -> deduplicated 8x8 tile set + tilemap +
    palette bank(s), as one .inc.

    `colors` is the per-bank opaque-color budget (1..15; slot 0 of every
    bank stays $0000 -- in 4bpp text BG modes pixel index 0 always shows
    the backdrop, so opaque art must not use it). `palettes` selects the
    palette model (see module docstring). Tiles are deduplicated exactly,
    and -- with `dedup_flips` -- against their horizontal/vertical/both
    mirrors, encoded into the map entry flip bits.

    Map entries are emitted row-major at MAP_W x MAP_H (image tiles, not
    the 32x32 screenblock): the cart-side loader lays rows into the
    screenblock stride. Tile indices must fit the 10-bit map field; a
    busy image that dedups to more than 1024 tiles is an error (crop,
    simplify, or split it).
    """
    infile = Path(infile)
    im = Image.open(infile).convert("RGB")
    W, H = im.size
    if W % 8 or H % 8:
        raise ValueError(f"bg-bake: image must be a multiple of 8 in both axes, got {W}x{H}")
    if not 1 <= colors <= 15:
        raise ValueError("bg-bake: --colors must be 1..15 (slot 0 is the backdrop)")
    if not 1 <= palettes <= 16:
        raise ValueError("bg-bake: --palettes must be 1..16 (hardware has 16 BG banks)")

    tiles_w, tiles_h = W // 8, H // 8

    if palettes == 1:
        bank_pals, tile_bank, tile_pixels, degraded = _single_palette(im, colors, tiles_w, tiles_h)
    else:
        bank_pals, tile_bank, tile_pixels, degraded = _multi_palette(im, colors, palettes,
                                                                     tiles_w, tiles_h)

    # ---- index tiles, dedup (bank-agnostic: data = indices, map = bank) ----
    indexers = [_make_indexer(p) for p in bank_pals]
    tiles: list[list[int]] = []
    seen: dict[tuple[int, ...], tuple[int, int, int]] = {}
    map_words: list[int] = []
    for i, tp in enumerate(tile_pixels):
        bank = tile_bank[i]
        f = indexers[bank]
        t = [f(c) for c in tp]
        hit = seen.get(tuple(t))
        if hit is None:
            ti = len(tiles)
            tiles.append(t)
            # Register the stored tile under every orientation the map
            # entry can reconstruct. Identity goes first so an exact
            # repeat prefers flip-free entries.
            orientations = [(False, False)]
            if dedup_flips:
                orientations += [(True, False), (False, True), (True, True)]
            for hf, vf in orientations:
                seen.setdefault(tuple(_flip_tile(t, hf, vf)), (ti, int(hf), int(vf)))
            hit = (ti, 0, 0)
        ti, hf, vf = hit
        map_words.append(ti | (hf << 10) | (vf << 11) | (bank << 12))

    if len(tiles) > 1024:
        raise ValueError(f"bg-bake: {len(tiles)} unique tiles exceed the 10-bit "
                         f"map field (1024); simplify or split the image")

    tile_bytes: list[int] = []
    for t in tiles:
        tile_bytes.extend(util.pack_4bpp_linear(t))

    # ---- palette emission ----
    # Single-bank: the historical compact form (1 + n_colors entries).
    # Multi-bank: N contiguous 16-slot banks so the loader can copy the
    # whole array to BG palette RAM and bank offsets line up in hardware.
    n_banks = len(bank_pals)
    if n_banks == 1:
        flat_pal = list(bank_pals[0])
    else:
        flat_pal = []
        for bi, pal in enumerate(bank_pals):
            if bi > 0:
                flat_pal.append((0, 0, 0))       # slot 0 of banks 1..N-1
            flat_pal.extend(pal)
            flat_pal.extend([(0, 0, 0)] * (15 - len(pal)))

    out = Path(out)
    util.emit_inc(out, name, W, H, flat_pal, tile_bytes,
                  frames=1, obj_order=False, include_transparent=True,
                  source_note=f"bg-bake of {infile.name}: {len(tiles)} tiles, "
                              f"{n_banks} palette bank(s)",
                  extra_const={"MAP_W": tiles_w, "MAP_H": tiles_h,
                               "TILE_COUNT": len(tiles),
                               "PAL_BANKS": n_banks},
                  map_words=map_words)

    rec: dict = {
        "op": "bg-bake",
        "infile": str(infile),
        "out": str(out),
        "name": name,
        "size": [W, H],
        "map": [tiles_w, tiles_h],
        "tiles_unique": len(tiles),
        "tiles_total": tiles_w * tiles_h,
        "dedup_flips": dedup_flips,
        "palettes": n_banks,
        "bank_sizes": [len(p) for p in bank_pals],
        "colors_used": sum(len(p) for p in bank_pals),
        "tiles_degraded": degraded,
        "preview": None,
    }
    if preview:
        # Round-trip render from the emitted data model (tiles + map + banks),
        # proving the bake reconstructs the image the cart will show.
        pv = Image.new("RGB", (W, H))
        pp = pv.load()
        for my in range(tiles_h):
            for mx in range(tiles_w):
                entry = map_words[my * tiles_w + mx]
                t = tiles[entry & 0x3FF]
                hf, vf = bool(entry & 0x400), bool(entry & 0x800)
                bank = (entry >> 12) & 0xF
                pal = bank_pals[bank]
                shown = _flip_tile(t, hf, vf)
                for y in range(8):
                    for x in range(8):
                        s = shown[y * 8 + x]
                        pp[mx * 8 + x, my * 8 + y] = (0, 0, 0) if s == 0 else pal[s - 1]
        pv_path = out.with_suffix(".preview.png")
        pv.save(pv_path)
        rec["preview"] = str(pv_path)
    return rec


# ============================================================
# Palette models
# ============================================================

def _single_palette(im: Image.Image, colors: int, tiles_w: int, tiles_h: int):
    """One shared palette: whole-image quantize, first-seen slot order."""
    q = im.quantize(colors=colors, method=Image.MEDIANCUT).convert("RGB")
    palette: list[tuple[int, int, int]] = []
    have: set[tuple[int, int, int]] = set()
    for c in q.getdata():
        if c not in have and len(palette) < colors:
            have.add(c)
            palette.append(c)
    px = q.load()
    tile_pixels = _gather_tiles(px, tiles_w, tiles_h)
    return [palette], [0] * (tiles_w * tiles_h), tile_pixels, 0


def _multi_palette(im: Image.Image, colors: int, palettes: int,
                   tiles_w: int, tiles_h: int):
    """Cluster tiles into <= `palettes` banks, each <= `colors` colors.

    1. Whole-image quantize to palettes*colors (bounds the color universe
       while leaving each region room for its own shades).
    2. Any single tile still holding > `colors` distinct colors is reduced
       tile-locally first (rare: only very busy 8x8 cells).
    3. Greedy set-cover assigns tile color-sets to banks largest-first.
    4. A bank forced past its budget (all banks full, none could absorb)
       is re-quantized from its member tiles' pooled pixels; member tiles
       remap through nearest-color. `degraded` counts those tiles -- zero
       means the bake is pixel-exact by construction.
    """
    q = im.quantize(colors=min(255, palettes * colors),
                    method=Image.MEDIANCUT).convert("RGB")
    px = q.load()
    tile_pixels = _gather_tiles(px, tiles_w, tiles_h)

    # 2. tile-local reduce
    for i, tp in enumerate(tile_pixels):
        if len(set(tp)) > colors:
            strip = Image.new("RGB", (len(tp), 1))
            strip.putdata(tp)
            qs = strip.quantize(colors=colors, method=Image.MEDIANCUT).convert("RGB")
            tile_pixels[i] = list(qs.getdata())

    tile_sets = [frozenset(tp) for tp in tile_pixels]

    # 3. greedy assignment, largest sets first (deterministic order)
    banks: list[set[tuple[int, int, int]]] = []
    set_bank: dict[frozenset, int] = {}
    forced: set[int] = set()
    for S in sorted(set(tile_sets), key=lambda s: (-len(s), sorted(s))):
        best_bi = -1
        best_cost = None
        best_union = None
        for bi, B in enumerate(banks):
            u = len(B | S)
            if u <= colors:
                cost = u - len(B)
                if best_cost is None or (cost, u) < (best_cost, best_union):
                    best_bi, best_cost, best_union = bi, cost, u
        if best_bi >= 0:
            banks[best_bi] |= S
        elif len(banks) < palettes:
            banks.append(set(S))
            best_bi = len(banks) - 1
        else:
            best_bi = min(range(len(banks)), key=lambda bi: len(banks[bi] | S))
            banks[best_bi] |= S
            forced.add(best_bi)
        set_bank[S] = best_bi
    tile_bank = [set_bank[s] for s in tile_sets]

    # 4. final per-bank palettes (sorted for deterministic slot order)
    bank_pals: list[list[tuple[int, int, int]]] = []
    degraded = 0
    for bi, B in enumerate(banks):
        if len(B) <= colors:
            bank_pals.append(sorted(B))
        else:
            pool = [c for i, tp in enumerate(tile_pixels)
                    if tile_bank[i] == bi for c in tp]
            strip = Image.new("RGB", (len(pool), 1))
            strip.putdata(pool)
            qs = strip.quantize(colors=colors, method=Image.MEDIANCUT).convert("RGB")
            reduced: list[tuple[int, int, int]] = []
            have: set[tuple[int, int, int]] = set()
            for c in qs.getdata():
                if c not in have and len(reduced) < colors:
                    have.add(c)
                    reduced.append(c)
            bank_pals.append(sorted(reduced))
            degraded += sum(1 for b in tile_bank if b == bi)
    return bank_pals, tile_bank, tile_pixels, degraded


# ============================================================
# helpers
# ============================================================

def _gather_tiles(px, tiles_w: int, tiles_h: int) -> list[list[tuple[int, int, int]]]:
    """Row-major list of tiles, each a row-major list of 64 RGB tuples."""
    out: list[list[tuple[int, int, int]]] = []
    for ty in range(tiles_h):
        for tx in range(tiles_w):
            out.append([px[tx * 8 + x, ty * 8 + y]
                        for y in range(8) for x in range(8)])
    return out


def _make_indexer(pal: list[tuple[int, int, int]]):
    """Color -> 1-based slot in `pal`; exact hit else nearest (cached)."""
    lut = {c: k + 1 for k, c in enumerate(pal)}

    def f(c: tuple[int, int, int]) -> int:
        k = lut.get(c)
        if k is None:
            k = 1 + min(range(len(pal)),
                        key=lambda j: sum((pal[j][n] - c[n]) ** 2 for n in range(3)))
            lut[c] = k
        return k
    return f
