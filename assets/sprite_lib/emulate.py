"""sprite_lib.emulate -- render a baked .inc through the real PPU OBJ path.

Drives the host-side `sprite_smoke.pas` harness: stages a renamed copy of any
baked .inc at the include path, builds `sprite_smoke.exe` via host-FPC (NOT the
GBA cross compiler -- this is the emulator's Memory + Ppu units running on x86),
runs it, captures the per-frame PPM dumps, and converts them to PNG + a looping
GIF for the agent to view.

Output:
  <out>_f0.png .. <out>_fN-1.png    per-frame PPM-to-PNG dumps (240x160)
  <out>.gif                         looping GIF at sprite framerate
  Returns the paths in the JSON record.

Requires the FPC host compiler (default at C:\\lazarus\\fpc\\3.2.2\\bin\\...). The
PPU units are stock Pascal that builds on Windows/Linux/Mac alike; we just need
FPC + the project's `gba/src` directory.
"""
from __future__ import annotations
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable

from PIL import Image

from . import util


# ---------- project locations ----------

GBA_PROJECT_ROOT = Path(__file__).resolve().parents[2]   # host project root
TEST_DIR = GBA_PROJECT_ROOT / "test"
SRC_DIR = GBA_PROJECT_ROOT / "src"
BIN_DIR = GBA_PROJECT_ROOT / "bin"
SPRITE_SMOKE_PAS = TEST_DIR / "sprite_smoke.pas"
STAGED_INC = TEST_DIR / "sprite_input.inc"
STAGED_EXE = TEST_DIR / "sprite_smoke.exe"   # FPC default: alongside source

DEFAULT_FPC = Path(r"C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe")


def _resolve_fpc(fpc: Path | str | None = None) -> Path:
    """Resolve the host FPC binary: explicit path, then Windows default, then PATH."""
    if fpc is not None:
        return Path(fpc)
    if DEFAULT_FPC.exists():
        return DEFAULT_FPC
    found = shutil.which("fpc")
    if found:
        return Path(found)
    return DEFAULT_FPC

# Sidecar file storing the SHA of the build-time constants the cached
# sprite_smoke.exe was compiled against. Mismatch -> forced rebuild.
SHAPE_SIDECAR = BIN_DIR / ".sprite_smoke.shape"


def _shape_signature(staged_inc_text: str) -> str:
    """Hash the build-time constants compiled into sprite_smoke.exe.

    The constants `SPRITE_W`, `SPRITE_H`, `SPRITE_FRAMES`, `SPRITE_OBJ_ORDER`
    are baked into the binary at compile time. Reusing a stale binary against
    a different-shape input produces silently-wrong output (wrong frame count,
    wrong dimensions, wrong tile-order branch). This signature lets emulate()
    force a rebuild when the shape changes even if `--no-rebuild` was passed.
    """
    consts: dict[str, str] = {}
    for fld in ("W", "H", "FRAMES", "OBJ_ORDER"):
        m = re.search(rf"const\s+SPRITE_{fld}\s*=\s*(\S+?)\s*;",
                      staged_inc_text)
        consts[fld] = m.group(1).strip() if m else "?"
    sig = json.dumps(consts, sort_keys=True)
    return hashlib.sha256(sig.encode()).hexdigest()[:16]


# ---------- stage a renamed .inc ----------

def stage_inc(src_inc: Path, dst_inc: Path = STAGED_INC) -> tuple[Path, str]:
    """Read `src_inc`, find its NAME_ prefix, write a copy at `dst_inc` with the
    prefix renamed to SPRITE so sprite_smoke.pas's `{$I sprite_input.inc}` works.

    Defensive: only rewrite occurrences of `<NAME>_<UPPER>`, never the unprefixed
    NAME (so e.g. 'SOLDIER' alone is left alone; only 'SOLDIER_W' becomes 'SPRITE_W').
    """
    text = src_inc.read_text()
    m = re.search(r"const\s+(\w+)_W\s*=", text)
    if not m:
        raise ValueError(f"no NAME_W const found in {src_inc}")
    name = m.group(1)
    # Word-boundary safe rewrite: replace exact `<name>_` -> `SPRITE_`
    pattern = re.compile(rf"\b{re.escape(name)}_")
    rewritten = pattern.sub("SPRITE_", text)
    dst_inc.parent.mkdir(parents=True, exist_ok=True)
    dst_inc.write_text(rewritten)
    return dst_inc, name


# ---------- build sprite_smoke.exe ----------

class BuildError(RuntimeError):
    pass


