#!/usr/bin/env python3
"""Offline smoke suite for the sprite asset pipeline.

Default run is keyless and makes zero network calls. Live-network stages require
both --with-key and --i-understand-this-costs-money.

Exit codes:
  0  all scenarios pass or skip
  1  one or more assertion failures
  2  harness / setup error
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable  # Callable used without nested-param form (firewall)

from PIL import Image

# ---------------------------------------------------------------------------
# paths
# ---------------------------------------------------------------------------

HERE = Path(__file__).resolve().parent
ASSETS = HERE.parent
REPO = ASSETS.parent
SPRITE_PY = ASSETS / "sprite.py"
TEST_INC = REPO / "test" / "sprite_input.inc"
FPC_CANDIDATES = [
    Path(r"C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe"),
    Path(r"C:\fpcupdeluxe\fpc\bin\x86_64-win64\fpc.exe"),
]

sys.path.insert(0, str(ASSETS))
sys.path.insert(0, str(HERE))

from fixtures import (  # noqa: E402
    NINE_SLICE_COLORS,
    gen_anim_frames,
    gen_bake_source,
    gen_font_sheet,
    gen_mirror_texture,
    gen_nine_slice_source,
    gen_pick_sequence,
    gen_texture_source,
)
from fixtures.gen_bake_source import magenta_pixel_count, subject_center  # noqa: E402
from fixtures.gen_font_sheet import expected_glyph_bitmap  # noqa: E402

from sprite_lib import cost as cost_mod  # noqa: E402
from sprite_lib import review  # noqa: E402
from sprite_lib import util  # noqa: E402
from sprite_lib import xai  # noqa: E402
from sprite_lib.tile import make_seamless_mirror, make_seamless_offset  # noqa: E402


# ---------------------------------------------------------------------------
# result / reporting
# ---------------------------------------------------------------------------

class Fail(Exception):
    """Scenario assertion failure."""


class Skip(Exception):
    """Scenario intentionally skipped."""


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _emit_ndjson(rec: dict) -> None:
    sys.stdout.write(json.dumps(rec, sort_keys=False) + "\n")
    sys.stdout.flush()


def _common_flags(td: Path) -> list[str]:
    """Every path-bearing root, explicit -- never rely on cwd defaults."""
    return [
        "--json",
        "--auth", str(td / "no-such-auth.json"),
        "--ledger", str(td / "ledger.jsonl"),
        "--cache-dir", str(td / "cache"),
        "--manifest-dir", str(td / "manifests"),
    ]


def _scrub_env() -> dict[str, str]:
    """Child env with no xAI credentials and no mock unless the scenario sets it."""
    env = os.environ.copy()
    env.pop("XAI_API_KEY", None)
    env.pop("SPRITE_MOCK", None)
    # isolate path roots so a parent SPRITE_* cannot leak into the child
    env.pop("SPRITE_CACHE_DIR", None)
    env.pop("SPRITE_LEDGER", None)
    env.pop("SPRITE_MANIFEST_DIR", None)
    return env


# Top-level commands whose next token is a nested subparser verb (not a positional).
_NESTED_SUBS = frozenset({"manifest", "canonical"})


def run_cli(td: Path, argv: list[str], *, env: dict[str, str] | None = None,
            timeout: int = 180) -> tuple[int, dict | None, str, str]:
    """Invoke sprite.py; return (exit_code, json_record_or_None, stdout, stderr).

    Common path flags live on the subcommand parser (not the top-level). For a
    plain command they follow the first token; for nested verbs (manifest set,
    canonical get, ...) they follow the second token so --json is actually
    consumed by the leaf parser.
    """
    if not argv:
        raise ValueError("run_cli: empty argv")
    flags = _common_flags(td)
    if argv[0] in _NESTED_SUBS and len(argv) >= 2:
        cmd = [sys.executable, str(SPRITE_PY), argv[0], argv[1]] + flags + list(argv[2:])
    else:
        cmd = [sys.executable, str(SPRITE_PY), argv[0]] + flags + list(argv[1:])
    child_env = env if env is not None else _scrub_env()
    r = subprocess.run(
        cmd, capture_output=True, text=True, env=child_env,
        cwd=str(td), timeout=timeout,
    )
    rec = None
    out = r.stdout.strip()
    if out:
        # last non-empty line that parses as JSON wins
        for line in reversed(out.splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
                break
            except json.JSONDecodeError:
                continue
    return r.returncode, rec, r.stdout, r.stderr


def _require(cond: bool, msg: str) -> None:
    if not cond:
        raise Fail(msg)


def _near(a: tuple[int, ...], b: tuple[int, ...], tol: int = 12) -> bool:
    return all(abs(int(x) - int(y)) <= tol for x, y in zip(a, b))


def _channel_delta(a: tuple[int, int, int], b: tuple[int, int, int]) -> int:
    return sum(abs(int(x) - int(y)) for x, y in zip(a, b))


def _seed_cache_png(cache_dir: Path, ck: str, color: tuple[int, int, int] = (10, 20, 30)) -> Path:
    cache_dir.mkdir(parents=True, exist_ok=True)
    p = cache_dir / f"{ck}.png"
    Image.new("RGB", (8, 8), color).save(p)
    return p


def _seed_cache_mp4(cache_dir: Path, ck: str) -> Path:
    """Minimal non-empty stand-in; cache-hit only copies bytes, never demuxes."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    p = cache_dir / f"{ck}.mp4"
    # ftyp-ish dummy payload (not a real mp4; cache path never parses it)
    p.write_bytes(b"\x00\x00\x00\x18ftypisom\x00\x00\x00\x00isomiso2" + b"\x00" * 32)
    return p


def _gen_cache_key(prompt: str, model: str, resolution: str = "1k",
                   aspect_ratio: str = "1:1") -> str:
    return util.stable_hash({
        "shape_version": xai.SHAPE_VERSION,
        "op": "generate_image",
        "model": model,
        "prompt": prompt,
        "resolution": resolution,
        "aspect_ratio": aspect_ratio,
    })


def _edit_cache_key(prompt: str, model: str, ref_path: Path,
                    resolution: str = "1k",
                    aspect_ratio: str | None = None) -> str:
    return util.stable_hash({
        "shape_version": xai.SHAPE_VERSION,
        "op": "edit_image",
        "model": model,
        "prompt": prompt,
        "resolution": resolution,
        "aspect_ratio": aspect_ratio,
        "ref_keys": [f"sha:{util.file_sha(ref_path)}"],
    })


def _video_cache_key(prompt: str, model: str, duration: int = 3,
                     aspect_ratio: str = "1:1", resolution: str = "720p",
                     mode: str = "t2v") -> str:
    return util.stable_hash({
        "shape_version": xai.SHAPE_VERSION,
        "op": "generate_video",
        "mode": mode,
        "model": model,
        "prompt": prompt,
        "duration": duration,
        "aspect_ratio": aspect_ratio,
        "resolution": resolution,
        "start_key": None,
        "ref_keys": [],
    })


def _find_fpc() -> Path | None:
    for p in FPC_CANDIDATES:
        if p.exists():
            return p
    which = shutil.which("fpc")
    return Path(which) if which else None


def _mock_supported() -> bool:
    src = (ASSETS / "sprite_lib" / "xai.py").read_text(encoding="utf-8")
    return "SPRITE_MOCK" in src and "_mock_enabled" in src


