"""sprite_lib.registry -- per-asset manifest + canonical-reference index.

One JSON manifest per baked asset, stored under assets/manifests/<asset>.json:

  {
    "asset": "red_soldier_map",           // stable slug, unique
    "kind": "sprite" | "anim" | "tile" | "sheet",
    "faction": "red_faction" | "blue_faction" | "classic" | null,
    "unit": "soldier" | "scout" | ... | null,    // null for terrain
    "scale": "map" | "battle" | null,
    "prompt": "...",                      // verbatim model prompt (sprite/walk/texture)
    "refs": ["..."],                      // ref image paths (for edit_image variants)
    "template": "sprite" | "texture" | "walk-video" | "raw",
    "params": { ... },                    // model + size + aspect + obj + colors etc.
    "source": "_gen/u.jpg",               // gen output (raster input)
    "output": "gen/u.inc",                // baked .inc
    "frames": 1 | N,
    "size": [W, H],
    "cost_in_usd_ticks": int | null,
    "cache_key": "..." | null,
    "tags": [...],
    "created": "2026-05-20T17:00:00Z",
    "updated": "..." | null
  }

The canonical-reference registry lives at assets/manifests/canonical.json:

  {
    "red_faction.soldier": {
       "canonical": "red_soldier_map",    // asset slug of the locked canonical
       "variants": ["red_soldier_attack", "red_soldier_recolor"]
    },
    ...
  }

The canonical image is the locked "this is what a red_soldier looks like" PNG/JPG;
every variant is generated via /v1/images/edits referencing it, so faction identity
holds by construction.
"""
from __future__ import annotations
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from . import util


# Manifest dir resolved at call time relative to cwd. Run the CLI from your
# asset root (e.g. the game project's assets/ directory). Override per-call
# via the `manifest_dir` kwarg.
def _default_manifest_dir() -> Path:
    return Path.cwd() / "manifests"

CANONICAL_FILE = "canonical.json"

# Mirrors argparse --kind choices on `sprite manifest set`.
VALID_KINDS = frozenset({"sprite", "anim", "tile", "sheet"})


# ============================================================
# per-asset manifest
# ============================================================

def manifest_path(asset: str, manifest_dir: Path | None = None) -> Path:
    base = Path(manifest_dir) if manifest_dir else _default_manifest_dir()
    return base / f"{asset}.json"


def write_manifest(asset: str,
                   kind: str,
                   *,
                   manifest_dir: Path | None = None,
                   faction: str | None = None,
                   unit: str | None = None,
                   scale: str | None = None,
                   prompt: str | None = None,
                   refs: Iterable[str] | None = None,
                   template: str | None = None,
                   params: dict | None = None,
                   source: str | None = None,
                   output: str | None = None,
                   frames: int = 1,
                   size: tuple[int, int] | None = None,
                   cost_in_usd_ticks: int | None = None,
                   cache_key: str | None = None,
                   tags: Iterable[str] | None = None,
                   merge: bool = True) -> dict:
    """Write/update a manifest. With merge=True, existing fields are preserved
    when the new value is None (so partial updates don't blow away history).
    """
    if kind not in VALID_KINDS:
        raise ValueError(
            f"invalid kind {kind!r}; valid kinds: {sorted(VALID_KINDS)}"
        )
    p = manifest_path(asset, manifest_dir)
    p.parent.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    existing: dict = {}
    if merge and p.exists():
        existing = json.loads(p.read_text())
    record = {**existing}
    record["asset"] = asset
    record["kind"] = kind
    # explicit field updates -- None means "leave alone" only if merging
    for k, v in [("faction", faction), ("unit", unit), ("scale", scale),
                 ("prompt", prompt), ("template", template),
                 ("source", source), ("output", output),
                 ("frames", frames), ("size", list(size) if size else None),
                 ("cost_in_usd_ticks", cost_in_usd_ticks),
                 ("cache_key", cache_key)]:
        if v is not None or not merge:
            record[k] = v
    if refs is not None:
        record["refs"] = list(refs)
    elif "refs" not in record:
        record["refs"] = []
    if params is not None:
        record["params"] = dict(params)
    elif "params" not in record:
        record["params"] = {}
    if tags is not None:
        record["tags"] = list(tags)
    elif "tags" not in record:
        record["tags"] = []
    record.setdefault("created", now)
    record["updated"] = now
    util.atomic_write(p, json.dumps(record, indent=2, default=str))
    return record


