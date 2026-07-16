"""Compose isometric road banks and brick cubes from geometry + optional textures.

Closed inventories (pipeline contract):
  - Roads: 16 Wang 2-edge masks (N=1 E=2 S=4 W=8) as full diamond *pieces*
  - Bricks: precomposed 3-face cube (top + left + right)
  - Z affordances: ghost outline cube + ground shadow disc

Offline-first: no network. Texture images are optional fills.
"""
from __future__ import annotations

from pathlib import Path
from typing import Callable

from PIL import Image, ImageDraw

from . import iso_geom
from .iso_geom import IsoSize, in_diamond, iso_cube_faces

# Neighbor bits — must match cart city_map
N, E, S, W = 1, 2, 4, 8

# Default materials (BGR-friendly bright toy palette)
GRASS = (40, 160, 50)
GRASS_DARK = (30, 120, 40)
ASPHALT = (70, 70, 80)
ASPHALT_LIGHT = (100, 100, 110)
CURB = (180, 170, 150)
OUTLINE = (20, 20, 25)
BRICK_TOP = (220, 60, 50)
BRICK_LEFT = (160, 40, 40)
BRICK_RIGHT = (120, 30, 30)
STUD = (240, 80, 70)
ROOF_TOP = (90, 90, 100)
ROOF_LEFT = (60, 60, 70)
ROOF_RIGHT = (45, 45, 55)
KEY = (255, 0, 255)
SHADOW = (0, 0, 0)


def _tex_at(tex: Image.Image | None, x: int, y: int, fallback: tuple[int, int, int]) -> tuple[int, int, int]:
    if tex is None:
        return fallback
    t = tex.convert("RGB")
    return t.getpixel((x % t.size[0], y % t.size[1]))  # type: ignore[return-value]


def _lane_pixels(size: IsoSize, mask: int, lane: float = 0.38) -> set[tuple[int, int]]:
    """Pixels that belong to the road *piece* for this connectivity mask.

    Map axes on 2:1 lattice:
      NS corridor (N|S): abs(u+v) <= lane   # screen NE–SW band tip-to-tip
      EW corridor (E|W): abs(u-v) <= lane   # screen NW–SE band tip-to-tip
    """
    w, h = size.w, size.h
    cx, cy = (w - 1) / 2.0, (h - 1) / 2.0
    n, e, s, wbit = bool(mask & N), bool(mask & E), bool(mask & S), bool(mask & W)
    bits = (1 if n else 0) + (1 if e else 0) + (1 if s else 0) + (1 if wbit else 0)
    out: set[tuple[int, int]] = set()

    for y in range(h):
        for x in range(w):
            if not in_diamond(x, y, w, h):
                continue
            u = (x - cx) / (w / 2.0)
            v = (y - cy) / (h / 2.0)
            on_ns = abs(u + v) <= lane
            on_ew = abs(u - v) <= lane
            hit = False

            if bits == 0:
                # Pad: fat center
                hit = abs(u) + abs(v) < 0.55
            elif n and e and s and wbit:
                hit = on_ns or on_ew or (abs(u) + abs(v) < 0.35)
            elif n and s and not e and not wbit:
                # Straight NS — full spine tip to tip
                hit = on_ns
            elif e and wbit and not n and not s:
                hit = on_ew
            else:
                # Stubs, corners, T: corridors only in connected directions
                if n and s and on_ns:
                    hit = True
                if e and wbit and on_ew:
                    hit = True
                # Half-spines toward connected tips only
                if n and not s and on_ns and (u + v) <= 0.08:
                    hit = True
                if s and not n and on_ns and (u + v) >= -0.08:
                    hit = True
                if e and not wbit and on_ew and (u - v) >= -0.08:
                    hit = True
                if wbit and not e and on_ew and (u - v) <= 0.08:
                    hit = True
                # Corner / T hub
                if bits >= 2 and abs(u) + abs(v) < 0.42:
                    hit = True
            if hit:
                out.add((x, y))
    return out


def paint_ground_tile(
    size: IsoSize,
    *,
    grass_tex: Image.Image | None = None,
    fill: tuple[int, int, int] = GRASS,
) -> Image.Image:
    im = Image.new("RGB", (size.w, size.h), KEY)
    ip = im.load()
    assert ip is not None
    for y in range(size.h):
        for x in range(size.w):
            if in_diamond(x, y, size.w, size.h):
                ip[x, y] = _tex_at(grass_tex, x, y, fill)
    return im