@contextmanager
def _restore_shipped_inc():
    """Snapshot + restore test/sprite_input.inc around a critical section."""
    if not TEST_INC.exists():
        raise RuntimeError(f"shipped fixture missing: {TEST_INC}")
    before = TEST_INC.read_bytes()
    try:
        yield before
    finally:
        TEST_INC.write_bytes(before)


# ===========================================================================
# scenarios
# ===========================================================================

def sc_cost(td: Path) -> str:
    ledger = td / "ledger.jsonl"
    ticks = [100, 200_000_000, 50]
    for i, t in enumerate(ticks):
        cost_mod.append(
            {"op": f"gen-syn-{i}", "cost_in_usd_ticks": t},
            ledger,
        )
    code, rec, _, err = run_cli(td, ["cost"])
    _require(code == 0, f"cost exit {code}: {err}")
    _require(rec is not None, "cost: no JSON record")
    expected_ticks = sum(ticks)
    _require(rec["total_ticks"] == expected_ticks,
             f"total_ticks {rec['total_ticks']} != {expected_ticks}")
    expected_usd = round(expected_ticks * cost_mod.USD_PER_TICK, 4)
    _require(abs(rec["total_usd"] - expected_usd) < 1e-9,
             f"total_usd {rec['total_usd']} != {expected_usd}")
    return f"ticks={expected_ticks} usd={expected_usd}"


def sc_cache_list_clear(td: Path) -> str:
    cache = td / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    names = ["aaa1111111111111.png", "bbb2222222222222.png"]
    for n in names:
        (cache / n).write_bytes(b"x")
    code, rec, _, err = run_cli(td, ["cache", "list"])
    _require(code == 0, f"cache list exit {code}: {err}")
    _require(rec["n"] == 2, f"list n={rec.get('n')}")
    listed = sorted(f["name"] for f in rec["files"])
    _require(listed == sorted(names), f"files={listed}")
    code, rec, _, err = run_cli(td, ["cache", "clear"])
    _require(code == 0, f"cache clear exit {code}: {err}")
    _require(rec["removed"] == 2, f"removed={rec.get('removed')}")
    code, rec, _, err = run_cli(td, ["cache", "list"])
    _require(code == 0 and rec["n"] == 0, f"post-clear n={rec.get('n')}")
    return "list+clear ok"


def sc_manifest(td: Path) -> str:
    # set prompt, then output; merge must preserve prompt
    code, rec, _, err = run_cli(td, [
        "manifest", "set", "unit_a", "--kind", "sprite",
        "--faction", "red_faction", "--unit", "soldier",
        "--prompt", "hello-prompt",
    ])
    _require(code == 0, f"manifest set1: {err}")
    code, rec, _, err = run_cli(td, [
        "manifest", "set", "unit_a", "--kind", "sprite",
        "--output", "gen/a.inc",
    ])
    _require(code == 0, f"manifest set2: {err}")
    code, rec, _, err = run_cli(td, ["manifest", "get", "unit_a"])
    _require(code == 0 and rec.get("found") is True, f"get: {rec}")
    _require(rec.get("prompt") == "hello-prompt", "merge lost prompt")
    _require(rec.get("output") == "gen/a.inc", "output not set")
    # --no-merge replaces
    code, rec, _, err = run_cli(td, [
        "manifest", "set", "unit_a", "--kind", "tile",
        "--output", "only.inc", "--no-merge",
    ])
    _require(code == 0, f"no-merge: {err}")
    code, rec, _, err = run_cli(td, ["manifest", "get", "unit_a"])
    _require(rec.get("prompt") is None or "prompt" not in rec or rec.get("prompt") is None,
             f"no-merge should drop prompt; got {rec.get('prompt')}")
    # seed more for list filters
    for asset, faction, unit, kind in [
        ("unit_b", "blue_faction", "scout", "sprite"),
        ("tile_g", "red_faction", "grass", "tile"),
    ]:
        run_cli(td, [
            "manifest", "set", asset, "--kind", kind,
            "--faction", faction, "--unit", unit,
        ])
    code, rec, _, err = run_cli(td, [
        "manifest", "list", "--faction", "red_faction",
    ])
    _require(code == 0, f"list: {err}")
    assets = {m["asset"] for m in rec["manifests"]}
    _require("tile_g" in assets, f"red filter missing tile_g: {assets}")
    _require("unit_b" not in assets, f"red filter leaked unit_b: {assets}")
    return f"list n={rec['n']}"


def sc_canonical(td: Path) -> str:
    for asset, unit in [
        ("red_soldier_map", "soldier"),
        ("red_soldier_atk", "soldier"),
        ("red_soldier_idle", "soldier"),
    ]:
        code, _, _, err = run_cli(td, [
            "manifest", "set", asset, "--kind", "sprite",
            "--faction", "red_faction", "--unit", unit,
        ])
        _require(code == 0, f"seed {asset}: {err}")
    code, rec, _, err = run_cli(td, ["canonical", "set", "red_soldier_map"])
    _require(code == 0, f"set A: {err}")
    key = "red_faction.soldier"
    _require(rec.get(key, {}).get("canonical") == "red_soldier_map", f"A not canon: {rec}")
    code, rec, _, err = run_cli(td, ["canonical", "set", "red_soldier_atk"])
    _require(code == 0, f"set B: {err}")
    slot = rec.get(key, {})
    _require(slot.get("canonical") == "red_soldier_atk", f"B not canon: {slot}")
    _require("red_soldier_map" in slot.get("variants", []), f"A not demoted: {slot}")
    code, rec, _, err = run_cli(td, ["canonical", "variant", "red_soldier_idle"])
    _require(code == 0, f"variant C: {err}")
    slot = rec.get(key, {})
    _require(slot.get("canonical") == "red_soldier_atk", "C disturbed canon")
    _require("red_soldier_idle" in slot.get("variants", []), f"C not variant: {slot}")
    # edge: variant with no prior canon for a new key
    run_cli(td, [
        "manifest", "set", "blue_scout_map", "--kind", "sprite",
        "--faction", "blue_faction", "--unit", "scout",
    ])
    code, rec, _, err = run_cli(td, ["canonical", "variant", "blue_scout_map"])
    _require(code == 0, f"variant-as-canon: {err}")
    bslot = rec.get("blue_faction.scout", {})
    _require(bslot.get("canonical") == "blue_scout_map",
             f"variant-without-canon should promote: {bslot}")
    code, rec, _, err = run_cli(td, ["canonical", "list"])
    _require(code == 0 and "red_faction.soldier" in rec.get("entries", {}), "list incomplete")
    code, rec, _, err = run_cli(td, [
        "canonical", "get", "--faction", "red_faction", "--unit", "soldier",
    ])
    _require(code == 0, f"get: {err}")
    _require(rec.get("slot", {}).get("canonical") == "red_soldier_atk", f"get slot {rec}")
    return "canonical ok"


