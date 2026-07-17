"""sprite_lib.judge -- vision judgment layer for baked/preview art.

Mechanical gates (fill, face-blob, motion, stance) catch quantitative defects.
Pose failures (frog-leg starts, feet facing wrong way, uncanny eyes) need a
vision pass. This module calls xAI chat completions with image inputs and a
closed rubric, returning structured PASS/FAIL JSON.

Auth: same as gen/edit/video (XAI_API_KEY or grok OAuth via XaiClient).
Default model: SPRITE_JUDGE_MODEL env or grok-4.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Sequence

from . import cost, util
from .xai import XaiClient, XaiError, _data_uri_for_path, resolve_token

DEFAULT_JUDGE_MODEL = os.environ.get("SPRITE_JUDGE_MODEL", "grok-4")

RUBRICS: dict[str, str] = {
    "walk-strip": """You are reviewing a GBA-style pixel-art WALK CYCLE contact sheet
(frames left-to-right). Judge at 32x32 character quality for a kid game.
If a second image is provided it is the canonical STILL — compare eye treatment.

FAIL if ANY of these are true:
1. FIRST FRAME (leftmost) is a bad idle/start: legs wide frog-split, feet pointing
   opposite directions, or pose unusable as standing/loop start.
2. Feet duck-splay: BOTH toes point outward (away from each other) instead of
   forward along the walk axis (when facing right, toes should point right /
   profile, not left-and-right like a duck). Check EVERY frame.
3. Eyes are malformed: fused into one white blob, one eye much larger, smeared
   white mass, or eyes much lighter/blown-out vs a readable dual-eye face.
4. Eye incongruity: walk eyes much paler/blown vs the still (when provided) or
   wild brightness changes frame-to-frame across the strip.
5. Severe artifacts: missing limbs, double heads, obvious glitches.

PASS if the cycle is side-view walk with consistent facing, usable first frame
(feet roughly under hips or clean contact), feet point along facing, and readable face.

Respond with ONLY compact JSON (no markdown):
{"ok": true|false, "verdict": "PASS"|"FAIL", "issues": ["..."], "notes": "one short sentence"}
""",
    "sprite-still": """You are reviewing a single GBA-style pixel sprite (or NN upscale).

FAIL if: hollow/transparent body center, fused eye blob, severe color key holes,
missing limbs, unreadable silhouette at arm length.

PASS if solid readable character/prop with coherent face (if present).

Respond with ONLY compact JSON (no markdown):
{"ok": true|false, "verdict": "PASS"|"FAIL", "issues": ["..."], "notes": "one short sentence"}
""",
    "generic": """You are reviewing pixel art for a Game Boy Advance game.

FAIL on severe quality defects that would be unacceptable in a shipped cart
(hollow body, broken face, unreadable silhouette, glitched limbs).

Respond with ONLY compact JSON (no markdown):
{"ok": true|false, "verdict": "PASS"|"FAIL", "issues": ["..."], "notes": "one short sentence",
 "action": "pass"|"regen"|"rebake"|"edit", "adjustment": "short pipeline fix instruction"}
""",
    "scenic-mid-strip": """You review a GBA mode-0 MID SKYLINE strip (or mid on sky composite).

Doctrine (FAIL if violated):
1. Sky/air must be pure chroma key magenta OR transparent showing a clean sky —
   NEVER painted blue water, cyan rivers, lakes, or solid non-magenta horizon fills
   between buildings and the play band.
2. Buildings/tents/rides form a readable SILHOUETTE (peaks→feet). Tops not sliced flat.
3. NO dirt path, grass floor, or brown bar under buildings (ground is a separate layer).
4. NO people, NO readable text/logos (garbled text is FAIL).
5. Chunky NES/GBA flat colors; not photo-mush.

PASS only if magenta/transparent sky, solid carnival silhouette, no water band, no ground strip.

