#!/usr/bin/env python3
"""sprite -- agent-forward art harness for the Pascal-GBA pipeline.

One CLI entry point covering the whole generate -> review -> edit -> bake ->
emulate loop. Every subcommand:
  - takes self-contained flags (no interactive prompts);
  - emits artifact paths in its JSON record so the caller can re-feed them;
  - is idempotent (xAI calls cached by prompt+params+ref-hashes);
  - logs every API call to the cost ledger (cwd/ledger.jsonl by default).

Quick recipes (chained one-liners that an agent runs cold):

  # 1. Generate a canonical unit + bake + preview + emulate
  py sprite.py gen "soldier" --colors-per-part "olive uniform" --out _gen/u.jpg \
    && py sprite.py bake _gen/u.jpg --out gen/u.inc --name UNIT --size 32x32 \
    && py sprite.py preview gen/u.inc \
    && py sprite.py emulate gen/u.inc --out gen/u_emu

  # 2. Derive a variant via reference (the coherence engine)
  py sprite.py edit _gen/u.jpg --prompt "same soldier, attacking pose" \
       --out _gen/u_attack.jpg

  # 3. Animated unit from a video clip
  py sprite.py video "soldier marching in place, side view, magenta bg" \
       --duration 3 --out _gen/walk.mp4
  # (then ffmpeg-extract frames, pick keyframes, bake_anim)

  # 4. Tile a uniform texture for terrain
  py sprite.py gen "shallow water texture" --template texture --out _gen/water.jpg
  py sprite.py tile _gen/water.jpg --out gen/water.inc --name WATER

  # 5. Show running cost
  py sprite.py cost

Run `py sprite.py <subcommand> --help` for per-subcommand flags.
"""
from __future__ import annotations
import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from sprite_lib import bake, bgbake, tile, pick, review, edit, emulate, xai, cost, util
from sprite_lib import iso_geom, iso_compose


# ============================================================
# helpers
# ============================================================

def _emit(record: dict, json_mode: bool) -> None:
    """Emit either a JSON line on stdout (machine mode) or a human-readable summary."""
    if json_mode:
        sys.stdout.write(json.dumps(record, default=str) + "\n")
        sys.stdout.flush()
    else:
        op = record.get("op", "?")
        out = record.get("out") or record.get("staged") or record.get("gif") or ""
        extras = []
        for k in ("size", "frames", "colors_used", "obj_order", "cost_in_usd_ticks",
                 "cached", "loop_len", "k", "method", "units", "remapped_slots",
                 "replaced_px", "total_px"):
            if k in record:
                extras.append(f"{k}={record[k]}")
        print(f"[{op}] {out}  " + " ".join(extras))


def _parse_size(s: str) -> tuple[int, int]:
    return util.parse_size(s)


def _parse_rgb_opt(s: str | None) -> tuple[int, int, int] | None:
    return util.parse_rgb(s) if s else None


def _validate_target_tile(s: str) -> str:
    """argparse type=  validator for --target-tile. Accepts any 'WxH' (positive
    ints). Returns the normalized 'WxH' lowercase form so downstream comparison
    is stable. Rejects bad shapes with a clear argparse error."""
    import argparse as _ap
    try:
        w, h = util.parse_size(s)
    except (ValueError, TypeError) as e:
        raise _ap.ArgumentTypeError(f"bad --target-tile {s!r}: {e}")
    if w <= 0 or h <= 0:
        raise _ap.ArgumentTypeError(
            f"--target-tile {s!r}: dimensions must be positive")
    return f"{w}x{h}"


def _ledger_arg(args) -> Path | None:
    """Resolve ledger path: --ledger > SPRITE_LEDGER env > None (cwd/ledger.jsonl)."""
    p = getattr(args, "ledger", None)
    if p:
        return Path(p)
    env = os.environ.get("SPRITE_LEDGER")
    if env:
        return Path(env)
    return None


def resolve_cache_dir(args) -> Path:
    """Resolve cache dir: --cache-dir > SPRITE_CACHE_DIR env > cwd/.cache.

    Shared by gen/edit/video (via _xai_client) and cache list/clear so both
    sides inspect the same directory.
    """
    p = getattr(args, "cache_dir", None)
    if p:
        return Path(p)
    env = os.environ.get("SPRITE_CACHE_DIR")
    if env:
        return Path(env)
    return Path.cwd() / ".cache"


def resolve_manifest_dir(args) -> Path:
    """Resolve manifest dir: --manifest-dir > SPRITE_MANIFEST_DIR env > cwd/manifests."""
    p = getattr(args, "manifest_dir", None)
    if p:
        return Path(p)
    env = os.environ.get("SPRITE_MANIFEST_DIR")
    if env:
        return Path(env)
    return Path.cwd() / "manifests"


def _xai_client(args) -> "xai.XaiClient":
    """Centralized XaiClient construction: threads --auth, --api-key, --ledger,
    --cache-dir, and the retry knobs onto every API-bearing subcommand.
    Progress messages emit to stderr in non-JSON mode so the operator sees
    retry attempts as they happen."""
    import sys as _sys
    if getattr(args, "json", False):
        log = None
    else:
        def log(msg, _s=_sys):
            print(f"[retry] {msg}", file=_s.stderr)
    return xai.XaiClient(
        auth_path=args.auth,
        api_key=getattr(args, "api_key", None),
        ledger=_ledger_arg(args),
        cache_dir=resolve_cache_dir(args),
        retry=getattr(args, "retry", 3),
        retry_base_delay=getattr(args, "retry_base_delay", 2.0),
        retry_max_delay=getattr(args, "retry_max_delay", 30.0),
        progress_log=log,
    )


# ============================================================
# subcommands
# ============================================================