def paint_road_piece(
    size: IsoSize,
    mask: int,
    *,
    grass_tex: Image.Image | None = None,
    road_tex: Image.Image | None = None,
    lane: float = 0.40,
) -> Image.Image:
    """One directional road *tile* for the given neighbor mask (0..15)."""
    im = paint_ground_tile(size, grass_tex=grass_tex)
    ip = im.load()
    assert ip is not None
    road_px = _lane_pixels(size, mask & 15, lane=lane)
    # Slightly darken curb ring of road (not whole diamond rim)
    for x, y in road_px:
        base = _tex_at(road_tex, x, y, ASPHALT)
        # Edge of road blob → curb
        edge = False
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            if (x + dx, y + dy) not in road_px and in_diamond(x + dx, y + dy, size.w, size.h):
                edge = True
                break
        ip[x, y] = CURB if edge else base
    return im


def road_bank(
    size: IsoSize | str = "32x16",
    *,
    grass_tex: Image.Image | Path | None = None,
    road_tex: Image.Image | Path | None = None,
    lane: float = 0.40,
) -> dict[str, Image.Image]:
    """Return {grass, road_00..road_15} RGB diamonds with KEY bg."""
    if isinstance(size, str):
        size = IsoSize.parse(size)
    gtex = Image.open(grass_tex).convert("RGB") if isinstance(grass_tex, (str, Path)) else grass_tex
    rtex = Image.open(road_tex).convert("RGB") if isinstance(road_tex, (str, Path)) else road_tex
    bank: dict[str, Image.Image] = {
        "grass": paint_ground_tile(size, grass_tex=gtex),
    }
    for mask in range(16):
        bank[f"road_{mask:02d}"] = paint_road_piece(
            size, mask, grass_tex=gtex, road_tex=rtex, lane=lane
        )
    return bank