Respond with ONLY compact JSON (no markdown):
{"ok": true|false, "verdict": "PASS"|"FAIL",
 "issues": ["water_band"|"dirt_under_mid"|"sliced_peaks"|"text"|"mud"|"other"],
 "notes": "one short sentence",
 "action": "pass"|"regen_mid"|"rebake",
 "adjustment": "concrete re-prompt or rebake instruction if FAIL"}
""",
    "scenic-ground-plate": """You review a GBA WALK-BAND ground plate (floor only).

Doctrine (FAIL if violated):
1. ENTIRE frame is floor: grass/dirt path. NO sky, NO cyan/blue water horizon bands,
   NO full buildings/tents/ferris as structures.
2. Grass majority (~60%+). ONE clear winding dirt path with texture — not a solid
   brown bottom rectangle, not triple stacked dirt highways.
3. Calm readable NES: soft tufts/flecks OK; muddy chaos/confetti piles FAIL.
4. Path must join the top of the plate naturally (near skyline feet) without a
   foreign water/cyan strip.

Respond with ONLY compact JSON (no markdown):
{"ok": true|false, "verdict": "PASS"|"FAIL",
 "issues": ["water_band"|"dirt_highway"|"sky_in_ground"|"buildings"|"mud"|"other"],
 "notes": "one short sentence",
 "action": "pass"|"regen_ground"|"rebake",
 "adjustment": "concrete re-prompt or rebake instruction if FAIL"}
""",
    "scenic-compose": """You review a FULL 3-layer GBA parallax PREVIEW (sky + mid strip + ground plate).

Doctrine (FAIL if violated):
1. Clean join: mid silhouette sits on ground — NO cyan/blue water band, NO pink/purple
   bar, NO empty gap strip between mid feet and grass.
2. Mid skyline readable (tents/ferris/bunting); not crushed/sliced flat under a solid sky bar.
3. Ground is fairground grass + path; not solid brown bottom quarter; not muddy noise.
4. Sunny carnival family; layers feel one place not three unrelated images glued.

Respond with ONLY compact JSON (no markdown):
{"ok": true|false, "verdict": "PASS"|"FAIL",
 "issues": ["water_join"|"sky_bar"|"dirt_slab"|"mud_ground"|"disjoint"|"sliced_mid"|"other"],
 "notes": "one short sentence",
 "action": "pass"|"regen_mid"|"regen_ground"|"regen_sky"|"regen_all"|"rebake",
 "adjustment": "which layer to fix and how"}
