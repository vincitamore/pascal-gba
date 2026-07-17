"""sprite_lib.scenic -- parallax layer compose primitives for mode-0 BGs.

Layer model (three text BGs, independent scroll rates in the cart):

  BG2 far  = **sky plate** (opaque generated art — gradient, clouds; day or dusk)
  BG1 mid  = **scenic plate** (buildings/ridge only; edge-keyed transparent sky)
  BG0 near = **ground stamps** (grass/dirt in the play band; transparent above)

Rules:

1. **Never paint sky into the mid plate.** Opaque solid-sky fill of mid is a
   hack that kills atmospheric depth. Sky is always its own asset layer.
2. **Edge-connected chroma key only** on mid plates. Flood from the border.
   White tent stripes / cream booth paint must never become transparent.
3. **Ground does not cover the whole screen.** Upper map rows stay transparent
   (palette index 0) so mid + sky show through.
4. **Ground stamps are low-contrast macros** (16x16 = 2x2 of 8x8), not high-
   contrast random 8x8 noise (that tiles into a checker artifact).

CLI: ``sprite mid-plate`` (edge-key + preview). Cart generators call these
helpers to emit multi-bank map .incs.
"""
from __future__ import annotations

from collections import deque
from pathlib import Path
from typing import Callable, Sequence

from PIL import Image


KeyPred = Callable[[int, int, int], bool]


def is_solid_magenta(r: int, g: int, b: int, *, g_max: int = 120) -> bool:
    """Plate-sky key for pure/JPEG magenta. Does NOT match white or pure red.

    JPEG softens #FF00FF into hot-pink (high R+B, mid G). Accept when G is
    clearly below both R and B. White/cream and tent red stay safe.
    """
    if min(r, g, b) >= 190:
        return False
    if r >= 180 and b <= 130 and g <= 130:
        return False
    # Hot-pink plate sky (often JPEG of #FF00FF → ~250,0,175)
    if r >= 200 and b >= 150 and g <= g_max and g < r - 60 and b > g + 80:
        return True
    if r >= 220 and b >= 140 and g <= 40:
        return True
    return False


def normalize_plate_key(im: Image.Image, is_key: KeyPred | None = None) -> Image.Image:
    """Rewrite key-colored pixels to pure #FF00FF so edge-flood is reliable."""
    is_key = is_key or is_solid_magenta
    out = im.convert("RGB").copy()
    px = out.load()
    w, h = out.size
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            if is_key(r, g, b):
                px[x, y] = (255, 0, 255)
    return out


def is_near_key_rgb(
    r: int, g: int, b: int,
    key: tuple[int, int, int] = (255, 0, 255),
    *,
    tol: int = 48,
) -> bool:
    if min(r, g, b) >= 200:
        return False
    kr, kg, kb = key
    return abs(r - kr) <= tol and abs(g - kg) <= tol and abs(b - kb) <= tol


def edge_connected_key_mask(
    im: Image.Image,
    is_key: KeyPred | None = None,
) -> Image.Image:
    """L-mask: 255 = transparent (edge-flooded key), 0 = keep subject."""
    is_key = is_key or is_solid_magenta
    rgb = im.convert("RGB")
    w, h = rgb.size
    px = rgb.load()
    mask = Image.new("L", (w, h), 0)
    m = mask.load()
    visited = [[False] * w for _ in range(h)]
    q: deque[tuple[int, int]] = deque()

    def try_push(x: int, y: int) -> None:
        if x < 0 or y < 0 or x >= w or y >= h or visited[y][x]:
            return
        r, g, b = px[x, y]
        if not is_key(r, g, b):
            return
        visited[y][x] = True
        q.append((x, y))

    for x in range(w):
        try_push(x, 0)
        try_push(x, h - 1)
    for y in range(h):
        try_push(0, y)
        try_push(w - 1, y)

    while q:
        x, y = q.popleft()
        m[x, y] = 255
        try_push(x + 1, y)
        try_push(x - 1, y)
        try_push(x, y + 1)
        try_push(x, y - 1)

    return mask