def cmd_gen(args) -> dict:
    if args.template != "texture" and getattr(args, "scale_hint", None):
        raise SystemExit(
            f"--scale-hint applies to --template texture only; got --template {args.template}")
    if args.template == "sprite":
        if not args.subject:
            raise SystemExit("gen --template sprite needs --subject")
        prompt = xai.sprite_prompt(
            args.subject,
            direction=args.direction or "facing forward",
            features=args.features or "",
            palette=args.palette or "",
            silhouette_hint=args.silhouette or "",
            target_tile=args.target_tile,
            colors_per_part=args.colors_per_part or "")
    elif args.template == "texture":
        if not args.subject:
            raise SystemExit("gen --template texture needs --subject (the material)")
        prompt = xai.texture_prompt(
            args.subject,
            target_tile=args.target_tile,
            scale_hint=args.scale_hint or None,
            source_resolution=2048 if args.resolution == "2k" else 1024)
    elif args.template == "ui-icon":
        if not args.subject:
            raise SystemExit("gen --template ui-icon needs --subject")
        prompt = xai.ui_icon_prompt(
            args.subject,
            features=args.features or "",
            palette=args.palette or "",
            target_tile=args.target_tile)
    elif args.template == "ui-nine-slice":
        if not args.subject:
            raise SystemExit("gen --template ui-nine-slice needs --subject (e.g. 'dialog frame')")
        prompt = xai.ui_nine_slice_prompt(
            args.subject,
            palette=args.palette or "",
            cell_target_tile=args.target_tile)
    elif args.template == "portrait":
        if not args.subject:
            raise SystemExit("gen --template portrait needs --subject")
        prompt = xai.portrait_prompt(
            args.subject,
            features=args.features or "",
            palette=args.palette or "",
            expression=args.expression or "neutral",
            target_tile=args.target_tile)
    elif args.template == "walk-video":
        if not args.subject:
            raise SystemExit("gen --template walk-video needs --subject")
        prompt = xai.walk_video_prompt(args.subject,
                                       colors_per_part=args.colors_per_part or "")
    elif args.template == "raw":
        prompt = args.prompt
        if not prompt:
            raise SystemExit("gen --template raw needs --prompt")
    else:
        raise SystemExit(f"unknown template: {args.template}")
    client = _xai_client(args)
    kwargs: dict = {
        "resolution": args.resolution,
        "aspect_ratio": args.aspect,
        "no_cache": args.no_cache,
    }
    if getattr(args, "model", None):
        kwargs["model"] = args.model
    return client.generate_image(prompt, args.out, **kwargs)


def cmd_edit(args) -> dict:
    client = _xai_client(args)
    kwargs: dict = {"resolution": args.resolution, "no_cache": args.no_cache}
    if getattr(args, "model", None):
        kwargs["model"] = args.model
    # aspect_ratio: per docs the server defaults single-ref edits to the input's
    # ratio. Only pass if the caller set it explicitly.
    if getattr(args, "aspect", None):
        kwargs["aspect_ratio"] = args.aspect
    return client.edit_image(args.prompt, args.refs, args.out, **kwargs)


def cmd_video(args) -> dict:
    # Resolve refs (--ref may be one or many; --start-frame is the i2v singular).
    refs = list(args.ref) if args.ref else []
    start_frame = args.start_frame

    # Determine the video mode:
    #   - explicit --mode wins
    #   - else: i2v if --start-frame, r2v if --ref, t2v otherwise
    mode = args.mode
    if mode is None:
        if start_frame:
            mode = "i2v"
        elif refs:
            mode = "r2v"
        else:
            mode = "t2v"

    # Apply the walk-video prompt template when requested -- otherwise pass the
    # raw prompt through.
    if args.template == "walk-video":
        if not args.subject:
            raise SystemExit("video --template walk-video needs --subject")
        # with_reference flips on when ANY ref-bearing mode is active so the
        # prompt scaffolding addresses "the character from the reference image."
        prompt = xai.walk_video_prompt(
            args.subject,
            colors_per_part=args.colors_per_part or "",
            view=args.view or "side view",
            reference_description=args.ref_description or "",
            with_reference=(mode in ("i2v", "r2v")),
            facing=args.facing or "right",
            palette=args.palette or "",
            **({"forbid_anatomy": args.forbid_anatomy} if args.forbid_anatomy is not None else {}))
    elif args.template == "raw":
        prompt = args.prompt
        if not prompt:
            raise SystemExit("video --template raw needs --prompt")
    else:
        raise SystemExit(f"unknown video template: {args.template}")

    client = _xai_client(args)
    kwargs: dict = {
        "mode": mode,
        "duration": args.duration,
        "aspect_ratio": args.aspect,
        "resolution": args.resolution,
        "no_cache": args.no_cache,
    }
    if getattr(args, "model", None):
        kwargs["model"] = args.model
    if mode == "i2v":
        kwargs["start_frame"] = start_frame
    elif mode == "r2v":
        kwargs["references"] = refs
    return client.generate_video(prompt, args.out, **kwargs)


def cmd_extract(args) -> dict:
    from sprite_lib import extract
    return extract.extract_frames(args.mp4, args.out_dir,
                                  fps=args.fps,
                                  start=args.start,
                                  duration=args.duration,
                                  clean=not args.no_clean)


def cmd_bake(args) -> dict:
    return bake.bake_single(args.infile, args.out, args.name,
                            size=_parse_size(args.size),
                            bg=_parse_rgb_opt(args.bg),
                            bg_tol=args.bg_tol,
                            bg_detect=args.bg_detect,
                            colors=args.colors,
                            margin=args.margin,
                            autocrop=not args.no_autocrop,
                            obj=not args.linear,
                            preview=not args.no_preview,
                            gif_ms=args.gif_ms,
                            resample=args.resample,
                            chroma=not args.no_chroma)


def cmd_ui_bake(args) -> dict:
    return bake.bake_nine_slice(args.infile, args.out, args.name,
                                cell_size=_parse_size(args.cell),
                                bg=_parse_rgb_opt(args.bg),
                                bg_tol=args.bg_tol,
                                bg_detect=args.bg_detect,
                                colors=args.colors,
                                chroma=not args.no_chroma,
                                obj=not args.linear,
                                preview=not args.no_preview,
                                gif_ms=args.gif_ms)


def cmd_bg_bake(args) -> dict:
    return bgbake.bake_bg(args.infile, args.out, args.name,
                          colors=args.colors,
                          palettes=args.palettes,
                          max_tiles=args.max_tiles,
                          dedup_flips=not args.no_flip_dedup,
                          preview=not args.no_preview)


def cmd_font_bake(args) -> dict:
    cols, rows = _parse_size(args.grid)
    sc = int(args.start_codepoint, 0) if isinstance(args.start_codepoint, str) else args.start_codepoint
    ec = int(args.end_codepoint, 0) if isinstance(args.end_codepoint, str) and args.end_codepoint else None
    return bake.bake_font_sheet(args.infile, args.out, args.name,
                                grid=(cols, rows),
                                glyph_size=_parse_size(args.glyph_size),
                                start_codepoint=sc,
                                end_codepoint=ec,
                                bg=_parse_rgb_opt(args.bg),
                                bg_tol=args.bg_tol,
                                bg_detect=args.bg_detect,
                                colors=args.colors,
                                chroma=not args.no_chroma,
                                obj=not args.linear,
                                preview=not args.no_preview)

def cmd_anim(args) -> dict:
    return bake.bake_anim(args.frames, args.out, args.name,
                          size=_parse_size(args.size),
                          bg=_parse_rgb_opt(args.bg),
                          bg_tol=args.bg_tol,
                          bg_detect=args.bg_detect,
                          colors=args.colors,
                          margin=args.margin,
                          chroma=not args.no_chroma,
                          obj=not args.linear,
                          preview=not args.no_preview,
                          resample=args.resample,
                          gif_ms=args.gif_ms)