def build_smoke(fpc: Path | None = None, verbose: bool = False) -> Path:
    """Compile sprite_smoke.pas to test/sprite_smoke.exe (host-arch, NOT -Tgba).

    Uses the same flags as the project's gba_runner build:
      -Mobjfpc -Sh -Fu<src> -FE<bin> -FU<bin>
    """
    fpc = _resolve_fpc(fpc)
    if not fpc.exists():
        raise BuildError(
            f"FPC compiler not found at {fpc} "
            f"(pass --fpc, or ensure fpc is on PATH)"
        )
    BIN_DIR.mkdir(exist_ok=True)
    if STAGED_EXE.exists():
        STAGED_EXE.unlink()
    cmd = [
        str(fpc),
        "-Mobjfpc", "-Sh",
        f"-Fu{SRC_DIR}",
        f"-FE{BIN_DIR}",   # binaries to bin/
        f"-FU{BIN_DIR}",   # .ppu / .o to bin/
        str(SPRITE_SMOKE_PAS),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=GBA_PROJECT_ROOT)
    if r.returncode != 0:
        raise BuildError(
            f"FPC build failed (exit {r.returncode})\n"
            f"  cmd: {' '.join(cmd)}\n"
            f"  stdout:\n{r.stdout}\n"
            f"  stderr:\n{r.stderr}"
        )
    # Host binary name: Windows FPC emits .exe; other hosts usually bare `sprite_smoke`.
    candidates = [
        BIN_DIR / "sprite_smoke.exe",
        BIN_DIR / "sprite_smoke",
        STAGED_EXE,
        TEST_DIR / "sprite_smoke",
    ]
    exe = next((c for c in candidates if c.exists()), None)
    if exe is None:
        raise BuildError(
            f"FPC reported success but exe not found "
            f"(looked for sprite_smoke[.exe] under {BIN_DIR} and {TEST_DIR})"
        )
    if verbose:
        print(f"built {exe}")
    return exe


# ---------- run + capture PPMs ----------