def sc_bake_single(td: Path) -> str:
    src = td / "bake_src.png"
    gen_bake_source(src)
    out = td / "unit.inc"
    code, rec, _, err = run_cli(td, [
        "bake", str(src), "--out", str(out), "--name", "UNIT",
        "--size", "32x32", "--no-preview",
    ])
    _require(code == 0, f"bake: {err} {rec}")
    insp = review.inspect(out)
    _require(insp["size"] == [32, 32], f"size {insp['size']}")
    _require(insp["frames"] == 1, f"frames {insp['frames']}")
    _require(insp["obj_order"] is True, "expected default OBJ order")
    bpf = 32 * 32 // 2
    parsed = review._parse_inc(out.read_text())
    _require(len(parsed["bytes"]) == bpf, f"tile bytes {len(parsed['bytes'])} != {bpf}")
    _require(rec["colors_used"] <= 15, f"colors_used {rec['colors_used']}")
    _require(insp["frame_stats"][0]["transparent_px"] > 0, "no transparent px keyed")
    imgs = review.render_inc_frames(out)
    # center of subject should be near red after quantize
    cx, cy = 16, 16
    pix = imgs[0].getpixel((cx, cy))
    # not the transparent gray placeholder
    _require(pix != (60, 60, 60), f"center is transparent gray: {pix}")
    _require(_near(pix, (255, 0, 0), tol=48) or pix[0] > 120,
             f"center not reddish: {pix}")
    return f"colors={rec['colors_used']} transp={insp['frame_stats'][0]['transparent_px']}"


def sc_bake_linear_parity(td: Path) -> str:
    src = td / "bake_src.png"
    gen_bake_source(src)
    out_obj = td / "obj.inc"
    out_lin = td / "lin.inc"
    for out, extra in [(out_obj, []), (out_lin, ["--linear"])]:
        code, _, _, err = run_cli(td, [
            "bake", str(src), "--out", str(out), "--name", "PAR",
            "--size", "16x16", "--no-preview", *extra,
        ])
        _require(code == 0, f"bake {'linear' if extra else 'obj'}: {err}")
    a = review.render_inc_frames(out_obj)[0]
    b = review.render_inc_frames(out_lin)[0]
    total = sum(_channel_delta(pa, pb) for pa, pb in zip(a.getdata(), b.getdata()))
    _require(total == 0, f"obj vs linear render delta={total}")
    return "obj/linear render identical"


def sc_bake_colors_cap(td: Path) -> str:
    src = td / "rich.png"
    # multi-color field to force palette pressure
    im = Image.new("RGB", (64, 64), (255, 0, 255))
    for y in range(8, 56):
        for x in range(8, 56):
            im.putpixel((x, y), ((x * 7) % 256, (y * 11) % 256, (x * y) % 256))
    im.save(src)
    out = td / "rich.inc"
    code, rec, _, err = run_cli(td, [
        "bake", str(src), "--out", str(out), "--name", "RICH",
        "--size", "32x32", "--colors", "100", "--no-preview",
    ])
    _require(code == 0, f"bake colors100: {err}")
    _require(rec["colors_used"] <= 15, f"colors_used {rec['colors_used']} > 15")
    insp = review.inspect(out)
    # palette includes slot 0; visible colors_used in record is len(palette) without slot0
    _require(len(insp["palette"]) <= 16, f"palette len {len(insp['palette'])}")
    return f"capped colors_used={rec['colors_used']}"


def sc_bake_nonsquare(td: Path) -> str:
    src = td / "bake_src.png"
    gen_bake_source(src)
    out = td / "tall.inc"
    code, rec, _, err = run_cli(td, [
        "bake", str(src), "--out", str(out), "--name", "TALL",
        "--size", "16x32", "--no-preview",
    ])
    _require(code == 0, f"bake 16x32: {err}")
    _require(rec["size"] == [16, 32], f"size {rec['size']}")
    insp = review.inspect(out)
    _require(insp["size"] == [16, 32], f"inspect size {insp['size']}")
    return "16x32 ok"


def sc_anim(td: Path) -> str:
    paths = gen_anim_frames(4, td / "anim_frames")
    out = td / "anim.inc"
    code, rec, _, err = run_cli(td, [
        "anim", *[str(p) for p in paths],
        "--out", str(out), "--name", "WALK",
        "--size", "32x32", "--no-preview",
    ])
    _require(code == 0, f"anim: {err}")
    _require(rec["frames"] == 4, f"frames={rec.get('frames')}")
    text = out.read_text()
    pal_hits = len(re.findall(r"WALK_PAL\b", text))
    # one declaration line pattern NAME_PAL:
    pal_decl = len(re.findall(r"WALK_PAL\s*:", text))
    _require(pal_decl == 1, f"expected one WALK_PAL array, got {pal_decl}")
    canvas = rec.get("canvas")
    _require(canvas is not None and len(canvas) == 4, f"canvas={canvas}")
    # re-crop each source with returned canvas -> identical dims
    cw = canvas[2] - canvas[0]
    ch = canvas[3] - canvas[1]
    for p in paths:
        crop = Image.open(p).crop(tuple(canvas))
        _require(crop.size == (cw, ch), f"crop size {crop.size} != {(cw, ch)}")
    return f"frames=4 canvas={canvas}"


def sc_ui_bake(td: Path) -> str:
    src = td / "ns.png"
    gen_nine_slice_source(src)
    out = td / "panel.inc"
    # Source is solid per-cell color with no key bg. Pin a magenta key that is
    # absent from the fixture so bg detection does not treat TL as transparent.
    code, rec, _, err = run_cli(td, [
        "ui-bake", str(src), "--out", str(out), "--name", "PANEL",
        "--cell", "8x8", "--no-preview",
        "--bg", "#FF00FF", "--no-chroma",
    ])
    _require(code == 0, f"ui-bake: {err}")
    _require(rec.get("frames") == 9 or rec.get("slice_index") is not None, f"rec={rec}")
    si = rec.get("slice_index") or {}
    expected = {"NS_TL": 0, "NS_T": 1, "NS_TR": 2, "NS_L": 3, "NS_C": 4,
                "NS_R": 5, "NS_BL": 6, "NS_B": 7, "NS_BR": 8}
    _require(si == expected, f"slice_index {si}")
    text = out.read_text()
    for k, v in expected.items():
        _require(re.search(rf"PANEL_{k}\s*=\s*{v}", text), f"missing const {k}={v}")
    frames = review.render_inc_frames(out)
    _require(len(frames) == 9, f"frames {len(frames)}")
    for i, want in enumerate(NINE_SLICE_COLORS):
        # sample center of cell after quantize
        pix = frames[i].getpixel((4, 4))
        if pix == (60, 60, 60):
            # transparent placeholder -- cell may have been keyed if color near magenta
            # our colors are not magenta; fail
            raise Fail(f"cell {i} fully transparent")
        _require(_near(pix, want, tol=40), f"cell {i} pix {pix} !~ {want}")
    return "9 cells ok"


def sc_font_bake(td: Path) -> str:
    src = td / "font.png"
    cols, rows = 4, 2
    gen_font_sheet(cols, rows, src)
    out = td / "font.inc"
    code, rec, _, err = run_cli(td, [
        "font-bake", str(src), "--out", str(out), "--name", "FNT",
        "--grid", f"{cols}x{rows}", "--glyph-size", "8x8",
        "--start-codepoint", "0x20", "--no-preview", "--no-chroma",
        "--bg", "#000000",
    ])
    _require(code == 0, f"font-bake: {err}")
    _require(rec["glyph_count"] == cols * rows, f"glyph_count={rec.get('glyph_count')}")
    _require(rec["end_codepoint"] == 0x20 + cols * rows - 1,
             f"end={rec.get('end_codepoint')}")
    frames = review.render_inc_frames(out)
    _require(len(frames) == cols * rows, f"frames={len(frames)}")
    # zero-tolerance B/W: fg near white, bg transparent gray or black-mapped
    for i, fr in enumerate(frames):
        pat = expected_glyph_bitmap(i)
        for y in range(8):
            for x in range(8):
                pix = fr.getpixel((x, y))
                if pat[y][x]:
                    # fg should be bright (not the transparent gray)
                    _require(sum(pix) > 200 or pix[0] > 180,
                             f"glyph {i} fg@{x},{y}={pix}")
                else:
                    # bg -> transparent placeholder (60,60,60) or near-black palette
                    _require(pix == (60, 60, 60) or sum(pix) < 40,
                             f"glyph {i} bg@{x},{y}={pix}")
    return f"glyphs={rec['glyph_count']}"