def cmd_tile(args) -> dict:
    return tile.make_tile(args.infile, args.out, args.name,
                          size=_parse_size(args.size),
                          method=args.method,
                          colors=args.colors,
                          preview_3x3=not args.no_preview)


def cmd_pick(args) -> dict:
    return pick.pick_keyframes(args.frames,
                               k=args.k,
                               min_loop=args.min_loop,
                               no_loop=args.no_loop)


def cmd_montage(args) -> dict:
    cell = _parse_size(args.cell) if args.cell else (0, 0)
    return review.montage(args.files, args.out, cols=args.cols, cell=cell,
                          pad=args.pad)


def cmd_gif(args) -> dict:
    return review.gif(args.frames, args.out,
                      frame_ms=args.frame_ms, scale=args.scale, loop=args.loop)


def cmd_tile3x3(args) -> dict:
    return review.tile3x3(args.src, args.out, scale=args.scale)


def cmd_inspect(args) -> dict:
    return review.inspect(args.inc)


def cmd_palette(args) -> dict:
    return review.palette_strip(args.inc, args.out, swatch=args.swatch)


def cmd_diff(args) -> dict:
    return review.diff(args.a, args.b, args.out, delta_amp=args.amp)


def cmd_recolor(args) -> dict:
    # parse "1:#FF0000,2:#00FF00" -> {1: (255,0,0), 2: (0,255,0)}
    cmap: dict[int, tuple[int, int, int]] = {}
    for piece in args.map.split(","):
        piece = piece.strip()
        if not piece:
            continue
        slot_s, rgb_s = piece.split(":", 1)
        cmap[int(slot_s.strip())] = util.parse_rgb(rgb_s.strip())
    return edit.recolor(args.inc, args.out, cmap, name=args.name)


def cmd_rekey(args) -> dict:
    return edit.rekey(args.infile, args.out,
                      old_bg=_parse_rgb_opt(args.old_bg),
                      new_bg=util.parse_rgb(args.new_bg),
                      tol=args.tol,
                      bg_detect=args.bg_detect,
                      chroma=not args.no_chroma)


def cmd_sheet(args) -> dict:
    return edit.sheet(args.incs, args.out, args.name, cols=args.cols)


def cmd_emulate(args) -> dict:
    out_stem = args.out or Path(args.inc).with_suffix("")
    return emulate.emulate(args.inc, out_stem, gif_ms=args.gif_ms,
                           fpc=Path(args.fpc) if args.fpc else None,
                           rebuild=not args.no_rebuild)