def run_smoke(exe: Path,
              ppm_dir: Path | None = None,
              timeout: int = 60) -> tuple[list[Path], str]:
    """Run sprite_smoke.exe. It dumps PPMs to `bin/sprite_f<N>.ppm` relative to its
    cwd. We launch it from GBA_PROJECT_ROOT so that `bin/...` resolves to the
    project's bin directory.

    Returns (sorted_ppm_paths, stdout_text).
    """
    if ppm_dir is None:
        ppm_dir = BIN_DIR
    # purge any previous frames so we don't confuse old + new output
    for p in ppm_dir.glob("sprite_f*.ppm"):
        p.unlink()
    r = subprocess.run([str(exe)], capture_output=True, text=True,
                       cwd=GBA_PROJECT_ROOT, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(
            f"sprite_smoke exit {r.returncode}\n"
            f"  stdout:\n{r.stdout}\n  stderr:\n{r.stderr}"
        )
    ppms = sorted(ppm_dir.glob("sprite_f*.ppm"),
                  key=lambda p: int(re.search(r"f(\d+)", p.stem).group(1)))
    return ppms, r.stdout


# ---------- PPM -> PNG / GIF ----------

def _read_ppm_p6(path: Path) -> Image.Image:
    """Read a binary PPM (P6) into a PIL image. The emulator's DumpPpm produces P6."""
    with open(path, "rb") as f:
        header = b""
        while header.count(b"\n") < 3:  # P6, dims, maxval
            ch = f.read(1)
            if not ch:
                raise IOError(f"truncated PPM at {path}")
            header += ch
        lines = header.split(b"\n", 3)
        magic = lines[0].decode().strip()
        if magic != "P6":
            raise IOError(f"unexpected PPM magic {magic!r} in {path}")
        dims = lines[1].split() if not lines[1].startswith(b"#") else lines[2].split()
        # tolerate a comment line between magic and dims
        if dims[0].startswith(b"#"):
            dims = lines[2].split()
        w, h = int(dims[0]), int(dims[1])
        # third non-comment line: maxval
        body = f.read()
    im = Image.frombytes("RGB", (w, h), body)
    return im


# Match sprite_lib.bake.SCREEN_GIF_SCALE so emulate and bake validation gifs
# look consistent at the same on-screen scale.
EMU_GIF_SCALE = 3


def ppms_to_pngs_and_gif(ppms: Iterable[Path], out_stem: Path,
                         gif_ms: int = 110) -> dict:
    """Convert N PPMs to N PNGs at <stem>_f<i>.png (native 240x160) and one
    looping GIF at <stem>.gif (NN-upscaled by EMU_GIF_SCALE for viewability)."""
    out_stem = Path(out_stem)
    out_stem.parent.mkdir(parents=True, exist_ok=True)
    pngs: list[Path] = []
    imgs: list[Image.Image] = []
    for p in ppms:
        im = _read_ppm_p6(p)
        idx = int(re.search(r"f(\d+)", p.stem).group(1))
        png = out_stem.with_name(f"{out_stem.name}_f{idx}.png")
        im.save(png)
        pngs.append(png)
        imgs.append(im)
    gif_path = out_stem.with_suffix(".gif")
    if imgs:
        w, h = imgs[0].size
        gif_frames = [im.resize((w * EMU_GIF_SCALE, h * EMU_GIF_SCALE),
                                Image.NEAREST) for im in imgs]
        # Windows-Photos-friendly: no disposal flag, shared palette across frames
        # (quantize the horizontal stack once, split back). Without this, PIL
        # gives each frame its own palette and the GIF reads as static in
        # Windows-native viewers despite n_frames>1.
        gw, gh = gif_frames[0].size
        stack = Image.new("RGB", (gw * len(gif_frames), gh))
        for i, f in enumerate(gif_frames):
            stack.paste(f, (i * gw, 0))
        q_stack = stack.quantize(colors=255, method=Image.MEDIANCUT,
                                 dither=Image.NONE)
        q_frames = [q_stack.crop((i * gw, 0, (i + 1) * gw, gh))
                    for i in range(len(gif_frames))]
        q_frames[0].save(gif_path, save_all=True, append_images=q_frames[1:],
                         duration=gif_ms, loop=0, optimize=False)
    return {"pngs": [str(p) for p in pngs],
            "gif": str(gif_path) if imgs else None,
            "frames": len(pngs)}


# ---------- one-line entry ----------

def emulate(inc_path: str | Path,
            out_stem: str | Path | None = None,
            *,
            gif_ms: int = 110,
            fpc: Path | None = None,
            rebuild: bool = True,
            keep_stage: bool = False) -> dict:
    """Stage + build + run + capture for any baked .inc. Returns:

      {
        op: 'emulate',
        inc: <input>,  staged: <staged inc>,  exe: <built exe>,
        name: <original NAME prefix>,
        pngs: [...],  gif: <path>,  frames: N
      }

    `rebuild=True` (default) ALWAYS recompiles sprite_smoke.exe. Pascal compiles
    constants like SPRITE_W / SPRITE_H / SPRITE_FRAMES / SPRITE_OBJ_ORDER into
    the binary at build time -- reusing a stale binary against a different-shape
    input produces silently-wrong output (wrong frame count, wrong dimensions,
    wrong tile-order branch).

    `rebuild=False` is opt-in skip-rebuild, but it is NOT a license to skip
    when the shape changed. emulate() computes a shape signature
    (`SPRITE_W/H/FRAMES/OBJ_ORDER`) of the staged .inc, compares it to the
    sidecar that recorded the constants the cached exe was built from, and
    forces a rebuild on mismatch -- regardless of `rebuild`. The forced
    rebuild emits a stderr warning so the operator sees the override happen.
    The structural fix replaces the prior SKILL.md warning ("NEVER use
    --no-rebuild across different .incs") with tool-level enforcement.
    """
    inc_path = Path(inc_path)
    if out_stem is None:
        out_stem = inc_path.with_suffix("")
    staged, original_name = stage_inc(inc_path)
    new_sig = _shape_signature(staged.read_text())
    cached_sig: str | None = None
    if SHAPE_SIDECAR.exists():
        cached_sig = SHAPE_SIDECAR.read_text().strip() or None
    exe_cached = BIN_DIR / "sprite_smoke.exe"
    exe_at_test = STAGED_EXE
    shape_changed = (cached_sig is not None and cached_sig != new_sig)
    must_rebuild = (
        rebuild
        or shape_changed
        or (not exe_cached.exists() and not exe_at_test.exists())
    )
    if shape_changed and not rebuild:
        print(f"[emulate] WARNING: --no-rebuild requested but staged .inc shape "
              f"changed (sig {cached_sig} -> {new_sig}); forcing rebuild to "
              f"avoid silently-wrong output (stale constants baked into exe).",
              file=sys.stderr)
    if must_rebuild:
        exe = build_smoke(fpc=fpc)
        BIN_DIR.mkdir(parents=True, exist_ok=True)
        SHAPE_SIDECAR.write_text(new_sig)
    else:
        exe = exe_cached if exe_cached.exists() else exe_at_test
    ppms, log = run_smoke(exe)
    artifacts = ppms_to_pngs_and_gif(ppms, Path(out_stem), gif_ms=gif_ms)
    if not keep_stage:
        # keep the staged .inc so a follow-up build doesn't need to re-stage
        pass
    return {"op": "emulate", "inc": str(inc_path), "staged": str(staged),
            "exe": str(exe), "name": original_name,
            "shape_signature": new_sig,
            "shape_signature_prior": cached_sig,
            "shape_changed": shape_changed,
            "forced_rebuild": bool(shape_changed and not rebuild),
            **artifacts,
            "log": log}
