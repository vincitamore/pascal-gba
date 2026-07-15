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
            max_tiles: int | None = None,
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

    `max_tiles` vector-quantizes the tile set down to a budget before
    palette work -- the tool for ORGANIC sources (AI art, downsampled
    photos-of-pixel-art) whose texture noise makes nearly every 8x8 cell
    unique. Codebook selection is maximin (start from the most frequent
    tile, repeatedly add the tile farthest from the codebook), so
    distinctive one-off detail survives while near-duplicate noise
    clusters collapse onto one representative. The JSON record's
    `tiles_merged` counts remapped cells; pick the budget by eye against
    the round-trip preview.
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
    if max_tiles is not None and not 1 <= max_tiles <= 1024:
        raise ValueError("bg-bake: --max-tiles must be 1..1024")

    tiles_w, tiles_h = W // 8, H // 8

    if palettes == 1:
        bank_pals, tile_bank, tile_pixels, degraded = _single_palette(im, colors, tiles_w, tiles_h)
        merged = 0
        if max_tiles is not None:
            tile_pixels, merged = _tile_budget_reduce(tile_pixels, max_tiles)
        universe = colors
    else:
        universe = min(255, palettes * colors)
        q = im.quantize(colors=universe, method=Image.MEDIANCUT,
                        dither=Image.NONE).convert("RGB")
        tile_pixels = _gather_tiles(q.load(), tiles_w, tiles_h)
        merged = 0
        if max_tiles is not None:
            tile_pixels, merged = _tile_budget_reduce(tile_pixels, max_tiles)
        bank_pals, tile_bank, tile_pixels, degraded = _multi_palette_from_tiles(
            tile_pixels, colors, palettes)
        if degraded > max(1, len(tile_pixels) // 50):
            # Set-cover failed broadly (organic source: too many distinct
            # color-sets to pack). Re-bank by color-coherent clustering:
            # region-shaped banks, controlled per-region quantize. A few
            # snapped stragglers (<= 2%) keep the otherwise-exact greedy
            # result instead.
            bank_pals, tile_bank, degraded = _cluster_banks(
                tile_pixels, colors, palettes)

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
        "tiles_merged": merged,
        "color_universe": universe,
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
    q = im.quantize(colors=colors, method=Image.MEDIANCUT,
                    dither=Image.NONE).convert("RGB")
    palette: list[tuple[int, int, int]] = []
    have: set[tuple[int, int, int]] = set()
    for c in q.getdata():
        if c not in have and len(palette) < colors:
            have.add(c)
            palette.append(c)
    px = q.load()
    tile_pixels = _gather_tiles(px, tiles_w, tiles_h)
    return [palette], [0] * (tiles_w * tiles_h), tile_pixels, 0


def _multi_palette_from_tiles(tile_pixels, colors: int, palettes: int):
    """Cluster tiles into <= `palettes` banks, each <= `colors` colors.

    1. Any single tile holding > `colors` distinct colors is reduced
       tile-locally first (rare: only very busy 8x8 cells).
    2. Greedy set-cover assigns tile color-sets to banks largest-first;
       a set nothing can absorb opens a new bank while any remain.
    3. Banks never grow past budget. A set that fits no bank once all
       banks exist is SNAPPED: it renders through the bank where its
       colors have the smallest total nearest-color error. Snapping is
       local, controlled loss (region-boundary tiles blend into one
       neighborhood's palette); the returned `degraded` counts snapped
       tiles -- zero means pixel-exact by construction.
    """
    # 1. tile-local reduce: a tile over budget keeps its most frequent
    # colors and snaps the rest to the nearest kept one. Snapping (never
    # re-quantizing) matters: a quantizer would invent blended colors
    # per tile, silently exploding the whole image's color universe and
    # defeating bank packing.
    for i, tp in enumerate(tile_pixels):
        distinct = set(tp)
        if len(distinct) > colors:
            freq: dict[tuple[int, int, int], int] = {}
            for c in tp:
                freq[c] = freq.get(c, 0) + 1
            keep = sorted(freq, key=lambda c: (-freq[c], c))[:colors]
            keepset = set(keep)
            snap = {}
            for c in distinct:
                if c in keepset:
                    snap[c] = c
                else:
                    snap[c] = min(keep, key=lambda k: sum((k[m] - c[m]) ** 2
                                                          for m in range(3)))
            tile_pixels[i] = [snap[c] for c in tp]

    tile_sets = [frozenset(tp) for tp in tile_pixels]

    # 2. greedy assignment, largest sets first (deterministic order)
    banks: list[set[tuple[int, int, int]]] = []
    set_bank: dict[frozenset, int] = {}
    deferred: list = []
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
            deferred.append(S)
            continue
        set_bank[S] = best_bi

    # 3. snap the stragglers: cheapest-total-error bank, palette unchanged
    def snap_error(S, B) -> int:
        e = 0
        for c in S:
            if c not in B:
                e += min(sum((b[m] - c[m]) ** 2 for m in range(3)) for b in B)
        return e

    snapped_sets = set()
    for S in deferred:
        best_bi = min(range(len(banks)),
                      key=lambda bi: (snap_error(S, banks[bi]), bi))
        set_bank[S] = best_bi
        snapped_sets.add(S)

    tile_bank = [set_bank[s] for s in tile_sets]
    degraded = sum(1 for s in tile_sets if s in snapped_sets)

    # 4. final per-bank palettes (sorted for deterministic slot order).
    # Banks never exceed the budget; snapped tiles map through the
    # indexer's nearest-color fallback at tile-build time.
    bank_pals = [sorted(B) for B in banks]
    return bank_pals, tile_bank, tile_pixels, degraded


def _cluster_banks(tile_pixels, colors: int, palettes: int):
    """Region-coherent banking for organic sources.

    Tiles cluster by mean color (k-means, k = palettes, deterministic
    maximin init, fixed iteration count); each cluster's pooled pixels
    quantize to one <= `colors` bank. A sky bank stays sky shades, a
    grass bank grass shades -- loss lands within a region's own hues
    instead of crushing whoever overflowed a greedy bank. Returns
    (bank_pals, tile_bank, degraded) where degraded counts tiles
    holding any color not exactly in their bank.
    """
    n = len(tile_pixels)
    means: list[tuple[int, int, int]] = []
    for tp in tile_pixels:
        sr = sg = sb = 0
        for c in tp:
            sr += c[0]; sg += c[1]; sb += c[2]
        means.append((sr >> 6, sg >> 6, sb >> 6))

    def d3(a, b) -> int:
        return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2

    # maximin init over distinct means
    distinct = sorted(set(means))
    seed = distinct[0]
    centers = [seed]
    best = [d3(m, seed) for m in distinct]
    while len(centers) < min(palettes, len(distinct)):
        far = max(range(len(distinct)), key=lambda i: (best[i], -i))
        if best[far] == 0:
            break
        centers.append(distinct[far])
        for i, m in enumerate(distinct):
            d = d3(m, distinct[far])
            if d < best[i]:
                best[i] = d

    assign = [0] * n
    for _ in range(8):
        for i, m in enumerate(means):
            assign[i] = min(range(len(centers)), key=lambda k: (d3(m, centers[k]), k))
        sums = [[0, 0, 0, 0] for _ in centers]
        for i, m in enumerate(means):
            s = sums[assign[i]]
            s[0] += m[0]; s[1] += m[1]; s[2] += m[2]; s[3] += 1
        centers = [((s[0] // s[3]), (s[1] // s[3]), (s[2] // s[3])) if s[3] else c
                   for s, c in zip(sums, centers)]

    # drop empty clusters, renumber
    used = sorted(set(assign))
    renum = {k: i for i, k in enumerate(used)}
    tile_bank = [renum[k] for k in assign]

    bank_pals: list[list[tuple[int, int, int]]] = []
    for bi in range(len(used)):
        pool: list[tuple[int, int, int]] = []
        for i, tp in enumerate(tile_pixels):
            if tile_bank[i] == bi:
                pool.extend(tp)
        strip = Image.new("RGB", (len(pool), 1))
        strip.putdata(pool)
        qs = strip.quantize(colors=colors, method=Image.MEDIANCUT,
                            dither=Image.NONE).convert("RGB")
        pal: list[tuple[int, int, int]] = []
        have: set[tuple[int, int, int]] = set()
        for c in qs.getdata():
            if c not in have and len(pal) < colors:
                have.add(c)
                pal.append(c)
        bank_pals.append(sorted(pal))

    degraded = 0
    for i, tp in enumerate(tile_pixels):
        B = set(bank_pals[tile_bank[i]])
        if any(c not in B for c in set(tp)):
            degraded += 1
    return bank_pals, tile_bank, degraded


# ============================================================
# Tile-budget vector quantization
# ============================================================

def _tile_budget_reduce(tile_pixels, budget: int):
    """Reduce the tile set to <= `budget` distinct tiles.

    Exact duplicates collapse first. If still over budget, a codebook of
    `budget` tiles is chosen by maximin (seed with the most frequent
    tile, then repeatedly add the tile farthest from its nearest
    codebook entry -- outliers and one-off detail survive; noise
    clusters lose their variants). Every remaining tile snaps to its
    nearest codebook tile. Distances shortlist on coarse quadrant-mean
    features, then rank fine (full-pixel SSD) among the shortlist.

    Returns (new_tile_pixels, merged_count). Deterministic.
    """
    n = len(tile_pixels)
    uniq: dict[tuple, int] = {}
    uniq_tiles: list[list[tuple[int, int, int]]] = []
    counts: list[int] = []
    assign: list[int] = []
    for tp in tile_pixels:
        key = tuple(tp)
        k = uniq.get(key)
        if k is None:
            k = len(uniq_tiles)
            uniq[key] = k
            uniq_tiles.append(tp)
            counts.append(0)
        counts[k] += 1
        assign.append(k)
    if len(uniq_tiles) <= budget:
        return tile_pixels, 0

    def coarse(tp) -> list[int]:
        # mean RGB of each 4x4 quadrant: 12 dims
        f = []
        for qy in (0, 4):
            for qx in (0, 4):
                sr = sg = sb = 0
                for y in range(4):
                    for x in range(4):
                        c = tp[(qy + y) * 8 + (qx + x)]
                        sr += c[0]; sg += c[1]; sb += c[2]
                f.extend((sr >> 4, sg >> 4, sb >> 4))
        return f

    feats = [coarse(tp) for tp in uniq_tiles]

    def cdist(a: list[int], b: list[int]) -> int:
        return sum((a[i] - b[i]) ** 2 for i in range(12))

    def fdist(a, b) -> int:
        return sum((a[i][0] - b[i][0]) ** 2 + (a[i][1] - b[i][1]) ** 2 +
                   (a[i][2] - b[i][2]) ** 2 for i in range(64))

    # maximin codebook selection over coarse features
    seed = max(range(len(uniq_tiles)), key=lambda i: (counts[i], -i))
    codebook = [seed]
    best = [cdist(feats[i], feats[seed]) for i in range(len(uniq_tiles))]
    while len(codebook) < budget:
        far = max(range(len(uniq_tiles)), key=lambda i: (best[i], -i))
        if best[far] == 0:
            break
        codebook.append(far)
        ff = feats[far]
        for i in range(len(uniq_tiles)):
            d = cdist(feats[i], ff)
            if d < best[i]:
                best[i] = d

    cbset = set(codebook)
    remap: list[int] = []
    merged_uniq = 0
    for i in range(len(uniq_tiles)):
        if i in cbset:
            remap.append(i)
            continue
        # shortlist by coarse distance, rank by fine SSD
        short = sorted(codebook, key=lambda c: (cdist(feats[i], feats[c]), c))[:6]
        tgt = min(short, key=lambda c: (fdist(uniq_tiles[i], uniq_tiles[c]), c))
        remap.append(tgt)
        merged_uniq += 1

    merged_cells = 0
    out = []
    for j in range(n):
        k = remap[assign[j]]
        if k != assign[j]:
            merged_cells += 1
        out.append(list(uniq_tiles[k]))
    return out, merged_cells


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