""",
}


def _parse_judge_json(text: str) -> dict:
    text = (text or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    m = re.search(r"\{[\s\S]*\}", text)
    if not m:
        return {
            "ok": False,
            "verdict": "FAIL",
            "issues": ["judge_unparseable"],
            "notes": text[:200],
            "raw": text[:500],
        }
    try:
        data = json.loads(m.group(0))
    except json.JSONDecodeError:
        return {
            "ok": False,
            "verdict": "FAIL",
            "issues": ["judge_json_error"],
            "notes": text[:200],
            "raw": text[:500],
        }
    ok = bool(data.get("ok", data.get("verdict") == "PASS"))
    action = str(data.get("action") or ("pass" if ok else "regen")).strip().lower()
    if ok:
        action = "pass"
    return {
        "ok": ok,
        "verdict": data.get("verdict") or ("PASS" if ok else "FAIL"),
        "issues": list(data.get("issues") or []),
        "notes": str(data.get("notes") or ""),
        "action": action,
        "adjustment": str(data.get("adjustment") or ""),
        "raw": text[:500],
    }


def judge_images(
    paths: Sequence[str | Path],
    *,
    rubric: str = "walk-strip",
    model: str | None = None,
    auth_path: Path | None = None,
    api_key: str | None = None,
    extra_prompt: str = "",
    no_cache: bool = False,
    ledger: Path | None = None,
    cache_dir: Path | None = None,
    observe_path: str | Path | None = None,
    adjustment: str = "",
) -> dict:
    """Vision-judge one or more images against a named rubric.

    If ``observe_path`` is set, prior journal context is injected into the
    prompt and this judgment is appended (with optional ``adjustment`` or
    auto-suggested fixes from :mod:`observe`).
    """
    from . import observe as observe_mod

    paths = [Path(p) for p in paths]
    for p in paths:
        if not p.is_file():
            raise FileNotFoundError(f"judge: missing image {p}")

    rubric_key = rubric if rubric in RUBRICS else "generic"
    system = RUBRICS[rubric_key]
    # Bake/vid pipeline awareness for the vision model
    system += (
        "\n\nPipeline context (you are a gate before cart entry):\n"
        "- GBA 32x32 OBJ, 4bpp shared palette, index-0 transparent.\n"
        "- Walk cycles: side view, in-place, k=6-8 frames; idle should match "
        "canonical still eyes (not a random walk cell).\n"
        "- Feet must point along facing (forward), not both splayed outward.\n"
        "- Known failure modes: frog-leg frame0, outward toes, fused white eyes, "
        "hollow body, wooden low motion.\n"
    )
    if observe_path:
        prior = observe_mod.load_context(observe_path)
        if prior:
            system += (
                "\n\nPrior observation journal (do not repeat unfixed modes; "
                "prefer adjustments already listed):\n"
                f"{prior}\n"
            )
    if extra_prompt:
        system = system + "\n\nAdditional criteria:\n" + extra_prompt

    model = model or DEFAULT_JUDGE_MODEL
    client = XaiClient(
        auth_path=auth_path,
        api_key=api_key,
        cache_dir=cache_dir,
        ledger=ledger,
    )

    cache_payload = {
        "op": "judge",
        "model": model,
        "rubric": rubric_key,
        "extra": extra_prompt,
        "refs": [util.file_sha(p) for p in paths],
    }
    ck = util.stable_hash(cache_payload)[:16]
    cache_path = client.cache_dir / f"judge_{ck}.json"
    if not no_cache and cache_path.is_file():
        data = json.loads(cache_path.read_text(encoding="utf-8"))
        data["cached"] = True
        data["cache_key"] = ck
        return data

    content: list[dict] = [{"type": "text", "text": system}]
    for p in paths:
        content.append({
            "type": "image_url",
            "image_url": {"url": _data_uri_for_path(p), "detail": "high"},
        })

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "temperature": 0.1,
        "max_tokens": 400,
    }

    resp = client._post_json("/v1/chat/completions", payload, op="judge")
    try:
        text = resp["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as e:
        raise XaiError(
            f"judge: bad response shape: {e}",
            body=str(resp)[:400],
            op="judge",
        ) from e

    parsed = _parse_judge_json(text)
    ticks = 0
    usage = resp.get("usage") or {}
    if "cost_in_usd_ticks" in usage:
        ticks = int(usage["cost_in_usd_ticks"])
    cost.append(
        {
            "op": "judge",
            "model": model,
            "rubric": rubric_key,
            "cost_in_usd_ticks": ticks,
            "paths": [str(p) for p in paths],
            "ok": parsed["ok"],
        },
        ledger=client.ledger,
    )

    adj = (
        adjustment.strip()
        or str(parsed.get("adjustment") or "").strip()
        or observe_mod.suggest_adjustments(list(parsed.get("issues") or []))
    )
    action = str(parsed.get("action") or ("pass" if parsed.get("ok") else "regen"))
    out = {
        "op": "judge",
        "model": model,
        "rubric": rubric_key,
        "paths": [str(p) for p in paths],
        "cached": False,
        "cache_key": ck,
        "adjustment": adj,
        "action": action,
        **{k: v for k, v in parsed.items() if k not in ("adjustment", "action")},
    }
    if observe_path:
        observe_mod.append(
            observe_path,
            rubric=rubric_key,
            ok=bool(out.get("ok")),
            verdict=str(out.get("verdict") or ""),
            issues=list(out.get("issues") or []),
            notes=str(out.get("notes") or ""),
            asset=", ".join(str(p) for p in paths),
            adjustment=adj,
            model=model,
        )
        out["observe_path"] = str(Path(observe_path))
    client.cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(out, indent=2), encoding="utf-8")
    return out