def paint_brick_cube(
    w: int = 16,
    *,
    top: tuple[int, int, int] = BRICK_TOP,
    left: tuple[int, int, int] = BRICK_LEFT,
    right: tuple[int, int, int] = BRICK_RIGHT,
    outline: tuple[int, int, int] = OUTLINE,
    studs: bool = True,
    material_tex: Image.Image | None = None,
) -> Image.Image:
    """Precomposed iso cube (top + L + R faces) on KEY background."""
    faces = iso_cube_faces(w)
    im = Image.new("RGB", faces.canvas, KEY)
    dr = ImageDraw.Draw(im)

    def fill_poly(poly, color):
        dr.polygon(list(poly), fill=color)

    if material_tex is not None:
        # Approximate: solid shades only; texture optional on top face
        top_c = _tex_at(material_tex, w // 2, w // 4, top)
        left_c = tuple(max(0, c - 40) for c in top_c)
        right_c = tuple(max(0, c - 70) for c in top_c)
    else:
        top_c, left_c, right_c = top, left, right

    fill_poly(faces.left, left_c)
    fill_poly(faces.right, right_c)
    fill_poly(faces.top, top_c)
    # outlines
    dr.line(list(faces.top) + [faces.top[0]], fill=outline, width=1)
    dr.line(list(faces.left) + [faces.left[0]], fill=outline, width=1)
    dr.line(list(faces.right) + [faces.right[0]], fill=outline, width=1)

    if studs:
        # 2x2 studs on top diamond (simple)
        cx, cy = w // 2, w // 4
        for sx, sy in ((-3, -1), (3, -1), (-3, 2), (3, 2)):
            dr.ellipse([cx + sx - 1, cy + sy - 1, cx + sx + 1, cy + sy + 1], fill=STUD)
    return im


def paint_ghost_cube(w: int = 16, *, outline: tuple[int, int, int] = (255, 255, 80)) -> Image.Image:
    """Outline-only cube for Z-plane ghost (same geometry as solid brick)."""
    faces = iso_cube_faces(w)
    im = Image.new("RGB", faces.canvas, KEY)
    dr = ImageDraw.Draw(im)
    for poly in (faces.top, faces.left, faces.right):
        dr.line(list(poly) + [poly[0]], fill=outline, width=1)
    return im


def paint_ground_shadow(size: IsoSize | str = "32x16") -> Image.Image:
    """Dark disc/ellipse on ground diamond — Z support footprint."""
    if isinstance(size, str):
        size = IsoSize.parse(size)
    im = Image.new("RGB", (size.w, size.h), KEY)
    dr = ImageDraw.Draw(im)
    # Ellipse inscribed in diamond
    margin_x, margin_y = size.w // 4, size.h // 4
    dr.ellipse(
        [margin_x, margin_y, size.w - 1 - margin_x, size.h - 1 - margin_y],
        fill=(30, 30, 40),
        outline=OUTLINE,
    )
    # Punch outside diamond to KEY
    ip = im.load()
    assert ip is not None
    for y in range(size.h):
        for x in range(size.w):
            if not in_diamond(x, y, size.w, size.h):
                ip[x, y] = KEY
    return im


def stitch_preview(
    bank: dict[str, Image.Image],
    pattern: str,
    size: IsoSize,
    *,
    scale: int = 3,
) -> Image.Image:
    """Contact sheet proving neighbor stitch for common patterns."""
    # pattern cells as (tx,ty,mask_or_grass)
    # Mask keys must match the edges each cell actually shares with neighbors.
    # Bits: N=1 E=2 S=4 W=8. Full spines (05 NS, 10 EW) are OK for through arms;
    # corner/tee use exact connectivity so free tips do not grow phantom stubs.
    patterns: dict[str, list[tuple[int, int, str]]] = {
        "straight_ns": [(0, 0, "road_05"), (0, 1, "road_05"), (0, 2, "road_05")],
        "straight_ew": [(0, 0, "road_10"), (1, 0, "road_10"), (2, 0, "road_10")],
        # L: east from (0,0), bend at (1,0), south to (1,1)
        "corner": [(0, 0, "road_02"), (1, 0, "road_12"), (1, 1, "road_01")],
        # T: horizontal bar + stem south
        "tee": [
            (0, 0, "road_02"),
            (1, 0, "road_14"),  # E|W|S
            (2, 0, "road_08"),
            (1, 1, "road_01"),
        ],
        "cross": [
            (1, 0, "road_04"),  # S only into center
            (0, 1, "road_02"),  # E only
            (1, 1, "road_15"),  # hub
            (2, 1, "road_08"),  # W only
            (1, 2, "road_01"),  # N only
        ],
        "atlas": [(m % 4, m // 4, f"road_{m:02d}") for m in range(16)],
    }
    cells = patterns.get(pattern)
    if cells is None:
        raise ValueError(f"unknown pattern {pattern}; choose {list(patterns)}")

    # Compute canvas from cell positions
    hs_x, hs_y = size.half_step
    positions = []
    for tx, ty, key in cells:
        sx, sy = iso_geom.cell_screen_xy(tx, ty, size, origin=(size.w, size.h))
        positions.append((sx, sy, key))
    max_x = max(sx for sx, _, _ in positions) + size.w + size.w
    max_y = max(sy for _, sy, _ in positions) + size.h + size.h
    canvas = Image.new("RGB", (max_x, max_y), (40, 80, 120))
    # Grass fill under
    grass = bank.get("grass")
    if grass is not None:
        for tx in range(-1, 6):
            for ty in range(-1, 6):
                sx, sy = iso_geom.cell_screen_xy(tx, ty, size, origin=(size.w, size.h))
                if 0 <= sx < max_x and 0 <= sy < max_y:
                    canvas.paste(grass, (sx, sy), _rgb_key_mask(grass))
    for sx, sy, key in positions:
        tile = bank[key]
        canvas.paste(tile, (sx, sy), _rgb_key_mask(tile))
    if scale != 1:
        canvas = canvas.resize((canvas.width * scale, canvas.height * scale), Image.Resampling.NEAREST)
    return canvas


def _rgb_key_mask(im: Image.Image, key: tuple[int, int, int] = KEY) -> Image.Image:
    """Alpha mask from magenta key."""
    im = im.convert("RGBA")
    datas = im.getdata()
    new = []
    for item in datas:
        if item[0] == key[0] and item[1] == key[1] and item[2] == key[2]:
            new.append((0, 0, 0, 0))
        else:
            new.append(item)
    im.putdata(new)
    return im


def save_bank(bank: dict[str, Image.Image], out_dir: Path) -> list[Path]:
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for name, im in bank.items():
        p = out_dir / f"{name}.png"
        im.save(p)
        paths.append(p)
    return paths