def sc_tile_offset(td: Path) -> str:
    src = td / "tex.png"
    gen_texture_source(src, size=32)
    # measure seam on unwrapped resize
    raw = Image.open(src).convert("RGB").resize((32, 32), Image.BOX)
    mid = 16
    raw_delta = _channel_delta(raw.getpixel((0, mid)), raw.getpixel((31, mid)))
    out = td / "tile.inc"
    code, rec, _, err = run_cli(td, [
        "tile", str(src), "--out", str(out), "--name", "WATER",
        "--size", "32x32", "--method", "offset",
    ])
    _require(code == 0, f"tile offset: {err}")
    # preview path from make_tile
    prev = Path(str(out) + ".3x3.png")
    if not prev.exists():
        # alternate naming
        candidates = list(td.glob("*.3x3.png"))
        _require(candidates, "no 3x3 preview")
        prev = candidates[0]
    pim = Image.open(prev)
    # 3x3 at default scale from make_tile -- check dims via tile3x3 path too
    scale = 4
    # also run tile3x3 for explicit dim check
    t3 = td / "t3.png"
    code2, rec2, _, err2 = run_cli(td, [
        "tile3x3", str(src), "--out", str(t3), "--scale", str(scale),
    ])
    _require(code2 == 0, f"tile3x3: {err2}")
    t3im = Image.open(t3)
    _require(t3im.size == (32 * 3 * scale, 32 * 3 * scale), f"tile3x3 size {t3im.size}")
    # seam continuity: apply offset method ourselves and compare wrap edge
    seamless = make_seamless_offset(raw)
    sm_delta = _channel_delta(seamless.getpixel((0, mid)), seamless.getpixel((31, mid)))
    _require(sm_delta < raw_delta or sm_delta <= 30,
             f"offset seam not improved: raw={raw_delta} seamless={sm_delta}")
    return f"seam raw={raw_delta} seamless={sm_delta}"


def sc_tile_mirror(td: Path) -> str:
    src = td / "mir.png"
    gen_mirror_texture(src, size=32)
    raw = Image.open(src).convert("RGB").resize((32, 32), Image.BOX)
    seamless = make_seamless_mirror(raw)
    W, H = seamless.size
    hw, hh = W // 2, H // 2
    # quadrant flip relations
    for y in range(hh):
        for x in range(hw):
            a = seamless.getpixel((x, y))
            b = seamless.getpixel((W - 1 - x, y))
            c = seamless.getpixel((x, H - 1 - y))
            d = seamless.getpixel((W - 1 - x, H - 1 - y))
            _require(a == b, f"LR mirror fail at {x},{y}: {a}!={b}")
            _require(a == c, f"TB mirror fail at {x},{y}: {a}!={c}")
            _require(a == d, f"180 fail at {x},{y}: {a}!={d}")
    out = td / "mir.inc"
    code, _, _, err = run_cli(td, [
        "tile", str(src), "--out", str(out), "--name", "MIRR",
        "--size", "32x32", "--method", "mirror", "--no-preview",
    ])
    _require(code == 0, f"tile mirror: {err}")
    return "mirror quadrants exact"


def sc_pick(td: Path) -> str:
    period = 8
    paths = gen_pick_sequence(period=period, cycles=3, out_dir=td / "pick")
    code, rec, _, err = run_cli(td, [
        "pick", *[str(p) for p in paths], "--k", "4", "--min-loop", "8",
    ])
    _require(code == 0, f"pick: {err}")
    # loop_len should recover period (or be >= min_loop floor)
    L = rec.get("loop_len")
    _require(L is not None, f"no loop_len: {rec}")
    _require(L == period or abs(L - period) <= 1,
             f"loop_len={L} expected ~{period}")
    picks = rec.get("picks") or []
    _require(len(picks) <= 4, f"k overflow {len(picks)}")
    for p in picks:
        _require(0 <= p["index"] < L, f"index {p['index']} out of [0,{L})")
    return f"loop_len={L} picks={len(picks)}"


def sc_montage(td: Path) -> str:
    paths = []
    for i in range(5):
        p = td / f"m{i}.png"
        Image.new("RGB", (16, 12), (i * 40, 80, 120)).save(p)
        paths.append(p)
    out = td / "mont.png"
    pad = 4
    code, rec, _, err = run_cli(td, [
        "montage", *[str(p) for p in paths], "--out", str(out),
        "--cols", "0", "--pad", str(pad),
    ])
    _require(code == 0, f"montage: {err}")
    n = 5
    cols = max(1, math.ceil(math.sqrt(n)))
    rows = math.ceil(n / cols)
    cw, ch = 16, 12
    want = (cols * cw + (cols + 1) * pad, rows * ch + (rows + 1) * pad)
    im = Image.open(out)
    _require(im.size == want, f"size {im.size} != {want}")
    return f"size={im.size}"