def get_manifest(asset: str, manifest_dir: Path | None = None) -> dict | None:
    p = manifest_path(asset, manifest_dir)
    if not p.exists():
        return None
    return json.loads(p.read_text())


def list_manifests(manifest_dir: Path | None = None,
                   *,
                   faction: str | None = None,
                   unit: str | None = None,
                   kind: str | None = None) -> list[dict]:
    base = Path(manifest_dir) if manifest_dir else _default_manifest_dir()
    if not base.exists():
        return []
    out: list[dict] = []
    for p in sorted(base.glob("*.json")):
        if p.name == CANONICAL_FILE:
            continue
        rec = json.loads(p.read_text())
        if faction is not None and rec.get("faction") != faction:
            continue
        if unit is not None and rec.get("unit") != unit:
            continue
        if kind is not None and rec.get("kind") != kind:
            continue
        out.append(rec)
    return out


# ============================================================
# canonical registry
# ============================================================

def _canonical_path(manifest_dir: Path | None = None) -> Path:
    base = Path(manifest_dir) if manifest_dir else _default_manifest_dir()
    return base / CANONICAL_FILE


def _load_canonical(manifest_dir: Path | None = None) -> dict:
    p = _canonical_path(manifest_dir)
    if not p.exists():
        return {}
    return json.loads(p.read_text())


def _save_canonical(doc: dict, manifest_dir: Path | None = None) -> None:
    p = _canonical_path(manifest_dir)
    p.parent.mkdir(parents=True, exist_ok=True)
    util.atomic_write(p, json.dumps(doc, indent=2, sort_keys=True))


def _key(faction: str | None, unit: str | None) -> str:
    if not unit:
        raise ValueError("canonical entries need a unit")
    return f"{faction or 'unset'}.{unit}"


def set_canonical(asset: str,
                  *,
                  manifest_dir: Path | None = None) -> dict:
    """Mark `asset` as the canonical reference for its faction+unit (read from
    the asset's manifest). Returns the updated canonical-registry entry."""
    rec = get_manifest(asset, manifest_dir)
    if rec is None:
        raise ValueError(f"manifest {asset!r} not found")
    k = _key(rec.get("faction"), rec.get("unit"))
    doc = _load_canonical(manifest_dir)
    slot = doc.get(k, {"canonical": None, "variants": []})
    # demote any previous canonical to a variant
    if slot["canonical"] and slot["canonical"] != asset and slot["canonical"] not in slot["variants"]:
        slot["variants"].append(slot["canonical"])
    slot["canonical"] = asset
    # ensure asset itself isn't double-listed as a variant
    slot["variants"] = [v for v in slot["variants"] if v != asset]
    doc[k] = slot
    _save_canonical(doc, manifest_dir)
    return {k: slot}


def add_variant(asset: str,
                *,
                manifest_dir: Path | None = None) -> dict:
    """Register `asset` as a variant of its faction+unit's canonical."""
    rec = get_manifest(asset, manifest_dir)
    if rec is None:
        raise ValueError(f"manifest {asset!r} not found")
    k = _key(rec.get("faction"), rec.get("unit"))
    doc = _load_canonical(manifest_dir)
    slot = doc.get(k, {"canonical": None, "variants": []})
    if slot["canonical"] is None:
        # no canonical yet -- this becomes one
        slot["canonical"] = asset
    elif asset != slot["canonical"] and asset not in slot["variants"]:
        slot["variants"].append(asset)
    doc[k] = slot
    _save_canonical(doc, manifest_dir)
    return {k: slot}


def get_canonical(faction: str | None, unit: str,
                  manifest_dir: Path | None = None) -> dict:
    """Return the canonical-registry slot for `faction.unit`, or {} if unset."""
    return _load_canonical(manifest_dir).get(_key(faction, unit), {})


def list_canonical(manifest_dir: Path | None = None) -> dict:
    return _load_canonical(manifest_dir)