def hard_pixel_fit(
    im: Image.Image,
    out_w: int,
    out_h: int,
    *,
    pre_colors: int = 32,
) -> Image.Image:
    """Fit plate to target size without muddy BOX blends.

    1) Snap to a hard palette at source (no dither) — kills JPEG mush.
    2) Scale with NEAREST — keeps chunky outlines (BOX = squished/dirty).

    This is the main fix for "mid looks squished and dirty": soft downscale
    invents intermediate colors that destroy NES-style clarity.
    """
    rgb = im.convert("RGB")
    q = rgb.quantize(
        colors=max(4, min(pre_colors, 48)),
        method=Image.MEDIANCUT,
        dither=Image.Dither.NONE,
    )
    hard = q.convert("RGB")
    # Stepwise NEAREST when shrinking hard so whole booths aren't skipped
    # in a single 10× sample (still chunky, just more of the source survives).
    cw, ch = hard.size
    while cw > out_w * 3 or ch > out_h * 3:
        nw = max(out_w, (cw + 1) // 2)
        nh = max(out_h, (ch + 1) // 2)
        if nw == cw and nh == ch:
            break
        hard = hard.resize((nw, nh), Image.Resampling.NEAREST)
        cw, ch = nw, nh
    return hard.resize((out_w, out_h), Image.Resampling.NEAREST)


def subject_strip_crop(
    im: Image.Image,
    is_key: KeyPred,
    *,
    out_w: int,
    out_h: int,
) -> Image.Image:
    """Crop a horizontal strip of subject matching target aspect.

    Full-frame carnival plates (e.g. 16:9) force-fit into a wide short band
    (e.g. 512×80 ≈ 6.4:1) by pure vertical stretch → "squished" skyline.
    Prefer a bottom-biased window of height ≈ source_w * (out_h/out_w) so
    booths rest on the horizon and proportions stay honest; magenta sky above
    the strip is free (keyed later).
    """
    w, h = im.size
    px = im.load()

    def row_has_subject(yy: int) -> bool:
        hits = 0
        step = max(1, w // 80)
        for xx in range(0, w, step):
            r, g, b = px[xx, yy]
            if not is_key(r, g, b):
                hits += 1
        return hits > 6

    y0, y1 = 0, h
    for yy in range(h):
        if row_has_subject(yy):
            y0 = max(0, yy - 2)
            break
    for yy in range(h - 1, -1, -1):
        if row_has_subject(yy):
            y1 = min(h, yy + 2)
            break

    sub_h = max(1, y1 - y0)
    # Cap extreme vertical squash only. Target band is ultra-wide (e.g. 512×72);
    # full-frame plates can be ~3–4× taller than honest aspect. Allow ~2.5× more
    # vertical compression than horizontal so ferris/tent tops stay in frame —
    # pure aspect-match crop only kept booth feet and looked worse.
    horiz_ratio = w / max(1, out_w)
    max_sub_h = max(out_h * 4, int(round(out_h * horiz_ratio * 2.5)))
    if sub_h > max_sub_h:
        # Bottom-biased window: horizon line of skyline + as much height as cap.
        # Slight upward bias so pennants/flags aren't always truncated.
        y1_new = y1
        y0_new = max(y0, y1_new - max_sub_h)
        used = y1_new - y0_new
        if used > max_sub_h:
            y0_new = y1_new - max_sub_h
        # Nudge ~12% toward top of subject mass (keep flags when possible)
        room = y0_new - y0
        if room > 0:
            y0_new = max(y0, y0_new - room // 8)
            y1_new = min(y1, y0_new + max_sub_h)
            y0_new = y1_new - max_sub_h
        y0, y1 = y0_new, y1_new
    return im.crop((0, y0, w, y1))


def prepare_mid_plate(
    path: str | Path,
    *,
    out_w: int,
    out_h: int,
    key_pred: KeyPred | None = None,
    fill_rgb: tuple[int, int, int] | None = None,
    hard_pixels: bool = True,
) -> Image.Image:
    """Load plate → aspect-honest subject strip → hard resize → chroma key.

    Default (``fill_rgb=None``): return **RGBA** with transparent sky so a
    separate sky layer shows through. Pass ``fill_rgb`` only for opaque previews
    — not for product mid layers (that kills parallax sky).

    ``hard_pixels=True`` (default): quantize-no-dither + NEAREST scale so the
    strip stays chunky instead of soft/squished/muddy.
    """
    path = Path(path)
    is_key = key_pred or is_solid_magenta
    im = normalize_plate_key(Image.open(path).convert("RGB"), is_key)
    crop = subject_strip_crop(im, is_key, out_w=out_w, out_h=out_h)
    if hard_pixels:
        crop = hard_pixel_fit(crop, out_w, out_h, pre_colors=24)
    else:
        crop = crop.resize((out_w, out_h), Image.Resampling.BOX)
    # Re-normalize after scale (fringes)
    crop = normalize_plate_key(crop, is_key)

    # Fill the mid band with subject mass: after hard-fit, magenta often still
    # occupies the top half of the strip so buildings look "squished" into a
    # short row. Re-crop to opaque content and NEAREST-scale that into out_h.
    cp0 = crop.load()
    def row_opaque(yy: int) -> bool:
        hits = 0
        for xx in range(0, out_w, max(1, out_w // 64)):
            r, g, b = cp0[xx, yy]
            if not is_key(r, g, b):
                hits += 1
        return hits > 3

    cy0, cy1 = 0, out_h
    for yy in range(out_h):
        if row_opaque(yy):
            cy0 = yy
            break
    for yy in range(out_h - 1, -1, -1):
        if row_opaque(yy):
            cy1 = yy + 1
            break
    content_h = max(1, cy1 - cy0)
    if content_h < int(out_h * 0.85):
        content = crop.crop((0, cy0, out_w, cy1))
        crop = content.resize((out_w, out_h), Image.Resampling.NEAREST)
        crop = normalize_plate_key(crop, is_key)

    # Key ALL plate-magenta pixels (not only edge-flood). Safe because
    # is_solid_magenta refuses white/cream/pure red — so tent stripes stay.
    # Edge-only flood left interior sky pockets (ferris gaps) opaque pink.
    cp = crop.load()
    key_mask = Image.new("L", (out_w, out_h), 0)
    km = key_mask.load()
    for y in range(out_h):
        for x in range(out_w):
            r, g, b = cp[x, y]
            if is_key(r, g, b):
                km[x, y] = 255

    if fill_rgb is not None:
        out = crop.copy()
        op = out.load()
        for y in range(out_h):
            for x in range(out_w):
                if km[x, y] >= 128:
                    op[x, y] = fill_rgb
        return out

    rgba = crop.convert("RGBA")
    rp = rgba.load()
    for y in range(out_h):
        for x in range(out_w):
            if km[x, y] >= 128:
                r, g, b, _a = rp[x, y]
                rp[x, y] = (r, g, b, 0)
    return rgba


def prepare_sky_plate(
    path: str | Path,
    *,
    out_w: int,
    out_h: int,
) -> Image.Image:
    """Resize a full-frame sky asset to the world map pixel size (opaque RGB)."""
    im = Image.open(path).convert("RGB")
    return im.resize((out_w, out_h), Image.Resampling.BOX)


def sky_row_colors(
    sky_im: Image.Image,
    *,
    tile: int = 8,
    n_slots: int = 12,
) -> list[tuple[int, int, int]]:
    """Sample a generated sky plate into one average RGB per tile-row.

    Returns ``map_h`` colors (one per 8px band), quantized into at most
    ``n_slots`` unique hues so a full sky is a handful of solid tiles — but
    the hues come from the *generated* plate, not invented fills.
    """
    w, h = sky_im.size
    if h % tile:
        raise ValueError(f"sky height {h} not multiple of {tile}")
    px = sky_im.convert("RGB").load()
    rows: list[tuple[int, int, int]] = []
    for ty in range(h // tile):
        rs = gs = bs = n = 0
        y0 = ty * tile
        for y in range(y0, y0 + tile):
            for x in range(0, w, max(1, w // 64)):
                r, g, b = px[x, y]
                rs += r
                gs += g
                bs += b
                n += 1
        rows.append((rs // n, gs // n, bs // n))
    # Merge similar consecutive rows into shared colors (tile reuse)
    # Keep order; map each row to nearest of a small unique set.
    unique: list[tuple[int, int, int]] = []
    for c in rows:
        placed = False
        for u in unique:
            if dist2(c, u) < 900:  # ~30 per channel
                placed = True
                break
        if not placed and len(unique) < n_slots:
            unique.append(c)
    if not unique:
        unique = [(80, 120, 200)]
    mapped: list[tuple[int, int, int]] = []
    for c in rows:
        mapped.append(min(unique, key=lambda u: dist2(c, u)))
    return mapped


def sky_band_tiles_and_map(
    sky_im: Image.Image,
    *,
    map_w: int,
    map_h: int,
    tile: int = 8,
    add_tile,  # Callable[[list[int]], int]
    bank: int = 0,
    n_slots: int = 12,
    visible_rows: int | None = None,
) -> tuple[list[tuple[int, int, int]], list[int]]:
    """Build sky map from a generated plate: gradient bands + soft cloud stamps.

    ``visible_rows`` (default map_h): stretch the *full* plate gradient across
    only the rows where sky is actually seen (above the ground band). Otherwise
    a tall mid leaves only the plate's top purple strip visible → mono bar.
    """
    w, h = sky_im.size
    vis = visible_rows if visible_rows is not None else map_h
    vis = max(1, min(vis, map_h))

    # Sample full plate height into `vis` bands (full dusk range in visible sky)
    px = sky_im.convert("RGB").load()
    row_cols: list[tuple[int, int, int]] = []
    for ty in range(vis):
        # map tile-row → source y band across full plate
        y0 = int(ty / vis * h)
        y1 = max(y0 + 1, int((ty + 1) / vis * h))
        rs = gs = bs = n = 0
        for y in range(y0, y1):
            for x in range(0, w, max(1, w // 48)):
                r, g, b = px[x, y]
                rs += r
                gs += g
                bs += b
                n += 1
        row_cols.append((rs // n, gs // n, bs // n))
    # below visible: hold horizon (last band)
    while len(row_cols) < map_h:
        row_cols.append(row_cols[-1])

    # unique colors → solid tiles
    pal: list[tuple[int, int, int]] = []
    color_to_tid: dict[tuple[int, int, int], int] = {}

    def tid_for(c: tuple[int, int, int]) -> int:
        # exact or near
        for u, tid in color_to_tid.items():
            if dist2(c, u) < 600:
                return tid
        if len(pal) >= 14:
            u = min(pal, key=lambda x: dist2(c, x))
            return color_to_tid[u]
        pal.append(c)
        slot = len(pal)  # 1..15
        tid = add_tile([slot] * 64)
        color_to_tid[c] = tid
        return tid

    sky_map: list[int] = []
    row_tids: list[int] = []
    for ty in range(map_h):
        tid = tid_for(row_cols[ty])
        row_tids.append(tid)
        for _tx in range(map_w):
            sky_map.append(map_entry(tid, bank=bank))

    # Cloud stamps from plate: lighter-than-local-band dabs on upper half
    if len(pal) < 14:
        # add a cloud highlight color (lighten last mid band)
        base = row_cols[max(0, vis // 3)]
        cloud_c = (
            min(255, base[0] + 50),
            min(255, base[1] + 45),
            min(255, base[2] + 40),
        )
        pal.append(cloud_c)
        cloud_slot = len(pal)
        # soft ellipse cloud tiles (opaque cloud on transparent — but sky is
        # opaque layer, so use band color as background in cell)
        for seed, (cx, cy) in enumerate(
            ((8, 2), (28, 3), (48, 1), (18, 4), (40, 5))
        ):
            if cy >= vis:
                continue
            band_slot = 0
            # find palette slot of that row's band color
            band_c = row_cols[cy]
            band_tid = tid_for(band_c)
            # rebuild cell: cloud_slot on ellipse, else band's solid index
            # band tile is solid [band_slot]*64 — recover slot from pal index
            band_slot = next(
                (i + 1 for i, u in enumerate(pal) if dist2(u, band_c) < 600),
                1,
            )
            cell: list[int] = []
            for y in range(8):
                for x in range(8):
                    dx = (x - 3.5 + (seed % 3)) / (3.8 + seed % 2)
                    dy = (y - 3.5) / 2.2
                    if dx * dx + dy * dy < 1.0:
                        cell.append(cloud_slot)
                    else:
                        cell.append(band_slot)
            ctid = add_tile(cell)
            if 0 <= cx < map_w and 0 <= cy < map_h:
                sky_map[cy * map_w + cx] = map_entry(ctid, bank=bank)
                if cx + 1 < map_w:
                    sky_map[cy * map_w + cx + 1] = map_entry(ctid, bank=bank)

    return pal, sky_map


def dist2(a: tuple[int, int, int], b: tuple[int, int, int]) -> int:
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2


def nearest_slot(
    rgb: tuple[int, int, int],
    pal: Sequence[tuple[int, int, int]],
    *,
    start: int = 1,
) -> int:
    bi, bd = start, 10**9
    for i in range(start, len(pal)):
        d = dist2(rgb, pal[i])
        if d < bd:
            bd, bi = d, i
    return bi


def quantize_to_palette(
    im: Image.Image,
    pal_rgb: Sequence[tuple[int, int, int]],
    *,
    transparent_index: int = 0,
) -> list[list[int]]:
    """Image → list of 8x8 cells (64 indices each). Alpha < 128 → transparent."""
    w, h = im.size
    if w % 8 or h % 8:
        raise ValueError(f"scenic quantize: size must be multiple of 8, got {w}x{h}")
    has_a = im.mode == "RGBA"
    px = im.load()
    tw, th = w // 8, h // 8
    cells: list[list[int]] = []
    for ty in range(th):
        for tx in range(tw):
            cell: list[int] = []
            for y in range(8):
                for x in range(8):
                    p = px[tx * 8 + x, ty * 8 + y]
                    if has_a:
                        r, g, b, a = p
                        if a < 128:
                            cell.append(transparent_index)
                            continue
                    else:
                        r, g, b = p
                    cell.append(nearest_slot((r, g, b), pal_rgb, start=1))
            cells.append(cell)
    return cells


def build_palette_from_image(
    im: Image.Image,
    *,
    n_colors: int = 15,
    skip_key: KeyPred | None = None,
) -> list[tuple[int, int, int]]:
    """Median-cut palette for a layer (slot 0 reserved transparent conceptually).

    Returns list of length n_colors of RGB triples (all subject colors).
    Caller places them at bank slots 1..n.
    """
    skip_key = skip_key or (lambda r, g, b: False)
    rgb = im.convert("RGB")
    # strip key pixels before quantize so magenta doesn't steal slots
    samples = Image.new("RGB", rgb.size, (128, 128, 128))
    sp = samples.load()
    src = rgb.load()
    w, h = rgb.size
    for y in range(h):
        for x in range(w):
            r, g, b = src[x, y]
            if im.mode == "RGBA":
                a = im.getpixel((x, y))[3]
                if a < 128:
                    continue
            if skip_key(r, g, b):
                continue
            sp[x, y] = (r, g, b)
    q = samples.quantize(colors=max(2, n_colors), method=Image.MEDIANCUT)
    pal = q.getpalette() or []
    out: list[tuple[int, int, int]] = []
    for i in range(n_colors):
        if (i + 1) * 3 <= len(pal):
            out.append((pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2]))
        else:
            out.append((0, 0, 0))
    return out


def soft_grass_8x8(seed: int, slots: tuple[int, int, int] = (12, 13, 14)) -> list[int]:
    """Low-contrast grass flecks for 2x2 macro stamping."""
    dark, mid, light = slots
    px: list[int] = []
    for y in range(8):
        for x in range(8):
            # ~95% mid body — flecks rare so stamped field reads as flat turf
            n = ((x // 3) * 13 + (y // 3) * 29 + seed * 41) & 255
            if n < 4:
                c = light
            elif n < 10:
                c = dark
            else:
                c = mid
            px.append(c)
    return px


def soft_dirt_8x8(seed: int, slots: tuple[int, int, int] = (9, 10, 11)) -> list[int]:
    dark, mid, light = slots
    px: list[int] = []
    for y in range(8):
        for x in range(8):
            n = ((x // 3) * 11 + (y // 3) * 19 + seed * 17) & 255
            if n < 5:
                c = light
            elif n < 14:
                c = dark
            else:
                c = mid
            px.append(c)
    return px


def stamp_ground_map(
    map_w: int,
    map_h: int,
    *,
    gnd_row0: int,
    grass_tile_ids: Sequence[int],
    dirt_tile_ids: Sequence[int],
    edge_tile_id: int,
    path_width: int = 2,
    empty_tile_id: int = 0,
) -> list[int]:
    """Full map; rows above gnd_row0 are empty (transparent) so mid/sky show."""
    import math

    m = [empty_tile_id] * (map_w * map_h)
    ng, nd = len(grass_tile_ids), len(dirt_tile_ids)
    if ng == 0 or nd == 0:
        raise ValueError("stamp_ground_map needs grass and dirt tile ids")

    def grass_at(tx: int, ty: int) -> int:
        if ng >= 4:
            return grass_tile_ids[(ty % 2) * 2 + (tx % 2)]
        return grass_tile_ids[(tx + ty) % ng]

    def dirt_at(tx: int, ty: int) -> int:
        if nd >= 4:
            return dirt_tile_ids[(ty % 2) * 2 + (tx % 2)]
        return dirt_tile_ids[(tx + ty) % nd]

    for y in range(gnd_row0, map_h):
        for x in range(map_w):
            if y == gnd_row0:
                m[y * map_w + x] = edge_tile_id
                continue
            lane = int(22 + 5 * math.sin((x + (y - gnd_row0) * 0.35) * 0.22))
            dx = min(abs(x - lane), abs(x - (lane + 30) % map_w))
            if dx < path_width:
                m[y * map_w + x] = dirt_at(x, y)
            elif dx == path_width:
                m[y * map_w + x] = dirt_at(x, y) if (x + y) % 4 == 0 else grass_at(x, y)
            else:
                m[y * map_w + x] = grass_at(x, y)
    return m


def map_entry(tile_index: int, *, bank: int = 0, hflip: bool = False, vflip: bool = False) -> int:
    """GBA text-BG screen entry: tile + flips + palette bank."""
    e = tile_index & 0x3FF
    if hflip:
        e |= 1 << 10
    if vflip:
        e |= 1 << 11
    e |= (bank & 0xF) << 12
    return e
