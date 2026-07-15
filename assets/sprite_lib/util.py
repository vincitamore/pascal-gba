"""sprite_lib.util -- shared helpers used by every other module.

Keeps PIL out of the API surface where it can be: most callers take/return RGB tuples,
indexed arrays, or file paths. Module is pure (no I/O side effects except parse).
"""
from __future__ import annotations
import collections
import hashlib
import json
import math
from pathlib import Path
from typing import Iterable, Sequence


# ---------- parsing ----------

def parse_size(s: str) -> tuple[int, int]:
    """'32x32' -> (32, 32). Accepts 'x' or '*' or ','."""
    s = s.lower().strip()
    for sep in ("x", "*", ","):
        if sep in s:
            w, h = s.split(sep)
            return int(w), int(h)
    raise ValueError(f"bad size: {s!r}; expected WxH")


def parse_rgb(s: str) -> tuple[int, int, int]:
    """'255,0,128' -> (255, 0, 128). Also accepts '#FF0080'."""
    s = s.strip()
    if s.startswith("#"):
        s = s[1:]
        if len(s) != 6:
            raise ValueError(f"bad hex color: {s!r}")
        return int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16)
    parts = [int(x) for x in s.split(",")]
    if len(parts) != 3:
        raise ValueError(f"bad rgb: {s!r}; expected R,G,B or #RRGGBB")
    return parts[0], parts[1], parts[2]


# ---------- color tests ----------

def near(a: Sequence[int], b: Sequence[int], tol: int) -> bool:
    """Channel-wise distance test. True if all |a[i]-b[i]| <= tol."""
    return all(abs(a[i] - b[i]) <= tol for i in range(3))


def chroma_test_for(key: tuple[int, int, int] | Sequence[int],
                    strong_thr: int = 50, weak_thr: int = 30):
    """Return a brightness-invariant 'pixel is near this key' closure, or None
    when the key is achromatic (white/black/gray) and callers should drop to
    plain color-distance.

    The discriminator: a key has 'hot' channels (>128) and 'cold' channels
    (<128). A pixel is 'key-chroma' if every hot-cold channel pair shows the
    expected gap: `pixel[hot] - pixel[cold] > thr`. The strongest contrast pair
    gets `strong_thr`; weaker pairs get `weak_thr`. This matches the empirical
    magenta detector (R-G > 50, B-G > 30) and generalizes to green, cyan,
    yellow, red, blue.

    Worked examples (default thresholds):
      magenta (255,0,255): hot=R,B cold=G  -> R-G>50 AND B-G>30
      green   (0,255,0)  : hot=G   cold=R,B -> G-R>50 AND G-B>30
      cyan    (0,255,255): hot=G,B cold=R  -> G-R>50 AND B-R>30
      yellow  (255,255,0): hot=R,G cold=B  -> R-B>50 AND G-B>30
      red     (255,0,0)  : hot=R   cold=G,B -> R-G>50 AND R-B>30
      blue    (0,0,255)  : hot=B   cold=R,G -> B-R>50 AND B-G>30
      white/black/gray   : returns None (no chroma to discriminate on)
    """
    r, g, b = key[0], key[1], key[2]
    hot: list[int] = []
    cold: list[int] = []
    for i, v in enumerate((r, g, b)):
        if v > 128:
            hot.append(i)
        elif v < 128:
            cold.append(i)
    if not hot or not cold:
        return None
    # Strongest contrast pair = strongest-hot channel against strongest-cold.
    hot.sort(key=lambda i: -key[i])
    cold.sort(key=lambda i: key[i])
    pairs: list[tuple[int, int, int]] = []
    first = True
    for h in hot:
        for c in cold:
            pairs.append((h, c, strong_thr if first else weak_thr))
            first = False

    def is_chroma(px):
        for h, c, thr in pairs:
            if px[h] - px[c] <= thr:
                return False
        return True
    return is_chroma


def is_magenta_chroma(c: Sequence[int]) -> bool:
    """Backward-compat alias for chroma_test_for((255, 0, 255))(c).

    Brightness-invariant magenta/pink test: R-G > 50 AND B-G > 30. Catches
    vignetted 'uniform magenta' video backgrounds where edges render darker
    than the modal center; green/skin/black subjects never satisfy it.
    Prefer `chroma_test_for(key)` for non-magenta keys (per the per-faction
    key-color doctrine).
    """
    r, g, b = c[0], c[1], c[2]
    return (r - g) > 50 and (b - g) > 30


