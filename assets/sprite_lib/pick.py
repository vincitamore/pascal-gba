"""sprite_lib.pick -- loop detection + arc-length keyframe selection.

Naive "pick N evenly-spaced frames from a clip" lands on near-duplicate poses
when the clip is 3+ cycles of motion. This module solves two problems:

  1. Loop length: the index L (>= min_loop) minimizing distance back to frame 0.
     Trims the clip to its first complete cycle.
  2. Distinct keyframes: K frames spaced by EQUAL CUMULATIVE MOTION (arc-length)
     within [0, L), so even when the model eases in/out we still pick distinct
     poses.

Distance metric: 32x32 grayscale mean-abs-diff. Cheap, robust to AA jitter.
"""
from __future__ import annotations
import glob
from pathlib import Path
from typing import Sequence

from PIL import Image


def _load_small(path: Path, n: int = 32) -> list[int]:
    return list(Image.open(path).convert("L").resize((n, n), Image.BOX).getdata())


def _dist(a: list[int], b: list[int]) -> float:
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def _expand_paths(frames: Sequence[str | Path]) -> list[Path]:
    out: list[Path] = []
    for f in frames:
        s = str(f)
        if any(c in s for c in "*?["):
            out.extend(Path(p) for p in sorted(glob.glob(s)))
        else:
            out.append(Path(s))
    return out


def pick_keyframes(frames: Sequence[str | Path],
                   *,
                   k: int = 6,
                   min_loop: int = 8,
                   no_loop: bool = False) -> dict:
    """Return picked frame paths + diagnostics.

    Result:
      {
        op: 'pick_keyframes',
        n_in: int, k: int, loop_len: int | None, loop_dist: float | None,
        picks: [{ index: int, path: str }, ...],
      }
    """
    paths = _expand_paths(frames)
    if not paths:
        raise ValueError("pick_keyframes: no frames matched")
    sm = [_load_small(p) for p in paths]
    N = len(sm)

    if no_loop or N <= min_loop + 2:
        L = N
        loop_dist = None
    else:
        cand = [(_dist(sm[i], sm[0]), i) for i in range(min_loop, N)]
        loop_dist, L = min(cand)

    arc = [0.0]
    for i in range(1, L):
        arc.append(arc[-1] + _dist(sm[i], sm[i - 1]))
    total = arc[-1] if arc[-1] > 0 else 1.0

    raw_picks: list[int] = []
    for j in range(k):
        target = total * j / k
        idx = min(range(L), key=lambda i: abs(arc[i] - target))
        raw_picks.append(idx)
    # dedupe preserving order
    seen, picks = set(), []
    for p in raw_picks:
        if p not in seen:
            seen.add(p)
            picks.append(p)

    return {
        "op": "pick_keyframes",
        "n_in": N,
        "k": len(picks),
        "loop_len": L if not no_loop else None,
        "loop_dist": loop_dist,
        "picks": [{"index": i, "path": str(paths[i])} for i in picks],
    }