def cmd_preview(args) -> dict:
    """Quick preview: render one frame of an .inc to PNG (for visual judgement)."""
    imgs = review.render_inc_frames(args.inc)
    parsed = review._parse_inc(Path(args.inc).read_text())
    out = Path(args.out) if args.out else Path(args.inc).with_suffix(".preview.png")
    out.parent.mkdir(parents=True, exist_ok=True)
    if len(imgs) == 1:
        scale = max(1, 192 // max(parsed["W"], parsed["H"]))
        imgs[0].resize((parsed["W"] * scale, parsed["H"] * scale),
                       __import__("PIL.Image", fromlist=["Image"]).NEAREST).save(out)
    else:
        # multi-frame: strip
        from PIL import Image as PILImage
        scale = max(1, 192 // max(parsed["W"], parsed["H"]))
        strip = PILImage.new("RGB", (parsed["W"] * len(imgs), parsed["H"]))
        for i, im in enumerate(imgs):
            strip.paste(im, (i * parsed["W"], 0))
        strip.resize((parsed["W"] * len(imgs) * scale, parsed["H"] * scale),
                     PILImage.NEAREST).save(out)
    return {"op": "preview", "inc": str(args.inc), "out": str(out),
            "frames": len(imgs), "size": [parsed["W"], parsed["H"]]}


def cmd_cost(args) -> dict:
    rows = cost.read_all(_ledger_arg(args))
    return {"op": "cost", **cost.summarize(rows)}


def cmd_cache(args) -> dict:
    cache_dir = resolve_cache_dir(args)
    if args.cache_op == "list":
        files = [(p.name, p.stat().st_size) for p in cache_dir.iterdir()
                 if p.is_file()] if cache_dir.exists() else []
        return {"op": "cache.list", "dir": str(cache_dir),
                "n": len(files), "files": [{"name": n, "bytes": s} for n, s in files]}
    if args.cache_op == "clear":
        n = 0
        if cache_dir.exists():
            for p in cache_dir.iterdir():
                if p.is_file():
                    p.unlink(); n += 1
        return {"op": "cache.clear", "dir": str(cache_dir), "removed": n}
    raise SystemExit(f"unknown cache op: {args.cache_op}")


def cmd_manifest(args) -> dict:
    """Subdispatch by --op set on the subparser."""
    from sprite_lib import registry
    mdir = resolve_manifest_dir(args)
    if args.m_op == "set":
        size = _parse_size(args.size) if args.size else None
        rec = registry.write_manifest(
            args.asset, args.kind,
            faction=args.faction, unit=args.unit, scale=args.scale,
            prompt=args.prompt, refs=args.refs, template=args.template,
            params=json.loads(args.params) if args.params else None,
            source=args.source, output=args.output,
            frames=args.frames, size=size,
            cost_in_usd_ticks=args.cost_ticks,
            cache_key=args.cache_key,
            tags=args.tags or None,
            merge=not args.no_merge,
            manifest_dir=mdir,
        )
        return {"op": "manifest.set", **rec}
    if args.m_op == "get":
        rec = registry.get_manifest(args.asset, manifest_dir=mdir)
        if rec is None:
            return {"op": "manifest.get", "asset": args.asset, "found": False}
        return {"op": "manifest.get", "found": True, **rec}
    if args.m_op == "list":
        recs = registry.list_manifests(
            manifest_dir=mdir,
            faction=args.faction, unit=args.unit, kind=args.kind)
        return {"op": "manifest.list", "n": len(recs),
                "manifests": [{"asset": r["asset"], "kind": r.get("kind"),
                               "faction": r.get("faction"), "unit": r.get("unit"),
                               "output": r.get("output")} for r in recs]}
    raise SystemExit(f"unknown manifest op: {args.m_op}")


def cmd_iso_geom_preview(args) -> dict:
    """Draw geometry sanity plate: diamond + solid cube + ghost cube on key bg."""
    from PIL import Image

    size = iso_geom.IsoSize.parse(args.size)
    cube_w = size.w if size.w <= 32 else 16
    canvas = Image.new("RGB", (size.w * 3 + 16, max(size.h, cube_w) + 8), (30, 30, 40))
    diamond = iso_geom.paint_diamond(size, (60, 180, 70), outline_rgb=(0, 0, 0))
    canvas.paste(diamond, (4, 4))
    cube = iso_compose.paint_brick_cube(cube_w)
    canvas.paste(cube, (size.w + 8, 4), iso_compose._rgb_key_mask(cube))
    ghost = iso_compose.paint_ghost_cube(cube_w)
    canvas.paste(ghost, (size.w * 2 + 12, 4), iso_compose._rgb_key_mask(ghost))
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    if args.scale != 1:
        canvas = canvas.resize(
            (canvas.width * args.scale, canvas.height * args.scale),
            Image.Resampling.NEAREST,
        )
    canvas.save(out)
    return {
        "op": "iso_geom_preview",
        "out": str(out),
        "size": str(size),
        "half_step": list(size.half_step),
        "contract": "2:1 dimetric",
    }


def cmd_iso_road_bank(args) -> dict:
    """Emit grass + 16 Wang 2-edge road pieces and stitch contact sheets."""
    size = iso_geom.IsoSize.parse(args.size)
    gtex = Path(args.grass) if args.grass else None
    rtex = Path(args.road) if args.road else None
    bank = iso_compose.road_bank(
        size,
        grass_tex=gtex,
        road_tex=rtex,
        lane=args.lane,
    )
    out_dir = Path(args.out_dir)
    paths = iso_compose.save_bank(bank, out_dir)
    stitches = {}
    for pat in ("straight_ns", "straight_ew", "corner", "tee", "cross", "atlas"):
        prev = iso_compose.stitch_preview(bank, pat, size, scale=args.scale)
        pp = out_dir / f"stitch_{pat}.png"
        prev.save(pp)
        stitches[pat] = str(pp)
    return {
        "op": "iso_road_bank",
        "out_dir": str(out_dir),
        "size": str(size),
        "tiles": len(paths),
        "paths": [str(p) for p in paths],
        "stitches": stitches,
        "inventory": "grass + road_00..15 (Wang 2-edge)",
        "mask_bits": {"N": 1, "E": 2, "S": 4, "W": 8},
    }


def cmd_iso_brick(args) -> dict:
    """Emit solid brick cube, Z-plane ghost outline, and ground shadow disc."""
    from PIL import Image

    w = int(args.size)
    mat = Image.open(args.material).convert("RGB") if args.material else None
    solid = iso_compose.paint_brick_cube(w, material_tex=mat, studs=not args.no_studs)
    ghost = iso_compose.paint_ghost_cube(w)
    shadow = iso_compose.paint_ground_shadow(iso_geom.IsoSize(w * 2, w))
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.suffix:
        solid_p = out
        ghost_p = out.with_name(out.stem + "_ghost.png")
        shadow_p = out.with_name(out.stem + "_shadow.png")
    else:
        out.mkdir(parents=True, exist_ok=True)
        solid_p = out / "brick_solid.png"
        ghost_p = out / "brick_ghost.png"
        shadow_p = out / "brick_shadow.png"
    solid.save(solid_p)
    ghost.save(ghost_p)
    shadow.save(shadow_p)
    return {
        "op": "iso_brick",
        "solid": str(solid_p),
        "ghost": str(ghost_p),
        "shadow": str(shadow_p),
        "size": w,
        "z_step": w // 2,
    }


def cmd_iso_stitch(args) -> dict:
    """Re-stitch a previously emitted road bank into a contact-sheet pattern."""
    from PIL import Image

    size = iso_geom.IsoSize.parse(args.size)
    bank_dir = Path(args.bank)
    bank = {}
    for p in sorted(bank_dir.glob("*.png")):
        if p.name.startswith("stitch_"):
            continue
        bank[p.stem] = Image.open(p).convert("RGB")
    if "grass" not in bank:
        bank["grass"] = iso_compose.paint_ground_tile(size)
    prev = iso_compose.stitch_preview(bank, args.pattern, size, scale=args.scale)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    prev.save(out)
    return {
        "op": "iso_stitch",
        "out": str(out),
        "pattern": args.pattern,
        "size": str(size),
        "bank_tiles": len(bank),
    }


def cmd_canonical(args) -> dict:
    from sprite_lib import registry
    mdir = resolve_manifest_dir(args)
    if args.c_op == "set":
        return {"op": "canonical.set",
                **registry.set_canonical(args.asset, manifest_dir=mdir)}
    if args.c_op == "variant":
        return {"op": "canonical.variant",
                **registry.add_variant(args.asset, manifest_dir=mdir)}
    if args.c_op == "get":
        slot = registry.get_canonical(args.faction, args.unit, manifest_dir=mdir)
        return {"op": "canonical.get", "faction": args.faction, "unit": args.unit,
                "slot": slot}
    if args.c_op == "list":
        return {"op": "canonical.list",
                "entries": registry.list_canonical(manifest_dir=mdir)}
    raise SystemExit(f"unknown canonical op: {args.c_op}")


# ============================================================
# argparse wiring
# ============================================================

def build_parser() -> argparse.ArgumentParser:
    # Common flags. Live on subparsers only (not the top-level), so they always
    # come AFTER the subcommand -- argparse otherwise lets the subparser's default
    # silently override a top-level value.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true",
                        help="emit a single-line JSON record on stdout (humans -> stderr)")
    common.add_argument("--auth", default=None,
                        help="path to grok auth.json (default: ~/.grok/auth.json)")
    common.add_argument("--api-key", default=None,
                        help="xAI API key (precedence over XAI_API_KEY env and --auth OAuth)")
    common.add_argument("--ledger", default=None,
                        help="path to cost ledger (default: cwd/ledger.jsonl; env: SPRITE_LEDGER)")
    common.add_argument("--cache-dir", default=None,
                        help="prompt-artifact cache dir (default: cwd/.cache; env: SPRITE_CACHE_DIR)")
    common.add_argument("--manifest-dir", default=None,
                        help="manifest registry dir (default: cwd/manifests; env: SPRITE_MANIFEST_DIR)")
    common.add_argument("--retry", type=int, default=3,
                        help="API retry count for transient 5xx / transport errors "
                             "(default: 3; 0 disables). Exponential backoff: 2s, 4s, 8s, ..., capped at 30s")
    common.add_argument("--retry-base-delay", type=float, default=2.0,
                        help="initial retry delay in seconds (default: 2.0); doubles per attempt")
    common.add_argument("--retry-max-delay", type=float, default=30.0,
                        help="maximum retry delay in seconds (default: 30.0)")
    p = argparse.ArgumentParser(prog="sprite", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=lambda **k:
                           argparse.ArgumentParser(parents=[common], **k))

    # gen
    g = sub.add_parser("gen", help="generate an image from a prompt (xAI Imagine)")
    g.add_argument("subject", nargs="?", default=None,
                   help="subject for built-in templates (e.g. 'soldier')")
    g.add_argument("--template", default="sprite",
                   choices=["sprite", "texture", "ui-icon", "ui-nine-slice", "portrait", "walk-video", "raw"],
                   help="prompt template (default: sprite)")
    g.add_argument("--prompt", default=None, help="raw prompt (for --template raw)")
    g.add_argument("--direction", default=None)
    g.add_argument("--colors-per-part", default=None,
                   help="pin subject colors so the model doesn't bleed key bg into the figure")
    g.add_argument("--features", default=None,
                   help="enumerated visible features (e.g. 'two short horns, large round head, "
                        "square chest plate with delta-triangle, thin sword'). The MORE explicit, "
                        "the less the model invents -- list everything the sprite should have AND "
                        "nothing else")
    g.add_argument("--palette", default=None,
                   help="enumerated allowed colors with hex codes (e.g. 'steel-blue armor #5a78a8, "
                        "dark navy outline #1a2540, cyan glow #00e0e0, white delta #ffffff'). 4-6 "
                        "colors total max")
    g.add_argument("--silhouette", default=None,
                   help="the iconic shape the model must produce at tile scale (e.g. 'horned helmet "
                        "dominates top half, chunky armored torso, stubby legs')")
    g.add_argument("--target-tile", default="32x32", type=_validate_target_tile,
                   help="the GBA tile size this asset is DESIGNED for; drives the "
                        "sprite chunkiness clause, texture feature-scale clause, "
                        "ui-icon scale clause, or portrait composition clause. "
                        "Accepts any 'WxH' (8x8, 16x16, 32x32, 48x48, 64x64, 96x96, 128x128, etc.); "
                        "templates have keyed clauses for common sizes plus a generic "
                        "fallback for arbitrary sizes")
    g.add_argument("--scale-hint", default=None,
                   help="explicit scale-hint override for --template texture only "
                        "(e.g. 'tight 1-pixel-wide horizontal flow lines for a data-channel "
                        "terrain'). When set, wins over the --target-tile auto-derived hint")
    g.add_argument("--expression", default=None,
                   help="expression axis for --template portrait (e.g. 'neutral', 'angry', "
                        "'concerned'). Default: 'neutral'")
    g.add_argument("--resolution", default="1k", choices=["1k", "2k"])
    g.add_argument("--aspect", default="1:1",
                   choices=["1:1", "3:4", "4:3", "9:16", "16:9", "2:3", "3:2",
                            "9:19.5", "19.5:9", "9:20", "20:9", "1:2", "2:1", "auto"],
                   help="image aspect ratio per docs.x.ai (default: 1:1; 'auto' lets the model pick)")
    g.add_argument("--model", default=None,
                   choices=[xai.MODEL_IMAGE_DEFAULT, xai.MODEL_IMAGE_BUDGET],
                   help=f"image model (default: {xai.MODEL_IMAGE_DEFAULT}; "
                        f"{xai.MODEL_IMAGE_BUDGET} for cheaper iteration)")
    g.add_argument("--out", required=True, help="output image path (extension auto if omitted)")
    g.add_argument("--no-cache", action="store_true")
    g.set_defaults(fn=cmd_gen)

    # edit (reference -> variant)
    e = sub.add_parser("edit", help="reference-based variant via /v1/images/edits (1-3 refs)")
    e.add_argument("refs", nargs="+", help="1 to 3 reference image paths")
    e.add_argument("--prompt", required=True)
    e.add_argument("--resolution", default="1k", choices=["1k", "2k"])
    e.add_argument("--aspect", default=None,
                   choices=["1:1", "3:4", "4:3", "9:16", "16:9", "2:3", "3:2",
                            "9:19.5", "19.5:9", "9:20", "20:9", "1:2", "2:1", "auto"],
                   help="output aspect ratio. Default (unset): single-ref edits inherit "
                        "the ref's ratio; multi-ref edits need this set explicitly.")
    e.add_argument("--model", default=None,
                   choices=[xai.MODEL_IMAGE_DEFAULT, xai.MODEL_IMAGE_BUDGET],
                   help=f"image model (default: {xai.MODEL_IMAGE_DEFAULT})")
    e.add_argument("--out", required=True)
    e.add_argument("--no-cache", action="store_true")
    e.set_defaults(fn=cmd_edit)

    # video
    v = sub.add_parser("video", help="generate an mp4 video clip (xAI Imagine Video)")
    v.add_argument("subject", nargs="?", default=None,
                   help="subject for built-in templates (e.g. 'red_soldier')")
    v.add_argument("--template", default="walk-video",
                   choices=["walk-video", "raw"],
                   help="prompt template (default: walk-video; pinned-colour, in-place, magenta bg)")
    v.add_argument("--prompt", default=None, help="raw prompt (for --template raw)")
    v.add_argument("--colors-per-part", default=None,
                   help="pin subject colours so the model doesn't bleed key bg into the figure")
    v.add_argument("--view", default="side view",
                   help="camera view (default: 'side view'; alternatives: 'front view', '3/4 view')")
    v.add_argument("--facing", default="right", choices=["left", "right"],
                   help="character orientation in the walk cycle (drives lead-foot/lead-arm side)")
    v.add_argument("--palette", default=None,
                   help="enumerated allowed colors (e.g. 'steel-blue armor #5a78a8, "
                        "navy outline #1a2540, cyan glow #00e0e0'). The model will "
                        "introduce off-palette colors (especially flesh tones) without this lock")
    v.add_argument("--forbid-anatomy", default=None,
                   help="comma-separated anatomical features to forbid (default forbids "
                        "human face/skin/eyes/hair/fingers to push back against the "
                        "model's human-warrior bias; pass empty string to allow humans)")
    v.add_argument("--mode", default=None, choices=["t2v", "i2v", "r2v"],
                   help="video mode (default: auto -- t2v if no refs, i2v if --start-frame, "
                        "r2v if --ref). t2v=text-only; i2v=starting frame from --start-frame; "
                        "r2v=style/content guide from --ref (1-3 refs).")
    v.add_argument("--ref", nargs="+", default=None,
                   help="reference image(s) for r2v mode -- 1 to 3 paths or HTTPS URLs. "
                        "Identity-anchored video: refs guide style/content without locking "
                        "the first frame.")
    v.add_argument("--start-frame", default=None,
                   help="starting-frame image for i2v mode (single path or HTTPS URL). "
                        "The video begins exactly at this frame; use for animating a "
                        "specific still.")
    v.add_argument("--ref-description", default=None,
                   help="describe the canonical's visible features (horns, palette, weapon, "
                        "glyphs) so the prompt scaffolding addresses 'the character from the "
                        "reference image' -- pairs with --ref to reinforce identity.")
    v.add_argument("--model", default=None,
                   help=f"video model (default: {xai.MODEL_VIDEO_DEFAULT})")
    v.add_argument("--duration", type=int, default=3, help="seconds")
    v.add_argument("--aspect", default="1:1",
                   choices=["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"],
                   help="video aspect ratio (explicit ratios; 9:16 = portrait)")
    v.add_argument("--resolution", default="720p",
                   choices=["480p", "720p", "1080p"],
                   help="video pixel tier (xAI video endpoint takes these, NOT 1k/2k)")
    v.add_argument("--out", required=True)
    v.add_argument("--no-cache", action="store_true")
    v.set_defaults(fn=cmd_video)

    # extract: mp4 -> per-frame PNGs (wraps ffmpeg)
    ex = sub.add_parser("extract", help="extract per-frame PNGs from an mp4 via ffmpeg")
    ex.add_argument("mp4")
    ex.add_argument("--out-dir", required=True,
                    help="frames land at <out-dir>/f_001.png .. f_NNN.png")
    ex.add_argument("--fps", type=int, default=0,
                    help="resample to this FPS; 0 = keep source framerate (default)")
    ex.add_argument("--start", type=float, default=0.0,
                    help="seek to this many seconds before extraction")
    ex.add_argument("--duration", type=float, default=0.0,
                    help="cap extraction at this many seconds; 0 = unbounded")
    ex.add_argument("--no-clean", action="store_true",
                    help="keep existing f_*.png in --out-dir (default: purge first)")
    ex.set_defaults(fn=cmd_extract)

    # bake single
    b = sub.add_parser("bake", help="bake one image into a GBA 4bpp sprite .inc")
    b.add_argument("infile")
    b.add_argument("--out", required=True)
    b.add_argument("--name", required=True)
    b.add_argument("--size", default="32x32")
    b.add_argument("--bg", default=None, help="R,G,B or #HEX; default = auto-detect")
    b.add_argument("--bg-tol", type=int, default=30,
                   help="tolerance for the bg color-distance test (higher = more pixels keyed)")
    b.add_argument("--bg-detect", default="auto", choices=["auto", "corner", "modal"],
                   help="bg auto-detection strategy when --bg is not set: "
                        "'auto' (corner if corners agree, else modal -- default), "
                        "'corner' (modal of the 4 corner patches; robust when subject "
                        "fills the frame), 'modal' (legacy whole-image modal)")
    b.add_argument("--colors", type=int, default=15)
    b.add_argument("--margin", type=int, default=2)
    b.add_argument("--no-chroma", action="store_true",
                   help="disable the brightness-invariant magenta chroma test "
                        "(use for non-magenta-keyed sources)")
    b.add_argument("--no-autocrop", action="store_true")
    b.add_argument("--linear", action="store_true",
                   help="emit scanline-ordered tile data (default: GBA OBJ tile order)")
    b.add_argument("--no-preview", action="store_true")
    b.add_argument("--gif-ms", type=int, default=0)
    b.add_argument("--resample", default="nearest",
                   choices=["nearest", "box", "lanczos"])
    b.set_defaults(fn=cmd_bake)

    # bake animation
    a = sub.add_parser("anim", help="bake N frames into a shared-palette GBA animation .inc")
    a.add_argument("frames", nargs="+", help="frame paths or globs")
    a.add_argument("--out", required=True)
    a.add_argument("--name", required=True)
    a.add_argument("--size", default="32x64")
    a.add_argument("--bg", default=None)
    a.add_argument("--bg-tol", type=int, default=40)
    a.add_argument("--bg-detect", default="auto", choices=["auto", "corner", "modal"],
                   help="bg auto-detection strategy when --bg is not set "
                        "(auto|corner|modal); see `bake --help`")
    a.add_argument("--colors", type=int, default=15)
    a.add_argument("--margin", type=int, default=2)
    a.add_argument("--no-chroma", action="store_true")
    a.add_argument("--resample", default="nearest",
                   choices=["nearest", "box", "lanczos"],
                   help="downscale filter. box area-averages -- preserves small "
                        "features (eyes) at extreme reductions where nearest "
                        "aliases them away; the shared quantize re-crisps")
    a.add_argument("--linear", action="store_true",
                   help="scanline order (default: GBA OBJ tile order)")
    a.add_argument("--no-preview", action="store_true")
    a.add_argument("--gif-ms", type=int, default=110)
    a.set_defaults(fn=cmd_anim)

    # ui-bake (nine-slice)
    ub = sub.add_parser("ui-bake",
                        help="bake a 3x3 source image into a 9-tile nine-slice .inc for UI panel chrome")
    ub.add_argument("infile",
                    help="3x3-layout source image (panel chrome with 9 distinct cells)")
    ub.add_argument("--out", required=True)
    ub.add_argument("--name", required=True)
    ub.add_argument("--cell", default="8x8",
                    help="per-cell target tile size (default: 8x8; 16x16 also common)")
    ub.add_argument("--bg", default=None, help="R,G,B or #HEX; default = auto-detect")
    ub.add_argument("--bg-tol", type=int, default=30)
    ub.add_argument("--bg-detect", default="auto", choices=["auto", "corner", "modal"],
                    help="bg auto-detection strategy when --bg is not set "
                         "(auto|corner|modal); see `bake --help`")
    ub.add_argument("--colors", type=int, default=15)
    ub.add_argument("--no-chroma", action="store_true",
                    help="disable brightness-invariant chroma test")
    ub.add_argument("--linear", action="store_true",
                    help="scanline tile order (default: GBA OBJ tile order)")
    ub.add_argument("--no-preview", action="store_true")
    ub.add_argument("--gif-ms", type=int, default=0,
                    help="preview gif duration ms (0 = no animated preview; nine-slice is static)")
    ub.set_defaults(fn=cmd_ui_bake)

    # bg-bake (full-image tilemap)
    bb = sub.add_parser("bg-bake",
                        help="bake a full image into a deduplicated BG tile set + tilemap + "
                             "palette .inc (text-BG modes; flip-aware dedup)")
    bb.add_argument("infile",
                    help="opaque source image; both dimensions multiples of 8 "
                         "(240x160 = one full screen)")
    bb.add_argument("--out", required=True)
    bb.add_argument("--name", required=True)
    bb.add_argument("--colors", type=int, default=15,
                    help="per-bank palette size 1..15 (default 15; slot 0 stays the backdrop)")
    bb.add_argument("--palettes", type=int, default=1,
                    help="palette banks 1..16 (default 1). >1 clusters tiles into "
                         "independent banks via the map-entry palette bits -- the fix "
                         "for multi-region images that bleed through one shared palette")
    bb.add_argument("--max-tiles", type=int, default=None,
                    help="vector-quantize the tile set to this budget (1..1024) before "
                         "palette work -- for organic sources whose noise makes every "
                         "8x8 cell unique; judge the budget against the preview")
    bb.add_argument("--no-flip-dedup", action="store_true",
                    help="dedup exact tiles only; skip h/v-mirror matching")
    bb.add_argument("--no-preview", action="store_true",
                    help="skip the round-trip preview PNG")
    bb.set_defaults(fn=cmd_bg_bake)

    # font-bake (existing pixel-font sheet ingestion)
    fb = sub.add_parser("font-bake",
                        help="ingest an EXISTING pixel-font sheet and emit a GBA glyph-bank .inc "
                             "(AI font gen is a non-goal -- use existing free fonts)")
    fb.add_argument("infile", help="font sheet image path")
    fb.add_argument("--out", required=True)
    fb.add_argument("--name", required=True)
    fb.add_argument("--grid", required=True,
                    help="COLSxROWS layout of glyph cells (e.g. 16x6 = 96 ASCII printable)")
    fb.add_argument("--glyph-size", default="8x8",
                    help="per-glyph target tile size (default 8x8; 16x16 for chunky fonts)")
    fb.add_argument("--start-codepoint", default="0x20",
                    help="ASCII codepoint of the FIRST glyph in reading order "
                         "(default 0x20 = space; pass 0x00 for full-table fonts; hex/decimal both ok)")
    fb.add_argument("--end-codepoint", default=None,
                    help="OPTIONAL explicit end codepoint; defaults to start + cols*rows - 1")
    fb.add_argument("--bg", default=None, help="R,G,B or #HEX; default = auto-detect")
    fb.add_argument("--bg-tol", type=int, default=30)
    fb.add_argument("--bg-detect", default="auto", choices=["auto", "corner", "modal"])
    fb.add_argument("--colors", type=int, default=3,
                    help="palette size (default 3: transparent + fg + outline)")
    fb.add_argument("--no-chroma", action="store_true",
                    help="disable brightness-invariant chroma test (irrelevant for black/white sheets)")
    fb.add_argument("--linear", action="store_true",
                    help="scanline tile order (default: GBA OBJ tile order)")
    fb.add_argument("--no-preview", action="store_true")
    fb.set_defaults(fn=cmd_font_bake)

    # tile
    t = sub.add_parser("tile", help="make a seamless GBA terrain tile .inc")
    t.add_argument("infile")
    t.add_argument("--out", required=True)
    t.add_argument("--name", required=True)
    t.add_argument("--size", default="32x32")
    t.add_argument("--method", default="offset", choices=["offset", "mirror"])
    t.add_argument("--colors", type=int, default=15)
    t.add_argument("--no-preview", action="store_true")
    t.set_defaults(fn=cmd_tile)

    # pick keyframes
    pk = sub.add_parser("pick", help="loop-detect + arc-length keyframe pick")
    pk.add_argument("frames", nargs="+")
    pk.add_argument("--k", type=int, default=6)
    pk.add_argument("--min-loop", type=int, default=8)
    pk.add_argument("--no-loop", action="store_true")
    pk.set_defaults(fn=cmd_pick)

    # montage / gif / tile3x3 / inspect / palette / diff / preview
    m = sub.add_parser("montage", help="contact-sheet grid of images")
    m.add_argument("files", nargs="+")
    m.add_argument("--out", required=True)
    m.add_argument("--cols", type=int, default=0)
    m.add_argument("--cell", default=None, help="cell size WxH; default = first image's size")
    m.add_argument("--pad", type=int, default=4)
    m.set_defaults(fn=cmd_montage)

    gp = sub.add_parser("gif", help="looping GIF preview from a frame sequence")
    gp.add_argument("frames", nargs="+")
    gp.add_argument("--out", required=True)
    gp.add_argument("--frame-ms", type=int, default=110)
    gp.add_argument("--scale", type=int, default=0, help="0 = auto-scale to ~192px")
    gp.add_argument("--loop", type=int, default=0, help="0 = infinite")
    gp.set_defaults(fn=cmd_gif)

    tt = sub.add_parser("tile3x3", help="3x3 tiled preview from a PNG or .inc")
    tt.add_argument("src")
    tt.add_argument("--out", required=True)
    tt.add_argument("--scale", type=int, default=4)
    tt.set_defaults(fn=cmd_tile3x3)

    ins = sub.add_parser("inspect", help="parse a baked .inc and report metadata")
    ins.add_argument("inc")
    ins.set_defaults(fn=cmd_inspect)

    pl = sub.add_parser("palette", help="render palette swatches from a baked .inc")
    pl.add_argument("inc")
    pl.add_argument("--out", required=True)
    pl.add_argument("--swatch", type=int, default=32)
    pl.set_defaults(fn=cmd_palette)

    df = sub.add_parser("diff", help="side-by-side + delta map of two images")
    df.add_argument("a"); df.add_argument("b")
    df.add_argument("--out", required=True)
    df.add_argument("--amp", type=int, default=4, help="delta amplification")
    df.set_defaults(fn=cmd_diff)

    pv = sub.add_parser("preview", help="render one frame of an .inc to PNG (NN upscale)")
    pv.add_argument("inc")
    pv.add_argument("--out", default=None)
    pv.set_defaults(fn=cmd_preview)

    # edit ops
    rc = sub.add_parser("recolor", help="swap palette slots in a baked .inc (no pixel work)")
    rc.add_argument("inc")
    rc.add_argument("--map", required=True,
                    help="palette remap: \"1:#FF0000,5:#00AA00\" (slot 0 reserved transparent)")
    rc.add_argument("--out", required=True)
    rc.add_argument("--name", default=None, help="override NAME prefix in the output .inc")
    rc.set_defaults(fn=cmd_recolor)

    rk = sub.add_parser("rekey", help="swap background color in a PNG/JPG")
    rk.add_argument("infile")
    rk.add_argument("--out", required=True)
    rk.add_argument("--old-bg", default=None, help="auto-detect modal if omitted")
    rk.add_argument("--new-bg", required=True, help="R,G,B or #HEX")
    rk.add_argument("--tol", type=int, default=40)
    rk.add_argument("--bg-detect", default="auto", choices=["auto", "corner", "modal"],
                    help="bg auto-detection strategy when --old-bg is not set "
                         "(auto|corner|modal); see `bake --help`")
    rk.add_argument("--no-chroma", action="store_true",
                    help="disable magenta-chroma test (for non-magenta-keyed sources)")
    rk.set_defaults(fn=cmd_rekey)

    sh = sub.add_parser("sheet", help="combine multiple .incs into one tile bank + metadata table")
    sh.add_argument("incs", nargs="+")
    sh.add_argument("--out", required=True)
    sh.add_argument("--name", required=True)
    sh.add_argument("--cols", type=int, default=0)
    sh.set_defaults(fn=cmd_sheet)

    # emulate
    em = sub.add_parser("emulate", help="render a baked .inc through the real PPU and dump PNGs+GIF")
    em.add_argument("inc")
    em.add_argument("--out", default=None,
                    help="output stem (default: <inc-stem>_emu)")
    em.add_argument("--gif-ms", type=int, default=110)
    em.add_argument("--fpc", default=None, help="override FPC path")
    em.add_argument("--no-rebuild", action="store_true",
                    help="reuse existing sprite_smoke.exe if present")
    em.set_defaults(fn=cmd_emulate)

    # cost + cache
    co = sub.add_parser("cost", help="show running cost ledger summary")
    co.set_defaults(fn=cmd_cost)

    ca = sub.add_parser("cache", help="manage the prompt-artifact cache")
    ca.add_argument("cache_op", choices=["list", "clear"])
    ca.set_defaults(fn=cmd_cache)

    # registry: manifest CRUD + canonical-reference index
    mf = sub.add_parser("manifest", help="per-asset manifest CRUD (set/get/list)")
    mf_sub = mf.add_subparsers(dest="m_op", required=True, parser_class=lambda **k:
                               argparse.ArgumentParser(parents=[common], **k))
    mf_set = mf_sub.add_parser("set", help="write/update a manifest entry")
    mf_set.add_argument("asset", help="unique slug (e.g. red_soldier_map)")
    mf_set.add_argument("--kind", required=True,
                        choices=["sprite", "anim", "tile", "sheet"])
    mf_set.add_argument("--faction", default=None)
    mf_set.add_argument("--unit", default=None)
    mf_set.add_argument("--scale", default=None,
                        choices=["map", "battle", None], nargs="?")
    mf_set.add_argument("--prompt", default=None)
    mf_set.add_argument("--refs", nargs="*", default=None)
    mf_set.add_argument("--template", default=None,
                        choices=["sprite", "texture", "walk-video", "raw", None],
                        nargs="?")
    mf_set.add_argument("--params", default=None, help="JSON object of model params")
    mf_set.add_argument("--source", default=None, help="raster input path")
    mf_set.add_argument("--output", default=None, help="baked .inc path")
    mf_set.add_argument("--frames", type=int, default=1)
    mf_set.add_argument("--size", default=None, help="WxH")
    mf_set.add_argument("--cost-ticks", type=int, default=None)
    mf_set.add_argument("--cache-key", default=None)
    mf_set.add_argument("--tags", nargs="*", default=None)
    mf_set.add_argument("--no-merge", action="store_true",
                        help="replace the manifest entirely (default: merge with existing)")
    mf_set.set_defaults(fn=cmd_manifest)
    mf_get = mf_sub.add_parser("get", help="read a manifest by asset name")
    mf_get.add_argument("asset")
    mf_get.set_defaults(fn=cmd_manifest)
    mf_list = mf_sub.add_parser("list", help="list manifests, optionally filtered")
    mf_list.add_argument("--faction", default=None)
    mf_list.add_argument("--unit", default=None)
    mf_list.add_argument("--kind", default=None)
    mf_list.set_defaults(fn=cmd_manifest)

    can = sub.add_parser("canonical", help="canonical-reference registry (set/variant/get/list)")
    can_sub = can.add_subparsers(dest="c_op", required=True, parser_class=lambda **k:
                                 argparse.ArgumentParser(parents=[common], **k))
    can_set = can_sub.add_parser("set", help="mark asset as the canonical for its faction.unit")
    can_set.add_argument("asset")
    can_set.set_defaults(fn=cmd_canonical)
    can_var = can_sub.add_parser("variant", help="register asset as a variant under its canonical")
    can_var.add_argument("asset")
    can_var.set_defaults(fn=cmd_canonical)
    can_get = can_sub.add_parser("get", help="look up the canonical for a faction.unit")
    can_get.add_argument("--faction", default=None)
    can_get.add_argument("--unit", required=True)
    can_get.set_defaults(fn=cmd_canonical)
    can_ls = can_sub.add_parser("list", help="dump the whole canonical index")
    can_ls.set_defaults(fn=cmd_canonical)

    # ---- isometric tileset primitives (offline geometry + optional textures) ----
    ig = sub.add_parser(
        "iso-geom-preview",
        help="draw 2:1 diamond + brick cube + ghost (geometry contract plate)",
    )
    ig.add_argument("--size", default="32x16",
                    help="ground diamond WxH; must be 2:1 even (default 32x16)")
    ig.add_argument("--out", required=True, help="output PNG path")
    ig.add_argument("--scale", type=int, default=4, help="nearest-neighbor upscale")
    ig.set_defaults(fn=cmd_iso_geom_preview)

    ir = sub.add_parser(
        "iso-road-bank",
        help="emit grass + 16 Wang 2-edge road tiles and stitch previews",
    )
    ir.add_argument("--size", default="32x16", help="ground diamond WxH (2:1)")
    ir.add_argument("--out-dir", required=True, help="directory for tile PNGs + stitches")
    ir.add_argument("--grass", default=None, help="optional grass texture image")
    ir.add_argument("--road", default=None, help="optional asphalt texture image")
    ir.add_argument("--lane", type=float, default=0.40,
                    help="lane half-width in diamond UV (default 0.40)")
    ir.add_argument("--scale", type=int, default=3, help="stitch preview upscale")
    ir.set_defaults(fn=cmd_iso_road_bank)

    ib = sub.add_parser(
        "iso-brick",
        help="emit solid brick cube + Z ghost + ground shadow (shared geometry)",
    )
    ib.add_argument("--size", type=int, default=16,
                    help="cube width in pixels (even; default 16 -> 16x16 AABB)")
    ib.add_argument("--out", required=True,
                    help="output PNG path (or directory without extension)")
    ib.add_argument("--material", default=None, help="optional material texture")
    ib.add_argument("--no-studs", action="store_true", help="omit LEGO-like studs")
    ib.set_defaults(fn=cmd_iso_brick)

    ist = sub.add_parser(
        "iso-stitch",
        help="compose a road-bank directory into a named stitch contact sheet",
    )
    ist.add_argument("--bank", required=True, help="directory with grass.png + road_00..15.png")
    ist.add_argument("--pattern", default="cross",
                     choices=["straight_ns", "straight_ew", "corner", "tee",
                              "cross", "atlas"],
                     help="neighbor layout to prove (default cross)")
    ist.add_argument("--size", default="32x16", help="tile size matching the bank")
    ist.add_argument("--out", required=True, help="output PNG path")
    ist.add_argument("--scale", type=int, default=3, help="nearest-neighbor upscale")
    ist.set_defaults(fn=cmd_iso_stitch)

    return p


# ============================================================
# main
# ============================================================

def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        rec = args.fn(args)
        _emit(rec, json_mode=args.json)
        return 0
    except SystemExit:
        raise
    except Exception as e:
        err = {"op": getattr(args, "cmd", "?"), "error": str(e),
               "error_type": type(e).__name__}
        if args.json:
            sys.stdout.write(json.dumps(err) + "\n")
        else:
            print(f"ERROR [{err['op']}]: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
