"""sprite_lib.observe -- rolling observation surface for judge sessions.

Between gen/judge/vid-gen/bake passes, failures and adjustments accumulate in a
single markdown journal the next judge call can load. Agents (or `sprite judge
--observe FILE`) pass the same path so the vision rubric learns repeated modes
without re-pasting chat history.

Format (append-only sections):

    ## 2026-07-17T12:00:00Z | walk-strip | FAIL
    - asset: path/to/strip.png
    - issues: frog-leg start; outward toes
    - notes: ...
    - adjustment: re-vid with FEET LOCK; idle from still not frame0

WHY: closed mechanical gates cannot name "toes outward" or "idle eyes too light";
vision judges can, but only if prior failures stay in context.
"""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_context(path: str | Path, *, max_chars: int = 6000) -> str:
    """Return tail of observation journal for injection into a judge prompt."""
    path = Path(path)
    if not path.is_file():
        return ""
    text = path.read_text(encoding="utf-8", errors="replace")
    if len(text) <= max_chars:
        return text
    return text[-max_chars:]


def append(
    path: str | Path,
    *,
    rubric: str,
    ok: bool,
    verdict: str,
    issues: list[str] | None = None,
    notes: str = "",
    asset: str = "",
    adjustment: str = "",
    model: str = "",
) -> Path:
    """Append one judgment block to the journal. Creates file + header if needed."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.is_file():
        path.write_text(
            "# Sprite pipeline observation journal\n\n"
            "Append-only. Loaded by `sprite judge --observe` as prior failure context.\n"
            "Record adjustments so the next gen/vid/bake pass does not re-hit the same mode.\n\n",
            encoding="utf-8",
        )
    status = "PASS" if ok else "FAIL"
    lines = [
        f"## {_now_iso()} | {rubric} | {status}",
        f"- asset: {asset or '(none)'}",
        f"- verdict: {verdict}",
    ]
    if model:
        lines.append(f"- model: {model}")
    if issues:
        lines.append(f"- issues: {'; '.join(issues)}")
    if notes:
        lines.append(f"- notes: {notes.strip()}")
    if adjustment:
        lines.append(f"- adjustment: {adjustment.strip()}")
    lines.append("")
    with path.open("a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return path


def suggest_adjustments(issues: list[str]) -> str:
    """Map known issue strings to pipeline adjustments (deterministic hints)."""
    hints: list[str] = []
    blob = " ".join(issues).lower()
    if "frog" in blob or "wide" in blob or "split" in blob or "first frame" in blob:
        hints.append("use --cycle-start min-stance; prefer idle from still not walk frame0")
    if "foot" in blob or "toe" in blob or "outward" in blob or "splay" in blob:
        hints.append(
            "re-vid with FEET LOCK: shoes point along facing axis (right when "
            "facing right), no duck-foot outward toes; side-profile soles"
        )
    if "eye" in blob or "blob" in blob or "light" in blob or "incongru" in blob:
        hints.append(
            "FACE LOCK two small eyes; bake walk with shared still face; "
            "idle from canonical still bake not walk cell0"
        )
    if "wooden" in blob or "stiff" in blob:
        hints.append("pick --k 8 mid-cycle; --strict-motion; longer r2v duration")
    if "hollow" in blob or "transparent" in blob:
        hints.append("solid body fill; green key; fill-check; bake 32x32")
    # Scenic / parallax plate modes
    if "water" in blob or "cyan" in blob or "lake" in blob or "river" in blob:
        hints.append(
            "regen mid/ground: FORBID blue/cyan water; mid sky pure #FF00FF only; "
            "ground is grass+path only — no horizon water band"
        )
    if "dirt_highway" in blob or "dirt_slab" in blob or "brown" in blob and "bottom" in blob:
        hints.append(
            "regen ground: grass majority 70%+; ONE winding path; no solid brown "
            "bottom quarter; no triple dirt bands"
        )
    if "dirt_under_mid" in blob or "ground strip" in blob:
        hints.append(
            "regen mid: buildings only on magenta; no dirt/grass floor under tents"
        )
    if "sliced" in blob or "sky_bar" in blob or "flat cut" in blob:
        hints.append(
            "regen mid full peaks-to-feet silhouette; hard-fit whole subject; "
            "no pure-sky slab above booth midsections"
        )
    if "disjoint" in blob or "join" in blob:
        hints.append(
            "recompose: mid feet meet ground top; no foreign cyan/pink strip; "
            "shared sunny carnival palette family"
        )
    if "mud" in blob or "chaos" in blob or "confetti pile" in blob:
        hints.append(
            "regen ground: calm NES flat grass; sparse flecks only; path readable"
        )
    if not hints:
        hints.append("re-gen or re-vid with failure issues listed in FACE/FEET LOCK clauses")
    return "; ".join(hints)
