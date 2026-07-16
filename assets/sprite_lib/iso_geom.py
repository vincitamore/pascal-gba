"""Isometric geometry primitives for GBA tile generation (dimetric 2:1).

Canonical contract (pixel-art dimetric standard):
  - Diamond width W, height H = W // 2  (2:1, ~26.565 deg -- not true 30 deg iso).
  - Corners (top, right, bottom, left) at mid-edges of the WxH AABB.
  - Fill test: |dx|/(W/2) + |dy|/(H/2) <= 1  (Manhattan in scaled axes).
  - Transparent AABB corners for BG/OBJ packing; map half-step = (W/2, H/2).

Does not call the network. Pure math + Pillow masks.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Literal

from PIL import Image, ImageDraw

Pivot = Literal["top_tip", "center", "feet", "top_left"]


@dataclass(frozen=True)
class IsoSize:
    """Diamond / ground cell size in pixels."""

    w: int
    h: int

    def __post_init__(self) -> None:
        if self.w < 8 or self.h < 4:
            raise ValueError(f"iso size too small: {self.w}x{self.h}")
        if self.w % 2 != 0 or self.h % 2 != 0:
            raise ValueError(f"iso size must be even: {self.w}x{self.h}")
        if self.h * 2 != self.w:
            raise ValueError(
                f"iso size must be 2:1 (W=2H); got {self.w}x{self.h} "
                f"(expected h={self.w // 2})"
            )

    @property
    def half_step(self) -> tuple[int, int]:
        """Screen offset to the next cell in +tx / +ty (map axes)."""
        return (self.w // 2, self.h // 2)

    @classmethod
    def parse(cls, s: str) -> "IsoSize":
        a, b = s.lower().split("x")
        return cls(int(a), int(b))

    def __str__(self) -> str:
        return f"{self.w}x{self.h}"


# Defaults (pipeline contract)
GROUND_DEFAULT = IsoSize(32, 16)  # readable roads
GROUND_COMPACT = IsoSize(16, 8)
BRICK_DEFAULT_W = 16  # 16x16 AABB cube (top 16x8 + sides)


def diamond_corners(w: int, h: int) -> tuple[tuple[int, int], ...]:
    """Top, right, bottom, left tips of the diamond inside the AABB."""
    return (
        (w // 2, 0),
        (w - 1, h // 2),
        (w // 2, h - 1),
        (0, h // 2),
    )


def in_diamond(x: int, y: int, w: int, h: int) -> bool:
    """True if pixel center is inside the 2:1 diamond (inclusive)."""
    cx = (w - 1) / 2.0
    cy = (h - 1) / 2.0
    dx = abs(x - cx) / (w / 2.0)
    dy = abs(y - cy) / (h / 2.0)
    return dx + dy <= 1.0 + 1e-9


def diamond_mask(w: int, h: int) -> Image.Image:
    """L mode mask: 255 inside diamond, 0 outside."""
    m = Image.new("L", (w, h), 0)
    px = m.load()
    assert px is not None
    for y in range(h):
        for x in range(w):
            if in_diamond(x, y, w, h):
                px[x, y] = 255
    return m


def pivot_offset(w: int, h: int, pivot: Pivot) -> tuple[int, int]:
    """Offset from top-left AABB to the named pivot (for consumer docs)."""
    if pivot == "top_left":
        return (0, 0)
    if pivot == "top_tip":
        return (w // 2, 0)
    if pivot == "center":
        return (w // 2, h // 2)
    if pivot == "feet":
        return (w // 2, h - 1)
    raise ValueError(pivot)


def cell_screen_xy(tx: int, ty: int, size: IsoSize, origin: tuple[int, int] = (0, 0)) -> tuple[int, int]:
    """Top-left of cell AABB at map (tx,ty) under 2:1 half-step lattice."""
    hs_x, hs_y = size.half_step
    ox, oy = origin
    return (ox + (tx - ty) * hs_x, oy + (tx + ty) * hs_y)


@dataclass(frozen=True)
class CubeFaces:
    """Polygons for a 1-high iso cube of ground width W (AABB W×W)."""

    w: int
    top: tuple[tuple[int, int], ...]
    left: tuple[tuple[int, int], ...]
    right: tuple[tuple[int, int], ...]

    @property
    def canvas(self) -> tuple[int, int]:
        return (self.w, self.w)


def iso_cube_faces(w: int = BRICK_DEFAULT_W) -> CubeFaces:
    """Top diamond + left/right rhombi for a unit cube.

    Vertical rise = W/2 so top is 2:1 diamond of size W×(W/2).
    Canvas is W×W (top occupies y=0..W/2-1, sides extend to y=W-1).
    """
    if w < 8 or w % 2:
        raise ValueError(f"cube width must be even >=8, got {w}")
    h = w // 2  # top diamond height / side rise
    # Top diamond at y=0..h-1
    top = (
        (w // 2, 0),
        (w - 1, h // 2),
        (w // 2, h - 1),
        (0, h // 2),
    )
    # Left face: left tip of top → bottom tip of top → down-left foot → down further
    # Standard: left rhombus under left half of top
    left = (
        (0, h // 2),
        (w // 2, h - 1),
        (w // 2, w - 1),
        (0, h // 2 + h),
    )
    right = (
        (w - 1, h // 2),
        (w // 2, h - 1),
        (w // 2, w - 1),
        (w - 1, h // 2 + h),
    )
    return CubeFaces(w=w, top=top, left=left, right=right)


def paint_diamond(
    size: IsoSize,
    fill_rgb: tuple[int, int, int],
    *,
    outline_rgb: tuple[int, int, int] | None = None,
    bg_rgb: tuple[int, int, int] = (255, 0, 255),
) -> Image.Image:
    """Solid-color diamond on key background."""
    im = Image.new("RGB", (size.w, size.h), bg_rgb)
    dr = ImageDraw.Draw(im)
    corners = diamond_corners(size.w, size.h)
    dr.polygon(list(corners), fill=fill_rgb)
    if outline_rgb is not None:
        dr.line(list(corners) + [corners[0]], fill=outline_rgb, width=1)
    return im


def sample_texture_on_diamond(
    size: IsoSize,
    texture: Image.Image,
    *,
    bg_rgb: tuple[int, int, int] = (255, 0, 255),
) -> Image.Image:
    """Fill diamond with texture pixels (tiled); outside = bg key."""
    tex = texture.convert("RGB")
    tw, th = tex.size
    tp = tex.load()
    im = Image.new("RGB", (size.w, size.h), bg_rgb)
    ip = im.load()
    assert tp is not None and ip is not None
    for y in range(size.h):
        for x in range(size.w):
            if in_diamond(x, y, size.w, size.h):
                ip[x, y] = tp[x % tw, y % th]
    return im


def mask_region_on_diamond(
    size: IsoSize,
    region: Iterable[tuple[int, int]],
) -> set[tuple[int, int]]:
    """Intersect an arbitrary pixel set with the diamond interior."""
    return {(x, y) for x, y in region if in_diamond(x, y, size.w, size.h)}
