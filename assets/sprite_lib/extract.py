"""sprite_lib.extract -- mp4 -> per-frame PNGs via ffmpeg.

Wraps ffmpeg so the video-to-animation chain is a true one-liner from the
harness CLI, no shell pivot needed. Frames land at <out-dir>/f_001.png etc.;
the caller then feeds these into `sprite pick` (for loop-detected keyframes)
and `sprite anim` (for the shared-palette bake).
"""
from __future__ import annotations
import re
import shutil
import subprocess
from pathlib import Path


class FfmpegMissing(RuntimeError):
    pass


def _resolve_ffmpeg() -> str:
    """Find ffmpeg on PATH or raise FfmpegMissing with install hint."""
    for cand in ("ffmpeg", "ffmpeg.exe"):
        p = shutil.which(cand)
        if p:
            return p
    raise FfmpegMissing(
        "ffmpeg not found on PATH; install via `choco install ffmpeg` "
        "(Windows) or your platform's package manager"
    )


def extract_frames(mp4_path: str | Path,
                   out_dir: str | Path,
                   *,
                   fps: int = 0,
                   start: float = 0.0,
                   duration: float = 0.0,
                   clean: bool = True) -> dict:
    """Extract every frame (or `fps` frames/sec) from `mp4_path` into out_dir/.

    Frames land at out_dir/f_001.png .. f_NNN.png (3-digit zero-pad). When `fps=0`
    we keep the source clip's native framerate (-vsync passthrough); a non-zero
    fps resamples (-vf fps=N).

    `start` / `duration` (seconds) optionally trim the source clip before extract.
    `clean=True` purges the out_dir first so stale frames don't pollute a re-run.

    Returns:
      {
        op: 'extract',
        mp4: str, out_dir: str,
        frames: [paths...],
        fps_target: int,  fps_source: float or None,
      }
    """
    mp4_path = Path(mp4_path)
    out_dir = Path(out_dir)
    if not mp4_path.exists():
        raise FileNotFoundError(f"mp4 not found: {mp4_path}")
    out_dir.mkdir(parents=True, exist_ok=True)
    if clean:
        for p in out_dir.glob("f_*.png"):
            p.unlink()
    ffmpeg = _resolve_ffmpeg()
    cmd: list[str] = [ffmpeg, "-y", "-loglevel", "error"]
    if start > 0:
        cmd += ["-ss", str(start)]
    if duration > 0:
        cmd += ["-t", str(duration)]
    cmd += ["-i", str(mp4_path)]
    if fps > 0:
        cmd += ["-vf", f"fps={fps}"]
    cmd += [str(out_dir / "f_%03d.png")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(
            f"ffmpeg exit {r.returncode}\n  cmd: {' '.join(cmd)}\n  stderr:\n{r.stderr}"
        )
    frames = sorted(out_dir.glob("f_*.png"))
    # also probe the source fps for the manifest
    probe = subprocess.run([ffmpeg, "-i", str(mp4_path)],
                           capture_output=True, text=True)
    fps_source: float | None = None
    m = re.search(r"(\d+(?:\.\d+)?)\s+fps", probe.stderr)
    if m:
        fps_source = float(m.group(1))
    return {
        "op": "extract",
        "mp4": str(mp4_path),
        "out_dir": str(out_dir),
        "frames": [str(p) for p in frames],
        "frame_count": len(frames),
        "fps_target": fps,
        "fps_source": fps_source,
    }