def sc_gif(td: Path) -> str:
    paths = gen_anim_frames(4, td / "gif_frames")
    out = td / "out.gif"
    code, rec, _, err = run_cli(td, [
        "gif", *[str(p) for p in paths], "--out", str(out), "--scale", "0",
    ])
    _require(code == 0, f"gif: {err}")
    im = Image.open(out)
    n = getattr(im, "n_frames", 1)
    _require(n == 4, f"n_frames={n}")
    w, h = 64, 64
    scale = max(1, 192 // max(w, h))
    _require(im.size == (w * scale, h * scale), f"gif size {im.size}")
    return f"frames={n} scale={scale}"


def sc_tile3x3_inc(td: Path) -> str:
    src = td / "bake_src.png"
    gen_bake_source(src)
    inc = td / "t.inc"
    run_cli(td, [
        "bake", str(src), "--out", str(inc), "--name", "T",
        "--size", "16x16", "--no-preview",
    ])
    out = td / "t3inc.png"
    scale = 3
    code, rec, _, err = run_cli(td, [
        "tile3x3", str(inc), "--out", str(out), "--scale", str(scale),
    ])
    _require(code == 0, f"tile3x3 inc: {err}")
    im = Image.open(out)
    _require(im.size == (16 * 3 * scale, 16 * 3 * scale), f"size {im.size}")
    return f"size={im.size}"


def sc_inspect(td: Path) -> str:
    src = td / "bake_src.png"
    gen_bake_source(src)
    inc = td / "ins.inc"
    run_cli(td, [
        "bake", str(src), "--out", str(inc), "--name", "INS",
        "--size", "16x16", "--no-preview",
    ])
    code, rec, _, err = run_cli(td, ["inspect", str(inc)])
    _require(code == 0, f"inspect: {err}")
    # golden-by-construction: recompute via library and match CLI record
    lib = review.inspect(inc)
    _require(rec["size"] == lib["size"], "size mismatch")
    _require(rec["frame_stats"][0]["transparent_px"]
             == lib["frame_stats"][0]["transparent_px"], "transp mismatch")
    _require(rec["frame_stats"][0]["colors_used"]
             == lib["frame_stats"][0]["colors_used"], "colors_used mismatch")
    return f"transp={rec['frame_stats'][0]['transparent_px']}"


def sc_palette(td: Path) -> str:
    src = td / "bake_src.png"
    gen_bake_source(src)
    inc = td / "pal.inc"
    run_cli(td, [
        "bake", str(src), "--out", str(inc), "--name", "PAL",
        "--size", "16x16", "--no-preview",
    ])
    out = td / "sw.png"
    swatch = 32
    code, rec, _, err = run_cli(td, [
        "palette", str(inc), "--out", str(out), "--swatch", str(swatch),
    ])
    _require(code == 0, f"palette: {err}")
    parsed = review._parse_inc(inc.read_text())
    N = len(parsed["palette_rgb"])
    want = ((N * swatch + N + 1) * 2, (swatch + 2) * 2)
    im = Image.open(out)
    _require(im.size == want, f"swatch size {im.size} != {want}")
    return f"N={N} size={im.size}"


def sc_diff_identity(td: Path) -> str:
    p = td / "same.png"
    Image.new("RGB", (8, 8), (12, 34, 56)).save(p)
    out = td / "d.png"
    code, rec, _, err = run_cli(td, [
        "diff", str(p), str(p), "--out", str(out),
    ])
    _require(code == 0, f"diff id: {err}")
    _require(rec["total_channel_delta"] == 0, f"total={rec['total_channel_delta']}")
    _require(rec["max_pixel_delta"] == 0, f"max={rec['max_pixel_delta']}")
    _require(rec["avg_pixel_delta"] == 0.0, f"avg={rec['avg_pixel_delta']}")
    return "identity zero"


def sc_diff_known(td: Path) -> str:
    a = td / "a.png"
    b = td / "b.png"
    Image.new("RGB", (4, 4), (0, 0, 0)).save(a)
    imb = Image.new("RGB", (4, 4), (0, 0, 0))
    # one pixel differs by (10, 20, 30) -> sum 60
    imb.putpixel((1, 1), (10, 20, 30))
    imb.save(b)
    out = td / "dk.png"
    # amp default 4 amplifies delta map but stats use amplified image in review.diff
    # total_channel_delta is sum over amplified delta pixels
    code, rec, _, err = run_cli(td, [
        "diff", str(a), str(b), "--out", str(out), "--amp", "1",
    ])
    _require(code == 0, f"diff known: {err}")
    # with amp=1: one pixel contributes 10+20+30 = 60
    _require(rec["total_channel_delta"] == 60,
             f"total={rec['total_channel_delta']} want 60")
    _require(rec["max_pixel_delta"] == 60, f"max={rec['max_pixel_delta']}")
    # avg = 60 / (4*4*3) = 60/48 = 1.25
    _require(abs(rec["avg_pixel_delta"] - 1.25) < 1e-9,
             f"avg={rec['avg_pixel_delta']}")
    return "known-delta exact"


def sc_recolor(td: Path) -> str:
    src = td / "bake_src.png"
    gen_bake_source(src)
    inc = td / "rc_in.inc"
    run_cli(td, [
        "bake", str(src), "--out", str(inc), "--name", "RC",
        "--size", "16x16", "--no-preview",
    ])
    out = td / "rc_out.inc"
    # include slot 0 in map (must be skipped for rewrite) plus a real slot
    code, rec, _, err = run_cli(td, [
        "recolor", str(inc), "--out", str(out),
        "--map", "0:#FFFFFF,1:#00FF00",
    ])
    _require(code == 0, f"recolor: {err}")
    _require(sorted(rec["remapped_slots"]) == [0, 1],
             f"remapped_slots={rec.get('remapped_slots')}")
    pa = review._parse_inc(inc.read_text())
    pb = review._parse_inc(out.read_text())
    _require(pa["bytes"] == pb["bytes"], "tile bytes changed")
    _require(pb["palette_rgb"][0] == pa["palette_rgb"][0], "slot 0 rewritten")
    # slot 1 should move toward green (BGR555 quantize)
    g = pb["palette_rgb"][1]
    _require(g[1] >= g[0] and g[1] >= g[2], f"slot1 not greenish: {g}")
    return "tiles identical, slot0 preserved"


def sc_rekey(td: Path) -> str:
    src = td / "bake_src.png"
    gen_bake_source(src)
    out = td / "rekeyed.png"
    # exact magenta count = total - subject block
    expect = magenta_pixel_count()
    code, rec, _, err = run_cli(td, [
        "rekey", str(src), "--out", str(out),
        "--old-bg", "#FF00FF", "--new-bg", "#00FFFF", "--tol", "0",
        "--no-chroma",
    ])
    _require(code == 0, f"rekey: {err}")
    _require(rec["total_px"] == 64 * 64, f"total_px={rec.get('total_px')}")
    _require(rec["replaced_px"] == expect,
             f"replaced={rec.get('replaced_px')} expect {expect}")
    return f"replaced={expect}"


def sc_sheet(td: Path) -> str:
    src = td / "bake_src.png"
    gen_bake_source(src)
    a = td / "sa.inc"
    b = td / "sb.inc"
    run_cli(td, [
        "bake", str(src), "--out", str(a), "--name", "A",
        "--size", "16x16", "--no-preview",
    ])
    run_cli(td, [
        "bake", str(src), "--out", str(b), "--name", "B",
        "--size", "16x16", "--no-preview",
    ])
    out = td / "sheet.inc"
    code, rec, _, err = run_cli(td, [
        "sheet", str(a), str(b), "--out", str(out), "--name", "SH",
    ])
    _require(code == 0, f"sheet: {err}")
    _require(rec["units"] == 2, f"units={rec.get('units')}")
    pa = review._parse_inc(a.read_text())
    pb = review._parse_inc(b.read_text())
    want_bytes = len(pa["bytes"]) + len(pb["bytes"])
    _require(rec["tile_bytes"] == want_bytes, f"tile_bytes={rec.get('tile_bytes')}")
    # negative: mixed obj_order
    blin = td / "sblin.inc"
    run_cli(td, [
        "bake", str(src), "--out", str(blin), "--name", "BL",
        "--size", "16x16", "--linear", "--no-preview",
    ])
    code2, rec2, out2, err2 = run_cli(td, [
        "sheet", str(a), str(blin), "--out", str(td / "bad.inc"), "--name", "BAD",
    ])
    _require(code2 == 2, f"mixed sheet should fail, exit={code2}")
    _require(rec2 is not None and "obj_order" in str(rec2.get("error", "")).lower()
             or "obj_order" in err2.lower() or "obj_order" in (rec2 or {}).get("error", ""),
             f"mixed error not about obj_order: {rec2} {err2}")
    return f"units=2 mixed-neg ok"


def sc_preview(td: Path) -> str:
    src = td / "bake_src.png"
    gen_bake_source(src)
    inc = td / "pv.inc"
    run_cli(td, [
        "bake", str(src), "--out", str(inc), "--name", "PV",
        "--size", "16x16", "--no-preview",
    ])
    out = td / "pv.png"
    code, rec, _, err = run_cli(td, [
        "preview", str(inc), "--out", str(out),
    ])
    _require(code == 0, f"preview: {err}")
    _require(Path(rec["out"]).exists(), "preview missing")
    return f"frames={rec.get('frames')}"


# ---- API family (keyless) ----

def sc_gen_cache_hit(td: Path) -> str:
    prompt = "pipeline-smoke-gen-cache-hit"
    model = xai.MODEL_IMAGE_DEFAULT
    ck = _gen_cache_key(prompt, model)
    seeded = _seed_cache_png(td / "cache", ck, (11, 22, 33))
    out = td / "gen_out.png"
    code, rec, _, err = run_cli(td, [
        "gen", "--template", "raw", "--prompt", prompt,
        "--out", str(out), "--resolution", "1k", "--aspect", "1:1",
    ])
    _require(code == 0, f"gen cache-hit exit {code}: {err} {rec}")
    _require(rec.get("cached") is True, f"cached!=true: {rec}")
    _require(rec.get("cost_in_usd_ticks") == 0, f"ticks={rec.get('cost_in_usd_ticks')}")
    _require(rec.get("http_status") == 0, f"http={rec.get('http_status')}")
    # out may gain .png suffix
    out_path = Path(rec["out"])
    _require(out_path.exists(), f"out missing {out_path}")
    _require(_sha256_file(out_path) == _sha256_file(seeded), "out != seeded cache")
    return f"ck={ck}"


def sc_gen_model_cache(td: Path) -> str:
    """Post-U8: --model must participate in the cache key."""
    prompt = "pipeline-smoke-gen-model"
    model = xai.MODEL_IMAGE_BUDGET  # non-default
    ck = _gen_cache_key(prompt, model)
    seeded = _seed_cache_png(td / "cache", ck, (44, 55, 66))
    out = td / "gen_model.png"
    code, rec, _, err = run_cli(td, [
        "gen", "--template", "raw", "--prompt", prompt,
        "--model", model,
        "--out", str(out), "--resolution", "1k", "--aspect", "1:1",
    ])
    _require(code == 0, f"gen --model cache-hit exit {code}: {err} {rec}")
    _require(rec.get("cached") is True,
             f"--model dropped? cache miss: {rec} (seeded ck={ck})")
    _require(rec.get("cost_in_usd_ticks") == 0, "nonzero cost on cache hit")
    out_path = Path(rec["out"])
    _require(_sha256_file(out_path) == _sha256_file(seeded), "out != seed")
    return f"model={model} ck={ck}"


def sc_gen_negative(td: Path) -> str:
    # empty cache, no credentials
    out = td / "gen_neg.png"
    code, rec, _, err = run_cli(td, [
        "gen", "--template", "raw", "--prompt", "should-fail-no-creds",
        "--out", str(out),
    ])
    _require(code == 2, f"expected exit 2, got {code}: {rec} {err}")
    _require(rec is not None, "no error record")
    blob = json.dumps(rec) + err
    _require("XAI_API_KEY" in blob, f"error does not name XAI_API_KEY: {blob[:300]}")
    return f"error_type={rec.get('error_type')}"


def sc_edit_cache_hit(td: Path) -> str:
    ref = td / "ref.png"
    Image.new("RGB", (16, 16), (1, 2, 3)).save(ref)
    prompt = "pipeline-smoke-edit-cache"
    model = xai.MODEL_IMAGE_DEFAULT
    ck = _edit_cache_key(prompt, model, ref)
    seeded = _seed_cache_png(td / "cache", ck, (7, 8, 9))
    out = td / "edit_out.png"
    code, rec, _, err = run_cli(td, [
        "edit", str(ref), "--prompt", prompt, "--out", str(out),
        "--resolution", "1k",
    ])
    _require(code == 0, f"edit cache-hit: {err} {rec}")
    _require(rec.get("cached") is True, f"cached={rec.get('cached')}")
    _require(rec.get("cost_in_usd_ticks") == 0, "ticks nonzero")
    out_path = Path(rec["out"])
    _require(_sha256_file(out_path) == _sha256_file(seeded), "out != seed")
    return f"ck={ck}"


def sc_edit_negative(td: Path) -> str:
    ref = td / "ref.png"
    Image.new("RGB", (8, 8), (1, 1, 1)).save(ref)
    code, rec, _, err = run_cli(td, [
        "edit", str(ref), "--prompt", "no-creds-edit",
        "--out", str(td / "e.png"),
    ])
    _require(code == 2, f"exit {code}")
    blob = json.dumps(rec or {}) + err
    _require("XAI_API_KEY" in blob, f"no XAI_API_KEY in {blob[:300]}")
    return "neg ok"


def sc_video_cache_hit(td: Path) -> str:
    prompt = "pipeline-smoke-video-cache"
    model = xai.MODEL_VIDEO_DEFAULT
    duration = 3
    ck = _video_cache_key(prompt, model, duration=duration)
    seeded = _seed_cache_mp4(td / "cache", ck)
    out = td / "vid.mp4"
    code, rec, _, err = run_cli(td, [
        "video", "--template", "raw", "--prompt", prompt,
        "--duration", str(duration), "--out", str(out),
        "--aspect", "1:1", "--resolution", "720p",
    ])
    _require(code == 0, f"video cache-hit: {err} {rec}")
    _require(rec.get("cached") is True, f"cached={rec.get('cached')}")
    _require(rec.get("cost_in_usd_ticks") == 0, "ticks nonzero")
    out_path = Path(rec["out"])
    _require(_sha256_file(out_path) == _sha256_file(seeded), "out != seed")
    return f"ck={ck}"


def sc_video_negative(td: Path) -> str:
    code, rec, _, err = run_cli(td, [
        "video", "--template", "raw", "--prompt", "no-creds-video",
        "--duration", "2", "--out", str(td / "v.mp4"),
    ])
    _require(code == 2, f"exit {code}")
    blob = json.dumps(rec or {}) + err
    _require("XAI_API_KEY" in blob, f"no XAI_API_KEY in {blob[:300]}")
    return "neg ok"


def sc_cache_collision(td: Path) -> str:
    """Same hashed fields + different --out share one cache entry (D.1)."""
    prompt = "pipeline-smoke-collision"
    model = xai.MODEL_IMAGE_DEFAULT
    ck = _gen_cache_key(prompt, model)
    seeded = _seed_cache_png(td / "cache", ck, (90, 91, 92))
    out1 = td / "c1.png"
    out2 = td / "c2.png"
    for out in (out1, out2):
        code, rec, _, err = run_cli(td, [
            "gen", "--template", "raw", "--prompt", prompt,
            "--out", str(out),
        ])
        _require(code == 0 and rec.get("cached") is True, f"hit fail: {rec} {err}")
    # changing resolution must miss
    code, rec, _, err = run_cli(td, [
        "gen", "--template", "raw", "--prompt", prompt,
        "--out", str(td / "c3.png"), "--resolution", "2k",
    ])
    _require(code == 2, f"resolution change should miss -> auth fail, got {code} {rec}")
    return "shared-hit + resolution-miss"


def sc_sprite_mock(td: Path) -> str:
    if not _mock_supported():
        raise Skip("SPRITE_MOCK adapter not present in xai.py")
    env = _scrub_env()
    env["SPRITE_MOCK"] = "1"
    out = td / "mock.png"
    code, rec, _, err = run_cli(td, [
        "gen", "--template", "raw", "--prompt", "mock-path",
        "--out", str(out),
    ], env=env)
    _require(code == 0, f"SPRITE_MOCK gen: {err} {rec}")
    _require(rec.get("cost_in_usd_ticks") == 0, f"ticks={rec.get('cost_in_usd_ticks')}")
    _require("mock" in str(rec.get("op", "")).lower() or rec.get("http_status") == 0,
             f"unexpected rec: {rec}")
    _require(Path(rec["out"]).exists(), "mock out missing")
    return f"op={rec.get('op')}"


# ---- external binary family ----

def sc_extract(td: Path) -> str:
    if shutil.which("ffmpeg") is None:
        raise Skip("ffmpeg not on PATH")
    mp4 = td / "src.mp4"
    # synthesize 1s @ 4fps 32x32
    cmd = [
        shutil.which("ffmpeg"), "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc=duration=1:size=32x32:rate=4",
        str(mp4),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    _require(r.returncode == 0, f"ffmpeg synth failed: {r.stderr}")
    out_dir = td / "frames"
    code, rec, _, err = run_cli(td, [
        "extract", str(mp4), "--out-dir", str(out_dir),
    ])
    _require(code == 0, f"extract: {err}")
    # 1s * 4fps = 4 frames (allow +/-1 for ffmpeg boundary)
    fc = rec.get("frame_count")
    _require(fc is not None and 3 <= fc <= 5, f"frame_count={fc}")
    frames = sorted(out_dir.glob("f_*.png"))
    _require(len(frames) == fc, f"glob {len(frames)} != {fc}")
    _require(frames[0].name.startswith("f_"), f"name {frames[0].name}")
    return f"frame_count={fc}"


def sc_emulate_negative(td: Path) -> str:
    # any valid-looking .inc is fine; fpc path is the failure.
    # Restore wrapper: emulate always stages into test/sprite_input.inc.
    with _restore_shipped_inc():
        src = td / "bake_src.png"
        gen_bake_source(src)
        inc = td / "e.inc"
        run_cli(td, [
            "bake", str(src), "--out", str(inc), "--name", "E",
            "--size", "16x16", "--no-preview",
        ])
        bad = td / "no-such-fpc.exe"
        code, rec, _, err = run_cli(td, [
            "emulate", str(inc), "--out", str(td / "emu_neg"),
            "--fpc", str(bad),
        ])
        _require(code == 2, f"exit {code}")
        blob = json.dumps(rec or {}) + err
        _require("fpc" in blob.lower() or "compiler" in blob.lower(),
                 f"error does not name compiler: {blob[:300]}")
        _require(str(bad) in blob or "not found" in blob.lower(),
                 f"missing path not named: {blob[:300]}")
    return "BuildError path"


def sc_emulate_positive(td: Path) -> str:
    fpc = _find_fpc()
    if fpc is None:
        raise Skip("host FPC not found")
    with _restore_shipped_inc():
        out_stem = td / "emu_ship"
        code, rec, _, err = run_cli(td, [
            "emulate", str(TEST_INC), "--out", str(out_stem),
            "--fpc", str(fpc),
        ], timeout=300)
        _require(code == 0, f"emulate: {err}\n{rec}")
        _require(rec.get("frames") == 4, f"frames={rec.get('frames')}")
        pngs = [Path(p) for p in rec.get("pngs") or []]
        _require(len(pngs) == 4, f"pngs={len(pngs)}")
        for p in pngs:
            im = Image.open(p)
            _require(im.size == (240, 160), f"{p.name} size {im.size}")
        # corner far from centered 16x16 sprite -> backdrop from sprite_smoke Setup:
        # WriteHalf BG_BACKDROP = (6<<10)|(6<<5)|4  (BGR555 R=4,G=6,B=6).
        # PPU expands 5-bit channels as (c<<3)|(c>>2) -> (33,49,49).
        backdrop = (33, 49, 49)
        im0 = Image.open(pngs[0])
        corner = im0.getpixel((2, 2))
        _require(_near(corner, backdrop, tol=2), f"backdrop corner {corner}")
        # marker dot for frame 0 is at DOTS[0]=(12,3) in sprite space;
        # screen center offset ((240-16)/2, (160-16)/2) = (112, 72)
        sx, sy = 112 + 12, 72 + 3
        mark = im0.getpixel((sx, sy))
        _require(not _near(mark, backdrop, tol=2),
                 f"marker still backdrop at ({sx},{sy}): {mark}")
    return f"frames=4 fpc={fpc.name}"


def sc_emulate_shape_rebuild(td: Path) -> str:
    fpc = _find_fpc()
    if fpc is None:
        raise Skip("host FPC not found")
    with _restore_shipped_inc():
        # first: 16x16 bake
        src = td / "bake_src.png"
        gen_bake_source(src)
        inc16 = td / "e16.inc"
        run_cli(td, [
            "bake", str(src), "--out", str(inc16), "--name", "E16",
            "--size", "16x16", "--no-preview",
        ])
        code, rec1, _, err = run_cli(td, [
            "emulate", str(inc16), "--out", str(td / "e16o"),
            "--fpc", str(fpc),
        ], timeout=300)
        _require(code == 0, f"emu16: {err}")
        sig1 = rec1.get("shape_signature")
        # second: 32x32 with --no-rebuild; shape change forces rebuild
        inc32 = td / "e32.inc"
        run_cli(td, [
            "bake", str(src), "--out", str(inc32), "--name", "E32",
            "--size", "32x32", "--no-preview",
        ])
        code, rec2, out2, err2 = run_cli(td, [
            "emulate", str(inc32), "--out", str(td / "e32o"),
            "--fpc", str(fpc), "--no-rebuild",
        ], timeout=300)
        _require(code == 0, f"emu32: {err2}")
        _require(rec2.get("forced_rebuild") is True,
                 f"forced_rebuild not set: {rec2}")
        _require(rec2.get("shape_signature") != sig1,
                 f"sig unchanged {sig1}")
        _require(rec2.get("frames") == 1, f"frames={rec2.get('frames')}")
        pngs = [Path(p) for p in rec2.get("pngs") or []]
        _require(pngs and Image.open(pngs[0]).size == (240, 160), "bad png")
    return f"forced_rebuild sig {sig1}->{rec2.get('shape_signature')}"


def sc_obj_order_emulate_parity(td: Path) -> str:
    fpc = _find_fpc()
    if fpc is None:
        raise Skip("host FPC not found")
    with _restore_shipped_inc():
        src = td / "bake_src.png"
        gen_bake_source(src)
        obj_inc = td / "po.inc"
        lin_inc = td / "pl.inc"
        run_cli(td, [
            "bake", str(src), "--out", str(obj_inc), "--name", "PO",
            "--size", "16x16", "--no-preview",
        ])
        run_cli(td, [
            "bake", str(src), "--out", str(lin_inc), "--name", "PL",
            "--size", "16x16", "--linear", "--no-preview",
        ])
        # bake-layer parity already covered; emulate both
        code_a, ra, _, ea = run_cli(td, [
            "emulate", str(obj_inc), "--out", str(td / "po_e"),
            "--fpc", str(fpc),
        ], timeout=300)
        _require(code_a == 0, f"emu obj: {ea}")
        code_b, rb, _, eb = run_cli(td, [
            "emulate", str(lin_inc), "--out", str(td / "pl_e"),
            "--fpc", str(fpc),
        ], timeout=300)
        _require(code_b == 0, f"emu lin: {eb}")
        pa = Image.open(ra["pngs"][0])
        pb = Image.open(rb["pngs"][0])
        total = sum(_channel_delta(a, b) for a, b in zip(pa.getdata(), pb.getdata()))
        _require(total == 0, f"emulate obj/linear delta={total}")
    return "emulate obj/linear identical"


def sc_truncated_inc(td: Path) -> str:
    """D.3: truncated .inc must raise, not return a silent wrong parse."""
    src = td / "bake_src.png"
    gen_bake_source(src)
    inc = td / "full.inc"
    run_cli(td, [
        "bake", str(src), "--out", str(inc), "--name", "TR",
        "--size", "16x16", "--no-preview",
    ])
    text = inc.read_text()
    cut = text.find("TR_TILES")
    _require(cut > 0, "no TILES block")
    mid = cut + len(text[cut:]) // 2
    bad = td / "trunc.inc"
    bad.write_text(text[:mid])
    try:
        review.inspect(bad)
        raise Fail("truncated .inc parsed without error")
    except Fail:
        raise
    except Exception as e:
        return f"raised {type(e).__name__}"


# ===========================================================================
# runner
# ===========================================================================

# Each entry: (name, fn) where fn(td: Path) -> detail str
SCENARIOS: list[tuple[str, Callable[..., str]]] = [
    # 1. filesystem / registry
    ("cost.summarize", sc_cost),
    ("cache.list_clear", sc_cache_list_clear),
    ("manifest.set_get_list", sc_manifest),
    ("canonical.set_variant_get_list", sc_canonical),
    # 2. bake family
    ("bake.single", sc_bake_single),
    ("bake.linear_parity", sc_bake_linear_parity),
    ("bake.colors_cap", sc_bake_colors_cap),
    ("bake.nonsquare", sc_bake_nonsquare),
    ("anim.shared_palette", sc_anim),
    ("ui_bake.nine_slice", sc_ui_bake),
    ("font_bake.glyphs", sc_font_bake),
    ("tile.offset_seam", sc_tile_offset),
    ("tile.mirror_exact", sc_tile_mirror),
    # 3. review / edit
    ("pick.loop", sc_pick),
    ("montage.dims", sc_montage),
    ("gif.frames", sc_gif),
    ("tile3x3.inc", sc_tile3x3_inc),
    ("inspect.golden", sc_inspect),
    ("palette.swatch_dims", sc_palette),
    ("diff.identity", sc_diff_identity),
    ("diff.known_delta", sc_diff_known),
    ("recolor.tiles_intact", sc_recolor),
    ("rekey.exact_count", sc_rekey),
    ("sheet.units_and_mixed_neg", sc_sheet),
    ("preview.smoke", sc_preview),
    # 4. API keyless
    ("gen.cache_hit", sc_gen_cache_hit),
    ("gen.model_cache_hit", sc_gen_model_cache),
    ("gen.negative_no_creds", sc_gen_negative),
    ("edit.cache_hit", sc_edit_cache_hit),
    ("edit.negative_no_creds", sc_edit_negative),
    ("video.cache_hit", sc_video_cache_hit),
    ("video.negative_no_creds", sc_video_negative),
    ("gen.cache_collision", sc_cache_collision),
    ("gen.sprite_mock", sc_sprite_mock),
    # 5. external
    ("extract.ffmpeg", sc_extract),
    ("emulate.negative_fpc", sc_emulate_negative),
    ("emulate.positive_shipped", sc_emulate_positive),
    ("emulate.shape_rebuild", sc_emulate_shape_rebuild),
    ("emulate.obj_linear_parity", sc_obj_order_emulate_parity),
    # 6. known-risk
    ("risk.truncated_inc", sc_truncated_inc),
]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Offline pipeline smoke suite")
    ap.add_argument("--with-key", nargs="?", const="DEFAULT", default=None,
                    help="opt into live-network scenarios (path to auth; default ~/.grok/auth.json)")
    ap.add_argument("--i-understand-this-costs-money", action="store_true",
                    help="required together with --with-key for live calls")
    ap.add_argument("--only", default=None,
                    help="comma-separated scenario name substrings to run")
    args = ap.parse_args(argv)

    live = False
    if args.with_key is not None:
        if not args.i_understand_this_costs_money:
            print("ERROR: --with-key requires --i-understand-this-costs-money",
                  file=sys.stderr)
            return 2
        live = True
        # live scenarios not implemented as auto suite entries; document skip
        print("NOTE: live-network scenarios are documented-manual; "
              "default inventory stays keyless.", file=sys.stderr)

    if not SPRITE_PY.exists():
        print(f"harness error: missing {SPRITE_PY}", file=sys.stderr)
        return 2
    if not TEST_INC.exists():
        print(f"harness error: missing {TEST_INC}", file=sys.stderr)
        return 2

    only = None
    if args.only:
        only = [s.strip() for s in args.only.split(",") if s.strip()]

    before_hash = _sha256_file(TEST_INC)
    before_bytes = TEST_INC.read_bytes()
    results: list[dict] = []
    harness_error = False

    try:
        with tempfile.TemporaryDirectory(prefix="sprite_smoke_") as root:
            root_p = Path(root)
            for name, fn in SCENARIOS:
                if only and not any(o in name for o in only):
                    continue
                # live gate: no scenario in the default inventory is live;
                # keep `live` flag for future entries that check it.
                _ = live
                sc_td = root_p / name.replace(".", "_")
                sc_td.mkdir(parents=True, exist_ok=True)
                t0 = time.time()
                status = "pass"
                detail = ""
                try:
                    detail = fn(sc_td) or ""
                except Skip as e:
                    status = "skip"
                    detail = str(e)
                except Fail as e:
                    status = "fail"
                    detail = str(e)
                except Exception as e:
                    status = "fail"
                    detail = f"{type(e).__name__}: {e}"
                    # keep a short traceback on stderr for diagnosis
                    traceback.print_exc(file=sys.stderr)
                ms = int((time.time() - t0) * 1000)
                rec = {
                    "scenario": name,
                    "status": status,
                    "detail": detail,
                    "duration_ms": ms,
                }
                results.append(rec)
                _emit_ndjson(rec)
    except Exception as e:
        harness_error = True
        print(f"harness error: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
    finally:
        # whole-run restore discipline
        try:
            TEST_INC.write_bytes(before_bytes)
        except Exception as e:
            harness_error = True
            print(f"harness error: restore sprite_input.inc failed: {e}",
                  file=sys.stderr)

    after_hash = _sha256_file(TEST_INC)
    if after_hash != before_hash:
        harness_error = True
        print(
            f"harness error: sprite_input.inc hash changed "
            f"{before_hash} -> {after_hash}",
            file=sys.stderr,
        )

    # human summary
    n_pass = sum(1 for r in results if r["status"] == "pass")
    n_fail = sum(1 for r in results if r["status"] == "fail")
    n_skip = sum(1 for r in results if r["status"] == "skip")
    print(
        f"\n=== pipeline_smoke summary: "
        f"{n_pass} pass / {n_fail} fail / {n_skip} skip "
        f"(of {len(results)}) ===",
        file=sys.stderr,
    )
    for r in results:
        mark = {"pass": "PASS", "fail": "FAIL", "skip": "SKIP"}[r["status"]]
        print(f"  [{mark}] {r['scenario']}: {r['detail']}", file=sys.stderr)
    print(f"sprite_input.inc sha256: {before_hash} (before=after={after_hash == before_hash})",
          file=sys.stderr)

    if harness_error:
        return 2
    if n_fail:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