def make_bg_test(bg: tuple[int, int, int], tol: int, chroma: bool):
    """Closure: True iff a pixel is background.

    Composite of exact-color match (within tol) OR brightness-invariant chroma
    test (if enabled and the key is chromatic). The chroma test is auto-
    derived from `bg` via `chroma_test_for`, so per-faction keys (magenta,
    green, cyan, etc.) all get the right discriminator without manual config.
    Pre-bound so per-pixel iteration in hot loops doesn't re-read flags.
    """
    if chroma:
        is_chroma = chroma_test_for(bg)
        if is_chroma is not None:
            def is_bg(c):
                return near(c, bg, tol) or is_chroma(c)
            return is_bg
    def is_bg(c):
        return near(c, bg, tol)
    return is_bg


def modal_color(pixels: Iterable[Sequence[int]]) -> tuple[int, int, int]:
    """Most common RGB tuple in `pixels`. Robust to AA gradients on a key bg."""
    c = collections.Counter(pixels).most_common(1)[0][0]
    return tuple(c)


def detect_bg(im, method: str = "auto", tol: int = 20) -> tuple[int, int, int]:
    """Detect background color of an image.

    Methods:
      "modal"  : most common RGB tuple across the whole image. Legacy default.
                 Fails when the subject occupies >40-50% of the frame because
                 the mode lands on subject color, not key (witnessed during
                 the 2026-05-21 terrain probe).
      "corner" : modal color across small patches sampled from the four
                 corners. Robust when the subject fills the frame; matches
                 the pixel-art convention that key color owns the corners.
      "auto"   : corner if the four per-corner modes agree (within `tol` on
                 every channel), else fall back to image-modal. The default
                 strategy -- it picks the right method per image without
                 operator intervention.

    `tol` controls only the per-corner agreement test in "auto" mode (does NOT
    affect what the bake's bg-test does downstream).
    """
    if method not in ("auto", "corner", "modal"):
        raise ValueError(f"detect_bg: bad method {method!r}; expected auto|corner|modal")
    if method == "modal":
        return modal_color(im.getdata())
    w, h = im.size
    ps = max(4, min(32, min(w, h) // 16))
    px = im.load()
    per_corner_modes: list[tuple[int, int, int]] = []
    pooled: list[tuple[int, int, int]] = []
    for cx, cy in ((0, 0), (w - ps, 0), (0, h - ps), (w - ps, h - ps)):
        patch: list[tuple[int, int, int]] = []
        for y in range(cy, cy + ps):
            for x in range(cx, cx + ps):
                patch.append(tuple(px[x, y]))
        per_corner_modes.append(
            collections.Counter(patch).most_common(1)[0][0])
        pooled.extend(patch)
    corner_mode = collections.Counter(pooled).most_common(1)[0][0]
    if method == "corner":
        return corner_mode
    # auto: accept corner_mode only if all 4 per-corner modes agree.
    ref = per_corner_modes[0]
    if all(near(m, ref, tol) for m in per_corner_modes):
        return corner_mode
    return modal_color(im.getdata())


# ---------- GBA color / packing ----------

def bgr555(c: Sequence[int]) -> int:
    """RGB 0..255 -> GBA BGR555 halfword (0..0x7FFF)."""
    r, g, b = (c[0] >> 3), (c[1] >> 3), (c[2] >> 3)
    return (b << 10) | (g << 5) | r


def pack_4bpp_linear(indices: Sequence[int]) -> list[int]:
    """Pack [n0, n1, n2, n3, ...] into bytes [n1<<4|n0, n3<<4|n2, ...].

    Low nibble first (matches GBA 4bpp tile format). Used for previews and as the
    default emission path when --obj is not set.
    """
    out = []
    for i in range(0, len(indices), 2):
        lo = indices[i] & 0xF
        hi = (indices[i + 1] & 0xF) if i + 1 < len(indices) else 0
        out.append((hi << 4) | lo)
    return out


def pack_4bpp_obj(indices: Sequence[int], W: int, H: int) -> list[int]:
    """Pack pixel indices in GBA OBJ 8x8-tile / 1D-mapping order.

    Input is row-major scanline [W*H]; output is the same pixels reordered so that
    the GBA's OBJ DMA / direct VRAM copy lands them correctly without a runtime
    transpose. Each 8x8 tile is 32 bytes, packed low-nibble-first in row-major order
    within the tile.

    Requires W and H to be multiples of 8 (GBA OBJ hardware requirement).
    """
    if W % 8 or H % 8:
        raise ValueError(f"--obj requires W and H multiples of 8 (got {W}x{H})")
    tilesW = W // 8
    tilesH = H // 8
    out = [0] * (W * H // 2)
    for y in range(H):
        for x in range(W):
            tx = x >> 3
            ty = y >> 3
            tileNo = ty * tilesW + tx
            row = y & 7
            col = x & 7
            byteOff = tileNo * 32 + row * 4 + (col >> 1)
            v = indices[y * W + x] & 0xF
            if (col & 1) == 0:
                out[byteOff] |= v
            else:
                out[byteOff] |= v << 4
    return out


# ---------- autocrop ----------

def subject_bbox(img, bg: tuple[int, int, int], tol: int, chroma: bool,
                 thr_pct: float = 0.0) -> tuple[int, int, int, int] | None:
    """Subject bounding box from a foreground/background scan.

    `thr_pct > 0` activates threshold-based bbox (a row/col must hold at least
    thr_pct of its samples as non-bg to count) -- robust to border noise.
    `thr_pct == 0` accepts any non-bg pixel as evidence (cheaper, what the single
    bake_sprite path used).

    Returns (minx, miny, maxx, maxy) inclusive, or None if no subject found.
    """
    sw, sh = img.size
    step = max(1, min(sw, sh) // 256)
    is_bg = make_bg_test(bg, tol, chroma)
    px = img.load()
    if thr_pct <= 0:
        minx, miny, maxx, maxy = sw, sh, 0, 0
        any_fg = False
        for y in range(0, sh, step):
            for x in range(0, sw, step):
                if not is_bg(px[x, y]):
                    any_fg = True
                    if x < minx: minx = x
                    if y < miny: miny = y
                    if x > maxx: maxx = x
                    if y > maxy: maxy = y
        return (minx, miny, maxx, maxy) if any_fg else None
    # threshold path
    nx = len(range(0, sw, step))
    ny = len(range(0, sh, step))
    col_thr = max(2, int(thr_pct * ny))
    row_thr = max(2, int(thr_pct * nx))
    colcnt: dict[int, int] = {}
    rowcnt: dict[int, int] = {}
    for y in range(0, sh, step):
        for x in range(0, sw, step):
            if not is_bg(px[x, y]):
                colcnt[x] = colcnt.get(x, 0) + 1
                rowcnt[y] = rowcnt.get(y, 0) + 1
    xs = [x for x, c in colcnt.items() if c >= col_thr]
    ys = [y for y, c in rowcnt.items() if c >= row_thr]
    if not xs or not ys:
        return None
    return min(xs), min(ys), max(xs), max(ys)


def aspect_pad_box(box: tuple[int, int, int, int], canvas: tuple[int, int],
                   target: tuple[int, int], margin: int) -> tuple[int, int, int, int]:
    """Grow the bbox by `margin` then pad axis-symmetrically to the target aspect."""
    sw, sh = canvas
    W, H = target
    x0, y0, x1, y1 = box
    x0 = max(0, x0 - margin)
    y0 = max(0, y0 - margin)
    x1 = min(sw - 1, x1 + margin)
    y1 = min(sh - 1, y1 + margin)
    cw, ch = (x1 - x0 + 1), (y1 - y0 + 1)
    tar = W / H
    if cw / ch > tar:
        need = int(cw / tar)
        pad = (need - ch) // 2
        y0 = max(0, y0 - pad)
        y1 = min(sh - 1, y1 + pad)
    else:
        need = int(ch * tar)
        pad = (need - cw) // 2
        x0 = max(0, x0 - pad)
        x1 = min(sw - 1, x1 + pad)
    return x0, y0, x1 + 1, y1 + 1  # PIL convention: right/bottom exclusive


# ---------- .inc emit ----------

def emit_inc(out_path: Path | str, name: str, W: int, H: int,
             palette: list[tuple[int, int, int]],
             tile_bytes: list[int],
             frames: int = 1,
             obj_order: bool = False,
             include_transparent: bool = True,
             source_note: str = "",
             extra_const: dict[str, int] | None = None,
             map_words: list[int] | None = None) -> Path:
    """Write a Pascal {$I}-includable .inc with the canonical schema.

    Schema (consumed by sprite_smoke.pas, test ROMs, and game-side `uses`):
      {{ <source_note> }}
      const <NAME>_W = W;
            <NAME>_H = H;
            <NAME>_FRAMES = frames;        (always emitted, =1 for single sprites)
            <NAME>_OBJ_ORDER = 0|1;        (1 if tile bytes are in 8x8 tile order)
            [extra_const items];
        <NAME>_PAL: array[0..N] of Word = (...BGR555 halfwords...);
        <NAME>_TILES: array[0..M-1] of Byte = (... 4bpp packed ...);
        [<NAME>_MAP: array[0..K-1] of Word = (...);]   (bg-bake tilemaps only)

    `include_transparent` controls whether palette slot 0 = $0000 is prepended.
    True for OBJ sprites (slot 0 must be transparent); False for terrain BG tiles
    where every slot is opaque.

    `map_words` (bg-bake) are GBA text-BG screen entries: tile index in bits
    0-9, hflip bit 10, vflip bit 11, palette bank bits 12-15.
    """
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    L: list[str] = []
    note = source_note or "generated by sprite_lib"
    L.append(f"{{ {note} }}")
    L.append(f"const {name}_W = {W};")
    L.append(f"  {name}_H = {H};")
    L.append(f"  {name}_FRAMES = {frames};")
    L.append(f"  {name}_OBJ_ORDER = {1 if obj_order else 0};")
    if extra_const:
        for k, v in extra_const.items():
            L.append(f"  {name}_{k} = {v};")
    # palette
    pal_words: list[str] = []
    if include_transparent:
        pal_words.append("$0000")
    pal_words.extend(f"${bgr555(c):04X}" for c in palette)
    L.append(f"  {name}_PAL: array[0..{len(pal_words) - 1}] of Word = (")
    L.append("    " + ", ".join(pal_words) + ");")
    # tiles
    L.append(f"  {name}_TILES: array[0..{len(tile_bytes) - 1}] of Byte = (")
    rows = [", ".join(f"${b:02X}" for b in tile_bytes[i:i + 16])
            for i in range(0, len(tile_bytes), 16)]
    L.append("    " + ",\n    ".join(rows) + ");")
    # tilemap (bg-bake)
    if map_words is not None:
        L.append(f"  {name}_MAP: array[0..{len(map_words) - 1}] of Word = (")
        mrows = [", ".join(f"${w:04X}" for w in map_words[i:i + 12])
                 for i in range(0, len(map_words), 12)]
        L.append("    " + ",\n    ".join(mrows) + ");")
    atomic_write(out_path, "\n".join(L) + "\n")
    return out_path


def read_inc_name(inc_path: Path | str) -> str:
    """Find the NAME prefix in a baked .inc (e.g. 'SOLDIER' from 'const SOLDIER_W = 32;')."""
    text = Path(inc_path).read_text()
    import re
    m = re.search(r"const\s+(\w+)_W\s*=", text)
    if not m:
        raise ValueError(f"no NAME_W const found in {inc_path}")
    return m.group(1)


# ---------- hashing / caching ----------

def stable_hash(obj) -> str:
    """16-hex sha256 over a JSON-serializable value. Order-stable."""
    blob = json.dumps(obj, sort_keys=True, default=str).encode()
    return hashlib.sha256(blob).hexdigest()[:16]


def file_sha(path: Path | str) -> str:
    """Full sha256 of a file (used for ref-image cache keys)."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


# ---------- json out / atomic write ----------

def atomic_write(path: Path | str, data: bytes | str) -> Path:
    """Write to a sibling .tmp then rename. Tolerates concurrent readers."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    if isinstance(data, str):
        tmp.write_text(data, encoding="utf-8")
    else:
        tmp.write_bytes(data)
    tmp.replace(path)
    return path


def json_print(record: dict, fp=None) -> None:
    """Emit a single-line JSON record on stdout (or `fp`). For --json subcommand output."""
    import sys
    if fp is None:
        fp = sys.stdout
    fp.write(json.dumps(record, sort_keys=False) + "\n")
    fp.flush()
