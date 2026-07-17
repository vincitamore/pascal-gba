# PIPELINE -- sprite/asset pipeline doctrine

Universal conventions for generating, baking, and validating GBA-ready
sprite, terrain, UI, portrait, and font assets with `sprite.py`. Command
surface: `py sprite.py <subcommand> --help`. This file is production
discipline; project-specific cast lists and ship scope live in each
consumer's own notes.

## Table of contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Installation](#installation)
4. [Authentication](#authentication)
5. [Configuration](#configuration)
6. [Asset taxonomy](#asset-taxonomy)
7. [Folder structure](#folder-structure)
8. [Naming convention](#naming-convention)
9. [The canonical workflow](#the-canonical-workflow)
10. [Completion checklist per scale](#completion-checklist-per-scale)
11. [Prompt formulas](#prompt-formulas)
12. [Bake settings reference](#bake-settings-reference)
13. [Offline vs online stage reference](#offline-vs-online-stage-reference)
14. [Failure modes and recovery](#failure-modes-and-recovery)
15. [Pipeline economics](#pipeline-economics)
16. [Isometric tilesets](#isometric-tilesets)
17. [Extension contracts](#extension-contracts)
18. [Cross-links](#cross-links)

---

## Overview

The pipeline turns a design brief into GBA 4bpp `.inc` data the FPC
consumer can `{$I}`:

```
prompt -> gen | edit | video -> (extract/pick) -> bake | anim | tile | ui-bake | font-bake | bg-bake
       -> preview | emulate -> manifest / canonical registry

iso-geom-preview | iso-road-bank | iso-brick | iso-stitch  (offline tileset primitives)
```

Most subcommands run fully offline with no network and no credentials.
Only `gen`, `edit`, and `video` call the xAI Imagine API. Isometric bank
generation is always offline (geometry + optional local textures).
See [Offline vs online stage reference](#offline-vs-online-stage-reference)
and [Isometric tilesets](#isometric-tilesets).

Path defaults (ledger, manifests, prompt cache) resolve against **cwd at
invocation**, not against the script location. Run the CLI from the asset
root you intend to write into, or pass the path flags / env vars in
[Configuration](#configuration).

---

## Prerequisites

| Dependency | How | Required by |
|---|---|---|
| Python 3.10+ | host install | all subcommands |
| `requests`, `Pillow` | `pip install -r requirements.txt` | all subcommands that touch images or the API |
| `ffmpeg` on PATH | host package manager | `extract` only |
| Host FPC compiler | host install; pass `--fpc` if not at the Windows Lazarus default | `emulate` only |

If you only bake and inspect local rasters, Python + `requirements.txt`
is enough. Skip `ffmpeg` until you extract video frames; skip FPC until
you want a real-PPU smoke render.

---

## Installation

From a clone of this repo:

```bash
cd assets
python -m pip install -r requirements.txt
```

A virtualenv is recommended but not required. Invoke the CLI as:

```bash
python sprite.py <subcommand> ...
# or, from the asset root of a consumer project:
python /path/to/pascal-gba/assets/sprite.py <subcommand> ...
```

There is no wheel and no console-script entry point; `sprite.py` inserts
its own directory on `sys.path` so `sprite_lib` resolves.

---

## Authentication

Only `gen`, `edit`, and `video` need credentials. Every other subcommand
constructs no client and never reads a key.

### Recommended: standing API key

1. Create a key at https://console.x.ai/team/default/api-keys
2. **Grant endpoint and model access.** Keys are default-deny: a fresh key
   authenticates as a bearer but image/video calls fail until you grant
   ACLs for the endpoints and models you plan to use (images + videos for
   this pipeline; wildcards are supported in the console).
3. Export it:

```bash
export XAI_API_KEY="your_api_key"          # Unix
setx XAI_API_KEY "your_api_key"            # Windows (new shells)
```

### Precedence (highest wins)

| Rank | Source | Notes |
|---|---|---|
| 1 | `--api-key KEY` | CLI flag on every subcommand. Least preferred: lands in shell history and process listings. Prefer the env var. |
| 2 | `XAI_API_KEY` env | Documented-first path; matches xAI's own tooling name. |
| 3 | OAuth file via `--auth PATH` (default `~/.grok/auth.json`) | For users who already run the grok CLI and want to ride an existing subscription allowance instead of a standing key. |

If nothing resolves, `gen`/`edit`/`video` fail immediately with an
actionable one-line error (no network timeout). See
[Failure modes](#failure-modes-and-recovery).

### Entitlement split (read once)

- **Standing `XAI_API_KEY`** is a separate pay-per-use product: billed per
  image/video call against the console.x.ai account that owns the key
  (about $0.05 per 1k image, about $0.30 for a 6s 720p r2v video; see
  [Pipeline economics](#pipeline-economics)).
- **OAuth ride** (`grok login` -> `~/.grok/auth.json`) uses an existing
  subscription allowance when available. No separate key billing setup,
  but it requires the grok CLI logged in.

Same `Authorization: Bearer ...` header either way; only acquisition
differs. Pick the path that matches what you already have.

---

## Configuration

Three path roots resolve independently. No config file. For each root,
highest wins:

| Root | CLI flag | Env var | Default |
|---|---|---|---|
| prompt-artifact cache | `--cache-dir PATH` | `SPRITE_CACHE_DIR` | `cwd/.cache` |
| cost ledger | `--ledger PATH` | `SPRITE_LEDGER` | `cwd/ledger.jsonl` |
| manifests + canonical index | `--manifest-dir PATH` | `SPRITE_MANIFEST_DIR` | `cwd/manifests` |

Vendor secret keeps the vendor name `XAI_API_KEY` (no `SPRITE_` prefix).
Tool-local path roots use `SPRITE_*`.

`--out` is always required on generation and bake subcommands. That is
intentional: paid or destructive writes never invent a filename.

### First smoke vs real project layout

| Mode | Destination | When |
|---|---|---|
| First smoke | `out/<name>.png` / `out/<name>.inc` | Flat scratch under cwd; good for a single offline bake |
| Real project | `_gen/` + `sprites/` tree below | Structured production layout; see [Folder structure](#folder-structure) |

---

## Asset taxonomy

Every artifact falls into exactly one kind. Confusing kinds is the first
symptom of a broken workflow.

| Kind | What it is | Source | Output | Where it lands |
|---|---|---|---|---|
| **Canonical still** | Locked-look reference image for one unit at one scale. Every variant traces back to it. | `sprite gen --template sprite` | High-res JPEG/PNG (~1k or 2k) | `_gen/canonical/` |
| **Animation source** | Short video clip that drives a sprite animation. | `sprite video --mode r2v --ref <canonical>` | MP4 + per-frame PNGs after extract | `_gen/animations/` |
| **Faction variant** | Recolored / re-styled version of a canonical via reference editing. Same silhouette as the source. | `sprite edit <canonical>` or multi-ref edit | High-res JPEG/PNG | `_gen/canonical/` (faction-suffixed name) |
| **Baked sprite** | Game-ready GBA `.inc` with packed tile data + palette. `{$I name.inc}` in FPC. | `sprite bake` or `sprite anim` | `.inc` + `.strip.png` preview + optional `.gif` | `sprites/units/<faction>/<archetype>/<scale>/` |
| **Terrain tile** | Seamless tileable terrain texture, baked. | `sprite gen --template texture` -> `sprite tile` | `.inc` + `_3x3.png` preview | `sprites/terrain/` |
| **UI icon** | HUD or menu element (cursor, button face, stat-bar end-cap). Shape, not character. | `sprite gen --template ui-icon` -> `sprite bake` | `.inc` | `sprites/ui/` |
| **UI nine-slice** | Panel chrome of 9 cells (corners + edges + center) for arbitrary-sized panels. | `sprite gen --template ui-nine-slice` -> `sprite ui-bake` | `.inc` (9 tiles + slicing metadata) | `sprites/ui/` |
| **Portrait** | Head-and-shoulders for cutscene/dialog frames; ships via BG layer. | `sprite gen --template portrait` -> `sprite bake --linear` | `.inc` | `sprites/portraits/` |
| **Font glyph bank** | Codepoint-indexed glyph `.inc` from an existing pixel-font sheet (AI font gen is a non-goal). | `sprite font-bake <sheet>` | `.inc` + codepoint-range metadata | `sprites/ui/font.inc` |
| **BG tilemap** | Full image (hub background, title screen) as a deduplicated tile set + tilemap for text-BG modes. Flip-aware dedup encodes mirrors into map-entry flip bits; `--palettes N` clusters tiles into up to 16 independent palette banks via the map-entry palette bits. | `sprite bg-bake <image>` | `.inc` (tiles + `_MAP` + palette bank(s)) + round-trip preview PNG | `sprites/bg/` |
| **Manifest** | Per-asset JSON metadata (scale, faction, archetype, source refs, frame count, ledger fields). | `sprite manifest set` | JSON | `manifests/<asset>.json` |
| **Canonical registry entry** | Cross-reference index: given faction + archetype + scale, find the canonical and its variants. | `sprite canonical set` / `sprite canonical variant` | `manifests/canonical.json` | `manifests/` |

---

## Folder structure

`assets/` in this repo is the substrate: the CLI, the library, and this
doctrine. It works standalone for smoke tests under its own cwd, or you
point the CLI's cwd at any external consumer project's asset root and
reuse the same substrate.

### Substrate (this repo)

```
<pascal-gba>/assets/
├── PIPELINE.md          # this file
├── requirements.txt     # pip deps
├── sprite.py            # the CLI
└── sprite_lib/          # the library
```

`sprite emulate` structurally depends on `<pascal-gba>/test/sprite_smoke.pas`
and `<pascal-gba>/bin/` for the host-FPC smoke render, so the substrate
stays pinned next to that tree.

### Consumer data (cwd-relative)

Defaults for ledger, manifests, and cache resolve against **cwd**, not
the script path. From a consumer asset root:

```bash
cd /path/to/my-game/assets
python /path/to/pascal-gba/assets/sprite.py gen "red soldier" \
    --template sprite --out _gen/canonical/red_soldier_map.jpg --json
```

Parameterized tree (faction x archetype x scale x action):

```
<project>/assets/
├── _gen/                              # raw model generations (source of truth)
│   ├── canonical/
│   │   ├── <faction>_<archetype>_<scale>.jpg
│   │   └── ...
│   └── animations/
│       ├── <faction>_<archetype>_<scale>_<action>.mp4
│       ├── <faction>_<archetype>_<scale>_<action>_frames/
│       │   ├── f_001.png ... f_NNN.png
│       └── ...
├── sprites/                           # baked game-ready .inc artifacts
│   ├── units/
│   │   ├── <faction>/
│   │   │   └── <archetype>/
│   │   │       └── <scale>/
│   │   │           ├── idle.inc
│   │   │           ├── walk.inc
│   │   │           ├── attack.inc       (battle scale typically)
│   │   │           ├── hit.inc
│   │   │           └── death.inc
│   │   └── ...
│   ├── terrain/
│   ├── ui/
│   └── portraits/
├── manifests/                         # per-asset JSON + canonical.json
├── _archive/                          # pre-doctrine scratch; tools never read it
│   └── <YYYY-MM-DD>-<reason>/
├── ledger.jsonl                       # append-only cost ledger
└── .cache/                            # prompt-artifact cache (regenerable)
```

Override any default per invocation:

```bash
python sprite.py gen ... --ledger /tmp/run.jsonl --cache-dir /tmp/c \
    --manifest-dir /tmp/m
```

Mixed-project sessions should pass these explicitly rather than relying
on cwd.

**Token vocabulary** (each consumer fills these in):

- `<faction>` -- kebab-case faction slug. Examples: `red`, `blue`, `neutral`.
- `<archetype>` -- kebab-case unit-archetype slug. Examples: `soldier`, `scout`, `tank`.
- `<scale>` -- fixed values: `map` (16x16 unit), `battle` (32x64 unit),
  `portrait` (64x64+ cutscene), `icon` (8x8 HUD). Other scales as needed.
- `<action>` -- fixed action verb: `idle`, `walk`, `attack`, `hit`, `death`. Extensible.
- `<terrain_type>` -- kebab-case terrain slug. Example: `grass_terrain`.

---

## Naming convention

Every artifact has a deterministic name derived from its slot. No bespoke
names. No abbreviations except universally recognized ones.

### Files

```
_gen/canonical/<faction>_<archetype>_<scale>.<ext>
_gen/animations/<faction>_<archetype>_<scale>_<action>.mp4
sprites/units/<faction>/<archetype>/<scale>/<action>.inc
sprites/terrain/<terrain_type>.inc
manifests/<faction>_<archetype>_<scale>_<action>.json
```

### Inside the .inc

Pascal asset name is uppercase-snake of the filename components,
terminating with the action:

```
<FACTION>_<ARCHETYPE>_<SCALE>_<ACTION>
```

Examples:

- `RED_SOLDIER_MAP_IDLE` (file: `sprites/units/red/soldier/map/idle.inc`)
- `BLUE_SCOUT_BATTLE_ATTACK` (file: `sprites/units/blue/scout/battle/attack.inc`)
- `NEUTRAL_TANK_MAP_WALK` (file: `sprites/units/neutral/tank/map/walk.inc`)

`sprite emulate` and FPC's `{$I}` directive both work on this convention
without modification.

---

## Cross-cutting design principles

These apply to every asset kind: units, terrain, UI, portrait, font.

### Design at the target scale, not the source scale

The model renders at source resolution (typically 1k = 1024x1024 or
2k = 2048x2048). The bake nearest-neighbor downscales to the GBA target
tile (8x8, 16x16, 32x32, 32x64, 64x64+). **Feature size, stroke width,
and detail must be specified in TARGET-tile pixels, not SOURCE pixels.**

| Kind | Target | Source | Source-px per target-px | Useful feature size |
|---|---|---|---|---|
| sprite (map unit) | 16x16 | 1024 | 64:1 | >=2-target-px = >=128 source-px detail; faces too small to resolve |
| sprite (battle) | 32x64 | 1024 | 32:1 (W) / 16:1 (H) | eyes 1-2 target-px = 32-64 source-px dots |
| texture (terrain) | 16x16 | 1024 | 64:1 | 1-2-target-px features = 64-128 source-px chunky shapes; thin source lines vanish |
| ui-icon | 16x16 | 1024 | 64:1 | 2-target-px strokes = 128 source-px chunky strokes |
| portrait | 64x64 | 1024 | 16:1 | 2-3-target-px eyes = 32-48 source-px facial features |
| font | 8x8 | (ingested, not generated) | -- | AI font gen is NOT a workflow here; use existing pixel fonts via `sprite font-bake` |

Templates encode this rule:

- `sprite_prompt(target_tile=...)` injects a chunkiness clause keyed on target size.
- `texture_prompt(target_tile=...)` auto-derives a "features each X-Y source pixels (= 1-2 target tile pixels)" clause from the source-to-target ratio. A prior default of "small uniform features" produced featureless 16x16 bakes; the auto-derived clause fixes that.
- `ui_icon_prompt(target_tile=...)` and `portrait_prompt(target_tile=...)` carry equivalent clauses.

Operator override: `--scale-hint "<your phrasing>"` on `gen --template texture`
wins over the auto-derived hint when the kind needs unusual feature topology
(e.g. "tight horizontal 1-px flow lines"). Texture is the only template that
accepts `--scale-hint`; for the others, encode the constraint in `--features`
and `--silhouette`.

### Per-faction key color

The bake removes background by matching a designated key color
(transparent slot). When a faction palette includes a color near the
global key, the bake leaks holes through the subject. Choose a key color
per palette family, maximally distant from every accent. The bake's
chroma test is key-aware (`util.chroma_test_for(K)` factory) and
generalizes to magenta / green / cyan / yellow / red / blue without
manual config.

### Background auto-detection

`sprite bake|anim|rekey|ui-bake|font-bake --bg-detect <auto|corner|modal>`
picks how the bg color is sniffed when `--bg` is not pinned:

- `auto` (default) -- corner-mode if the four corner patches agree
  (within tol on every channel), else fall back to image-modal. Handles
  the standard case and the "subject fills the frame" case.
- `corner` -- modal across the four corner patches. Robust when the
  subject fills the frame; matches the pixel-art convention that key
  owns the corners.
- `modal` -- whole-image modal (legacy default).

### Multi-palette BG bakes (region bleed)

One 15-color palette across a full-screen image forces distinct regions
(a night sky, a gold banner, a wooden stall) to compete for the same
slots; the quantizer merges their colors and regions bleed into each
other. Text-BG hardware selects one of 16 palette banks PER TILE through
map-entry bits 12-15, so the fix is native: `bg-bake --palettes N`
(2..16) clusters tiles into banks by color-set affinity and quantizes
each bank independently -- up to N x 15 opaque colors per image.

Mechanics worth knowing:

- Bank assignment tries exact greedy set-cover first (largest tile
  color-sets, each absorbed by the bank that adds fewest new colors).
  Clean tile-structured sources pack exactly: `tiles_degraded: 0` in
  the JSON record means pixel-exact by construction.
- Organic sources (AI art, downsampled paintings) have too many
  distinct color-sets to pack exactly. The bake then re-banks by
  color-coherent clustering: tiles group by mean color (a sky bank, a
  grass bank), each group's pooled pixels quantize to one 15-color
  bank, and every quantize is dither-free. Loss lands inside a
  region's own hues; `tiles_degraded` counts inexact tiles and the
  round-trip preview is the judge.
- `--max-tiles N` (1..1024) vector-quantizes the tile set to a budget
  before palette work -- for sources whose texture noise makes nearly
  every 8x8 cell unique. Codebook selection is maximin, so one-off
  detail survives while noise clusters collapse; `tiles_merged` counts
  remapped cells.
- Tile data holds palette indices, the map entry holds the bank, so
  identical index patterns share one tile across different banks (a
  flat fill or a repeating dither pays for itself once).
- The emitted `_PAL` is N contiguous 16-slot banks (slot 0 of each =
  $0000): copy the whole array into BG palette RAM and hardware bank
  offsets line up. `_PAL_BANKS` carries N.
- Single-palette output (`--palettes 1`, the default) is unchanged:
  compact palette, no bank bits.

Use one shared palette for single-region images (a sky, a field); reach
for banks when the round-trip preview shows regions stealing each
other's colors, and add a tile budget when the 1024-tile guard trips.

### Asset hygiene (keep the trees walkable)

Art accumulates fast: every bake emits previews, every replay drops
screenshots, every generation leaves a source. Without a standing
shape, the consumer's art folder becomes an undifferentiated heap.

Consumer-project layout (one folder per artifact class):

```
<consumer>/
├── art/
│   ├── src/       # generation sources: canonical stills, curated
│   │              # video frames, composited intermediates worth keeping
│   ├── bg/        # BG bakes (.inc + preview) -- tilemaps, full-screens
│   └── sprites/   # OBJ/blit sprite bakes (.inc + previews)
└── shots/         # replay screenshots + debug logs (run artifacts,
                   # never mixed in with assets)
```

End-of-wave tidy (same change as the wave's last bake):

- Canonical sources move from the staging dir (`_gen/`) into the
  consumer's `art/src/`; staging intermediates (frame dumps, contact
  sheets, pick records, thumbnails) are deleted -- the prompt cache
  and the kept canonicals make them reproducible.
- Superseded bakes and their previews are deleted, not left beside
  their replacements (version control remembers).
- Replay outputs land in `shots/` only; regression `.case` files point
  there.

The staging dir is scratch: empty between waves is its healthy state.

### Retry doctrine for transient API errors

The xAI Imagine endpoints intermittently return 500/502/503/504
(typically 1-2x per session during heavy generation). Every API-bearing
subcommand (`gen`, `edit`, `video`) defaults to 3 retries with
exponential backoff (2s, 4s, 8s, capped at 30s). Override via
`--retry N` (0 disables), `--retry-base-delay`, `--retry-max-delay`.
Retry attempts log to stderr in non-JSON mode.

Under the OAuth path, a 401 auth-refresh is a separate one-shot retry
NOT charged against the retry budget. Under `--api-key` / `XAI_API_KEY`,
a 401 is terminal (bad key or missing ACL grant). Non-retryable 4xx
(bad params, exceeded quota) raise immediately.

---

## The canonical workflow

Recipe to produce ONE unit from zero to game-ready. Each step is one
command. Re-runnable; the prompt cache makes idempotent calls free.

### Step 1 -- Design

Before invoking the harness, decide:

- **Faction** and **archetype** slugs (per the consumer design doc).
- **Scale** -- `map`, `battle`, or both. Start with `map` for tactical-layer playtest.
- **Palette** -- enumerated hex codes. 3-4 colors for `map`, 4-6 for `battle`.
  Forbidden: anything close to the magenta background key (`#FF00FF`).
- **Silhouette identifier** -- one or two visible features that make this
  archetype recognizable at the target scale (horns, antennae, sword length,
  body shape, accent-dot location).
- **Iconic features list** -- exhaustive enumeration of what the sprite
  shows. "And no others" is implicit.

### Step 2 -- Generate canonical for the FIRST faction

```bash
py sprite.py gen "<descriptive-name>" \
    --template sprite \
    --target-tile <16x16|32x32|32x64> \
    --direction "facing forward|facing right|3/4 view" \
    --features "<exhaustive enumeration>" \
    --palette "<hex-coded enumeration>" \
    --silhouette "<what the shape looks like at target scale>" \
    --resolution 1k \
    --aspect 1:1 \
    --out _gen/canonical/<faction>_<archetype>_<scale>.jpg \
    --json
```

Example:

```bash
py sprite.py gen "red soldier" \
    --template sprite --target-tile 16x16 \
    --features "oversized round helmet, block torso, no weapon, one chest emblem" \
    --palette "brick-red armor #b04030, dark outline #1a1010, cream emblem #f0e0c0" \
    --silhouette "chunky chess-piece soldier, head half the figure height" \
    --out _gen/canonical/red_soldier_map.jpg --json
```

The FIRST faction is the one whose colors anchor the design. Visual-check
before proceeding. Iterate the prompt until the canonical matches the
design spec.

### Step 3 -- Generate 2-frame idle bob

`idle.inc` is a **2-frame animation** at the target scale: the canonical
and a 1-pixel-shifted-down variant, played at ~450ms per frame. This is
the tactical-map idle idiom -- gentle vertical breathing on stationary
units, not a static pose.

**3. Bake the 2-frame idle bob** (offline; one CLI):

```bash
py sprite.py anim _gen/canonical/<faction>_<archetype>_<scale>.jpg --bob \
    --out sprites/units/<faction>/<archetype>/<scale>/idle.inc \
    --name <FACTION>_<ARCHETYPE>_<SCALE>_IDLE \
    --size <16x16|32x32|32x64> \
    --colors 7 \
    --json
```

`--bob` synthesizes the 1-target-pixel down shift
(`shift_source_px = source_h // target_h`, e.g. 1024//16 = 64) on the
key canvas and bakes a 2-frame shared-palette anim. Defaults with `--bob`:
`--margin 0`, `--gif-ms 450`. Manual two-path form (canonical + pre-shifted
frame without `--bob`) remains valid for custom offsets.

Visual check:

```bash
py sprite.py emulate sprites/units/<faction>/<archetype>/<scale>/idle.inc --json
```

If the bake reveals a problem (lost feature, key-bleed, wrong palette),
iterate Step 2 with a tighter prompt. Cache busts only when inputs or
params change (identical prompt + params + ref hashes hit the cache).

Smoke pin: `python tests/pipeline_smoke.py --only anim.bob`.

### Step 4 -- Generate walk animation

Use the canonical as `r2v` reference (NOT image-to-video; r2v lets the
model produce dramatic stride while preserving identity).

```bash
py sprite.py video "<archetype>" \
    --template walk-video \
    --mode r2v \
    --ref _gen/canonical/<faction>_<archetype>_<scale>.jpg \
    --ref-description "<terse description of the canonical's visible features>" \
    --palette "<same hex codes as canonical>" \
    --duration 6 \
    --aspect 1:1 \
    --resolution 720p \
    --out _gen/animations/<faction>_<archetype>_<scale>_walk.mp4 \
    --json
```

### Step 5 -- Extract, pick, bake walk animation

```bash
py sprite.py extract _gen/animations/<faction>_<archetype>_<scale>_walk.mp4 \
    --out-dir _gen/animations/<faction>_<archetype>_<scale>_walk_frames \
    --json

py sprite.py pick "_gen/animations/<faction>_<archetype>_<scale>_walk_frames/f_*.png" \
    --k 6 --json
# Note the picked frame paths from JSON output

py sprite.py anim <picked-frame-paths> \
    --out sprites/units/<faction>/<archetype>/<scale>/walk.inc \
    --name <FACTION>_<ARCHETYPE>_<SCALE>_WALK \
    --size <16x16|32x32|32x64> \
    --margin 0 --colors 15 --gif-ms 140 --json

py sprite.py emulate sprites/units/<faction>/<archetype>/<scale>/walk.inc --json
```

Frame count: `--k 4` for map scale (subtle motion); **walk cycles target
`--k 8`** (floor 6) with `anim --resample box --strict-motion`. Battle/attack
one-shots stay 4-6 + `--no-loop`.

### Step 6 -- Derive faction variants

For every OTHER faction, single-ref edit against the first faction's
canonical:

```bash
py sprite.py edit _gen/canonical/<source-faction>_<archetype>_<scale>.jpg \
    --prompt "<terse identity preservation> BUT this is the <variant-faction> faction: <palette swap instructions>" \
    --out _gen/canonical/<variant-faction>_<archetype>_<scale>.jpg \
    --json

# Synthesize the variant's shifted idle frame (same source-shift as Step 3a).

py sprite.py anim _gen/canonical/<variant-faction>_<archetype>_<scale>.jpg \
    _gen/animations/<variant-faction>_<archetype>_<scale>_idle_bob_f1.jpg \
    --out sprites/units/<variant-faction>/<archetype>/<scale>/idle.inc \
    --name <VARIANT-FACTION>_<ARCHETYPE>_<SCALE>_IDLE \
    --size <16x16|32x32|32x64> --margin 0 --colors 7 --gif-ms 450 --json
```

Example edit prompt:

```
Same character from the reference image, identical silhouette, identical
helmet and chest emblem. BUT this is the blue faction: replace brick-red
#b04030 with steel-blue #5a78a8, keep dark outline #1a1010, replace cream
emblem with white #ffffff. Solid magenta #FF00FF background only behind
the subject. Discrete blocky pixels, hard 1-pixel outline, no anti-aliasing.
```

For variant walk animations:

- **Recommended**: separate r2v walk from the variant canonical (Steps 4-5
  against the variant). Same motion, faction-correct colors throughout.
- **Cheap**: bake the source-faction walk frames through a palette swap
  (`sprite recolor`). Saves one video call; viable only if the source
  frames' palette maps cleanly to the variant's.

### Step 7 -- Register in manifest + canonical index

```bash
py sprite.py manifest set <faction>_<archetype>_<scale>_idle \
    --kind sprite \
    --faction <faction> --unit <archetype> --scale <scale> \
    --source _gen/canonical/<faction>_<archetype>_<scale>.jpg \
    --output sprites/units/<faction>/<archetype>/<scale>/idle.inc \
    --size <WxH> --frames 1 --json

py sprite.py canonical set <faction>_<archetype>_<scale>_idle --json   # first faction
py sprite.py canonical variant <faction>_<archetype>_<scale>_idle --json   # variants
```

Subsequent `sprite canonical get --unit <archetype> --scale <scale>`
returns the canonical and its variants -- useful when deriving new
variants from an established reference.

### Step 8 -- Repeat per action and per faction

`walk` (and any other action: `attack`, `hit`, `death`, etc.) repeats
the Step 4-7 cycle. For battle-scale units, write a per-action prompt
template if the action mechanics need them (see
[Prompt formulas](#prompt-formulas)).

---

## Completion checklist per scale

A unit is "complete" at a given scale when this minimum set exists.
Anything beyond is content / polish.

### Action-class pick defaults

Use `sprite pick` after extract. Walk cycles want loop-detect; one-shots must
pass `--no-loop` or defeat/interact keyframes wrong-trim to a false period.

| Class | Template (when present) | pick | k | gif-ms | notes |
|---|---|---|---|---|---|
| walk | `walk-video` | loop (default) | **8** (floor 6) | 90-120 | bipedal / legged — max quality bar |
| bounce | `bounce-video` | loop | 4-6 | 100-140 | hop locomotion (blob/soft) |
| slither | `slither-video` | loop | 4-6 | 100-140 | undulate / wave body |
| slide | `slide-video` | loop | 4-6 | 100-140 | glide / lean travel |
| idle bob | n/a (`anim --bob`) | n/a | 2 | 450 | programmatic; no pick |
| prop-idle | `prop-idle-video` | loop | 4 | 200-300 | small periodic sway |
| interact | `interact-video` | **`--no-loop`** | 4-6 | 80-120 | one-shot open/spin/bounce |
| hit / stagger | `hit-video` | **`--no-loop`** | 2-4 | 80-100 | short recoil |
| defeat / soft-fail | `defeat-video` | **`--no-loop`** | 3-5 | 100-140 | kid-safe; prefer shared VFX early |
| attack | `attack-video` | **`--no-loop`** or loop if cycle | 4-6 | 100-120 | soft combat optional |

Smoke: `pick.loop`, `pick.no_loop`, `pick.no_loop_vs_loop` in
`tests/pipeline_smoke.py`.

### Video motion templates (closed catalog)

`sprite video --template <name>` choices (exact set; smoke
`video.template_catalog`):

| Template | Motion | pick policy |
|---|---|---|
| `walk-video` | ABCD walk cycle | loop (default) |
| `bounce-video` | squash → launch → apex → fall hop | loop |
| `slither-video` | undulate / wave body | loop |
| `slide-video` | lean + glide drift | loop |
| `attack-video` | windup → contact → recovery | `--no-loop` |
| `hit-video` | short recoil | `--no-loop` |
| `defeat-video` | soft poof / comedy exit (kid-safe) | `--no-loop` |
| `prop-idle-video` | small sway / glow loop | loop |
| `interact-video` | one-shot open/spin/bounce | `--no-loop` |
| `raw` | free prompt | operator choice |

All non-raw templates require `--subject`. Shared clauses: solid magenta key
bg, no pink/magenta on subject, static camera, no walk ABCD on non-walk
templates. Live r2v quality is separate; offline prompt shape is gated by
`video.template_shapes`.

### Direction × motion mode (enemies and movers)

**Facing and motion mode are independent axes.**

| Axis | Values | Cart / bake role |
|---|---|---|
| **Facing** | side (L/R flip), down (front), up (back) | separate stills + sheet (or flip) so travel reads |
| **Motion mode** | walk · bounce · slither · slide · (future hover…) | which video template + pick policy |

A blob can bounce in four facings without legs. A snake can slither. A plush can
walk. Diagonals typically keep the side sheet (same as hero). Pipeline: pick the
template for the **mode**, then r2v once per **facing still** (`--view` /
`--facing` as for walk). Cart wander only needs `dir + cycle frame`; it does not
care whether the cycle is feet or squash.

### Parallax layers (mode-0 scenic)

Three **generated** asset layers, not solid-color fills:

| Layer | BG | Asset | Key / opacity |
|-------|-----|--------|----------------|
| Far sky | BG2 | full sky plate (gradient, clouds) | opaque |
| Mid scenic | BG1 | skyline / ridge plate | edge-key magenta → transparent |
| Near ground | BG0 | grass/dirt stamps in play band only | transparent above play band |

```text
# Mid plate only (edge-key; does NOT fill solid sky into the plate)
py sprite.py mid-plate mid.jpg --out mid_rgba.png --size 512x80 --json

# Cart compose example: adventure gen_parallax_assets.py
#   bank0 sky · bank1 mid · bank2 ground  (map entry palette bits)
```

**Failure modes:**
- Per-pixel key eats white tent stripes → edge-flood key only (`scenic.py`).
- **Solid sky fill baked into mid** → flat dead sky, no atmosphere, no parallax
  depth. Never do this for product. Sky is always its own generated plate.
- Gradient under-sky + mid holes → striped bars through fabric.
- Ground high-contrast random 8×8 → checker artifact; use low-contrast macros.

**Compose doctrine:**
1. Gen sky plate and mid plate as separate Imagine assets.
2. Mid: buildings only, pure magenta sky, key → RGBA (transparent sky).
3. Sky: sample the *full* generated sky plate into horizontal bands across
   the **visible** rows above ground (not 1:1 full-screen — otherwise a tall
   mid only reveals the plate's top mono strip). Soft cloud stamps optional.
4. Mid silhouette occupies the non-play band (peaks→feet). Sky shows *through*
   keyed gaps above/between peaks — prefer that over a pure-sky slab above a
   short rectangular crop (slab + flat cut is the solid-bar failure mode).
5. Ground: play band only; upper rows empty so mid+sky show.
6. Multi-bank palettes (15 colors each) for sky / mid / ground.

**Mid source aspect (load-bearing):** generate mid as a **wide short strip**
(e.g. aspect `20:9` / `2:1`), buildings from bottom edge up, pure `#FF00FF`
sky, **no dirt/grass floor**. Full-frame 16:9 carnival scenes force-fit into a
~48–56px band look mushy and “sliced.” Hard-fit (quantize + NEAREST) only;
never BOX soft downscale into the band.

**Never:** solid-color sky fill into mid; `//8` NEAREST pixelation of the sky
plate (destroys gradient into one purple bar); dirt path baked into mid;
bottom-only crop of booth midsections under a pure sky bar.

### Map scale (16x16) -- minimum

| Action | Required | Frame count | Notes |
|---|---|---|---|
| `idle` | yes | 2 | Canonical + 1-pixel-down programmatic shift via `sprite anim`. See Step 3. |
| `walk` | yes | 4 | r2v walk -> pick -> anim. Distinct prompt from idle |
| `attack` | no | -- | Battle scenes only |
| `hit` | no | -- | Battle scenes only |
| `death` | no | -- | Optional even at battle scale; can be a shared explosion sprite |

### Battle scale (32x64) -- minimum

| Action | Required | Frame count | Notes |
|---|---|---|---|
| `idle` | yes | 2-4 | Programmatic source-shift bob OR short r2v idle clip. 2-frame bob is the cheap default; richer r2v idle is polish |
| `attack` | yes | 4-6 | Per-archetype prompt template needed |
| `hit` | yes | 1-2 | Recoil pose; cheap |
| `death` | optional | 3-4 | Or use a shared generic destroy animation |
| `walk` | no | -- | Battle scenes typically static; movement is map-scale |

### Portrait scale (64x64+) -- minimum

| Action | Required | Notes |
|---|---|---|
| `neutral` | yes | Default expression for dialog frames |
| `talk` | optional | 2-3 frames if lip-sync is wanted |
| `emote_<state>` | optional | One per design-required emotion |

---

## Prompt formulas

Validated prompt patterns. Each formula is the minimum scaffolding that
survives the model's defaults. Trim only identity-lock clauses after the
reference binds reliably; keep motion-mechanics clauses for animation
prompts.

### Sprite gen (16x16 chunky map icon)

Template: `--template sprite --target-tile 16x16`. Required overrides:

- `--features` -- enumerate exhaustively. Key clauses:
  - **OVERSIZED head/helmet** at ~50% figure height (model defaults to
    realistic 1/4 -- produces mush at 16x16).
  - **NO weapon** (or only thick stubby weapons) -- thin blades do not
    survive NN downscale.
  - **NO arms, OR 2-pixel-wide block arms** pressed against the torso.
  - **One bold chest emblem** in a single accent color (>=2x2 block in
    the source design).
- `--palette` -- 3 colors total (faction-armor base + dark outline +
  single accent). Background-key slot is the 4th in the baked palette.
- `--silhouette` -- frame as *"chunky chess piece or tactical-map unit
  icon, not a detailed portrait."*

### Sprite gen (32x64 battle-scale)

Template: `--template sprite --target-tile 32x64`. Required overrides:

- Full feature enumeration including weapon and accessories.
- Palette of 4-6 colors.
- Silhouette can include diagonal-extending elements (sword, cape, banner).
- The model can render finer detail at this design scale; less reductive
  than 16x16.

### Sprite edit (faction recolor)

Template: passed `--prompt` directly. Key clauses:

- *"Same character from the reference image, identical silhouette,
  identical [list of preserved features]."*
- *"BUT this is the <faction> faction: replace <color> with <hex>,
  replace <color> with <hex>, replace <color> with <hex>."*
- *"Solid magenta #FF00FF background only behind the subject."*
- *"Discrete blocky pixels, hard 1-pixel outline, no anti-aliasing,
  no gradients."*

Single-ref is sufficient for palette swaps. Multi-ref (`<IMAGE_0>` +
`<IMAGE_1>`) is for combining shape from one source with style/palette
intensity from another.

### Video r2v (walk animation)

Template: `--template walk-video --mode r2v`. The `walk_video_prompt`
template's motion-mechanics clauses (4-pose ABCD walk, alternating limbs,
head bob, weapon-with-arm sync) are **load-bearing** for dramatic stride.
Do not trim them.

Identity-lock clauses (anatomy enumeration, palette enumeration, feature
checklist) within the template are over-built once the r2v reference binds
reliably. Acceptable to trim those.

For map-scale 16x16 units, the model produces appropriately-subtle motion
regardless of walk-mechanics scaffolding -- the legs are 2-pixel blocks
with little to articulate. A moderate ~480-char prompt is sufficient at
this scale.

### Texture gen (terrain tile)

Template: `--template texture --target-tile <WxH>`. Generates a uniform
stationary texture; `sprite tile` wraps it for seamless 4-way tiling via
half-roll blend. Pass `--target-tile` so the prompt's scale-hint clause
is auto-derived from the source-to-target ratio (see
[Design at the target scale](#design-at-the-target-scale-not-the-source-scale)).

Key clauses (already in the template):

- *"SEAMLESS REPEATING tileable texture of [material]"*
- *"Completely flat and even, NO focal point, NO center, NO large features"*
- *"chunky blocky features sized at X-Y source pixels each (= 1-2 target
  tile pixels at WxH), NOT thin lines or fine detail"* -- auto-derived
- *"distributed evenly across the ENTIRE frame edge to edge"*
- *"like a stock texture swatch, fills the whole frame uniformly with no
  darker edges"*

Operator overrides:

- `--scale-hint "<your phrasing>"` wins over the auto-derived hint. Use
  when the terrain needs unusual feature topology (e.g. "tight horizontal
  1-px flow lines"); the auto-hint would force chunky-blocky shapes that
  miss that language.
- `--target-tile` accepts `8x8, 16x16, 16x32, 32x32, 32x64, 64x64, 96x96,
  128x128`. Texture defaults to 32x32 (GBA BG tile standard).

Post-process through `sprite tile --method offset` for the standard
4-way wrap, or `--method mirror` if offset shows directional banding.

Example:

```bash
py sprite.py gen "grass terrain" --template texture --target-tile 16x16 \
    --out _gen/grass_terrain.jpg --json
py sprite.py tile _gen/grass_terrain.jpg \
    --out sprites/terrain/grass_terrain.inc --name GRASS_TERRAIN --json
```

### UI-icon gen (HUD elements)

Template: `--template ui-icon`. For single icons (cursor, menu arrow,
stat-bar end-cap, button face).

Distinct from `sprite_prompt`: the model is briefed for a SHAPE, not a
character. No anatomy clauses; the chunkiness/scale clauses keyed on
`--target-tile` apply (8x8 / 16x16 / 32x32 most common for HUD icons).

Required overrides:

- `--features` -- enumerate the shape: *"diagonal arrow pointing to
  upper-left, thick body, single bright outline, no shaft tail"*.
- `--palette` -- 3-4 colors max. High contrast for tile-scale readability.
- `--target-tile` -- drives the chunkiness clause.

### UI nine-slice (panel chrome)

Workflow: generate ONE 3x3 source image via the dedicated `ui-nine-slice`
template, then bake via `ui-bake`. The template hard-scaffolds the 3x3
grid structure (TL/T/TR + L/C/R + BL/B/BR with mirror/translation/rotation
symmetries) so the model produces a properly-cellular source on first try.

```bash
py sprite.py gen "dialog frame" \
    --template ui-nine-slice --target-tile 8x8 \
    --palette "navy outline #1a2540, steel-blue face #5a78a8, cyan inner-glow #00e0e0" \
    --out _gen/ui/dialog_frame.jpg --json
py sprite.py ui-bake _gen/ui/dialog_frame.jpg \
    --out sprites/ui/dialog_frame.inc \
    --name DIALOG_FRAME \
    --cell 8x8 --json
```

`--target-tile` on the gen step is the PER-CELL target size (typically
8x8 = GBA UI standard; 16x16 for thicker chrome). The baker slices the
source into a 3x3 grid (each cell = `W // 3` by `H // 3` source pixels),
downscales each to `--cell`, and emits a 9-tile `.inc` with row-major
slicing constants (`<NAME>_NS_TL`...`_NS_BR` = 0..8) plus a hardcoded
NS_index mapping the consumer can reference by position name.

### Portrait gen (cutscene / dialog frames)

Template: `--template portrait --target-tile 64x64`. Head-and-shoulders
composition; ships via BG layer, so bake with `--linear` to skip OBJ
tile-order packing.

Required overrides:

- `--features` -- enumerate the character: *"horned helmet, glowing visor,
  armored shoulder pauldrons, chest plate with a simple geometric emblem"*.
- `--palette` -- 4-6 colors. Portraits tolerate richer palettes than map sprites.
- `--expression` -- `neutral` | `talking` | `angry` | `concerned` | free-form.
  Ship N variants per character with same subject/features/palette and
  varying expression only.
- `--target-tile` -- `64x64`, `96x96`, `128x128` are common cutscene sizes.

### Font ingestion (NOT generation)

**AI font generation is a deliberate non-goal of this pipeline.** Existing
public-domain pixel fonts (Pixel Operator, Press Start 2P, FCEUX 6x8) ship
at higher fidelity than the diffusion model produces, and glyph-count /
ordering reliability is the killer constraint AI gen cannot meet (probed:
asked for 32 glyphs, got 33; row corruption).

Workflow: download a pixel font sheet (typically a PNG with a regular
`cols x rows` grid of glyphs), then:

```bash
py sprite.py font-bake fonts/pixel_operator_8x8.png \
    --out sprites/ui/font.inc \
    --name UIFONT \
    --grid 16x6 \
    --glyph-size 8x8 \
    --start-codepoint 0x20 \
    --json
```

The baker slices the sheet into `cols x rows` glyph cells, downscales each
to `--glyph-size`, and emits a shared-palette `.inc` with codepoint-mapping
constants: `<NAME>_GLYPH_START`, `_GLYPH_END`, `_GLYPH_COUNT`,
`_GLYPH_COLS`, `_GLYPH_ROWS`. Consumer-side lookup:
`tile_index = codepoint - <NAME>_GLYPH_START` for codepoints in
`[GLYPH_START, GLYPH_END]`, else fall back to a missing-glyph placeholder
(e.g. `?` at 0x3F).

---

## Bake settings reference

### `sprite bake` flag tuning

| Flag | Default | When to change |
|---|---|---|
| `--size WxH` | required | Target dimensions. GBA OBJ hardware: 8/16/32/64 per axis |
| `--margin` | 2 | Set 0 at 16x16 (every pixel counts); leave at 2-4 for larger sprites |
| `--colors` | 15 | Lower to 7 for tight palette (16x16 typically uses 3-4); 15 is the GBA 4bpp ceiling |
| `--bg` | auto-detect | Override with `--bg "#FF00FF"` if auto-detection picks the wrong color |
| `--bg-detect` | `auto` | Strategy when `--bg` is not pinned: `auto` (corner if 4 corners agree, else modal); `corner` (4-corner-modal -- robust when subject fills the frame); `modal` (whole-image modal) |
| `--bg-tol` | 30 | Raise to 40-50 for video frames (chroma-key brightness varies frame-to-frame) |
| `--no-chroma` | off | Pass for achromatic-keyed sources (white/black/gray bg) where the brightness-invariant chroma test does not apply. Magenta / green / cyan / yellow / red / blue keys all auto-discriminate via `chroma_test_for(K)` |
| `--linear` | off | Pass when emitting for BG tile use (not OBJ); rare for sprites |
| `--no-autocrop` | off | Pass if the canonical already has the desired margins baked in |
| `--retry` | 3 | API retry count for transient 5xx / transport errors. Exponential backoff (2s, 4s, 8s, ..., capped at 30s). 0 disables. Only meaningful on `gen`/`edit`/`video`. |

### `sprite anim` flag differences from bake

| Flag | Default | Notes |
|---|---|---|
| `--gif-ms` | 110 | Per-frame duration in the preview GIF. Walk cycle: 110-140. Idle bob: 180-240 (or 450 for a slower tactical bob) |
| `--bg-tol` | 40 | Higher default than `bake` because video bg vignettes more than stills |
| `--colors` | 15 | Animation frames share one palette; need broader headroom |
| `--margin` | 2 | Use 0 for 16x16 anim; 2-4 for battle scale |

---

## Offline vs online stage reference

This is a hard contract, not a soft preference. Only three subcommands
ever construct an xAI client. Every other subcommand never touches
credentials or the network.

| Needs a credential | Never touches auth |
|---|---|
| `gen` (text -> image) | `bake`, `anim`, `ui-bake`, `font-bake` (raster -> `.inc`) |
| `edit` (ref -> image) | `tile` (terrain seamless-wrap) |
| `video` (text/image/ref -> mp4) | `extract` (mp4 -> frames; needs `ffmpeg` only) |
| | `pick` (loop-detect keyframe selection) |
| | `montage`, `gif`, `tile3x3`, `inspect`, `palette`, `diff`, `preview` (review) |
| | `recolor`, `rekey`, `sheet` (local edit ops) |
| | `iso-geom-preview`, `iso-road-bank`, `iso-brick`, `iso-stitch` (isometric tilesets) |
| | `emulate` (host FPC only, not xAI) |
| | `cost`, `cache`, `manifest`, `canonical` (bookkeeping) |

There is no partial-offline mode for `gen`/`edit`/`video` (no local
model). Offline or cache-hit: a pre-seeded prompt-artifact cache entry
satisfies those stages without a live call when prompt + params + ref
hashes match. Without cache and without credentials, they fail fast with
the [Authentication](#authentication) error, never a network timeout.

---

## Failure modes and recovery

### "No xAI credentials found"

Cause: none of `--api-key`, `XAI_API_KEY`, or a usable OAuth file resolved.

Recovery: set `XAI_API_KEY` (create a key at
https://console.x.ai/team/default/api-keys and grant endpoint/model
access), or run `grok login` if you have the grok CLI and want the OAuth
path. See [Authentication](#authentication). Offline stages do not need
this; only `gen`/`edit`/`video` do.

### "Key present but request rejected -- check endpoint/model ACL grants"

Cause: a standing API key (flag or env) was sent as Bearer, but the
`/v1/images/*` or `/v1/videos/*` call returned non-2xx. Keys are
default-deny until endpoint and model ACLs are granted in the console.

Recovery: open console.x.ai, open the key, grant access to the image and
video endpoints and the models you use (`grok-imagine-image-quality` /
`grok-imagine-image` for stills; the video model for `video`). Re-run.
If the key itself is wrong or revoked, create a new key and update
`XAI_API_KEY`.

### "Sprite mush at 16x16 -- features unreadable"

Cause: model designed at native (realistic) proportions; NN downscale to
16x16 throws away the detail.

Recovery: re-prompt with OVERSIZED head ~50% figure height and
remove/simplify small features (face, fingers, thin weapons). The 16x16
design must already look chunky at 1024x1024 -- every "pixel" in the
source should be a >=32-pixel block.

### "Subject magenta-tinted -- bg key removes part of the figure"

Cause: prompt asked for a magenta background without forbidding magenta
on the subject; the model bleeds the key color into the figure.

Recovery: add: *"Solid uniform magenta #FF00FF background only behind
the subject. Do NOT use pink or magenta anywhere on the subject."* Re-gen.

### "Warm pink / candy subject vanishes under bake (ghost silhouette)"

Cause: warm pink is **itself** magenta-chroma under the brightness-invariant
test (`R-G>50` and `B-G>30`). Default chroma-ON bake with key `#FF00FF`
classifies the subject as background and punches it out. This is not a
`--bg-tol` tuning problem.

**Gate (elevated):**

```text
py sprite.py key-check source.png --key #FF00FF --json
# ok:false + key_chroma_fg_px / hole_frac when subject is at risk

py sprite.py bake source.png --out x.inc --name X --bg #FF00FF
# key_hole_warn:true + stderr warn when distance-FG is mostly key-chroma
# --strict-key fails the bake instead of warning
```

Recovery (pick one):

1. **Rekey green/cyan:** put subject on solid `#00FF00` (or cyan) and bake
   with `--bg #00FF00` (chroma may stay ON).
2. **Exact solid key, no vignette:** `bake --no-chroma` preserves pink
   when the key is a hard color match only.
3. Prefer gen palettes far from the key; never ship warm-pink props on
   default magenta chroma without `key-check` PASS.

CLI: `sprite key-check <image> [--key #FF00FF] [--palette "pink:#FF50A0"]
[--hole-frac 0.25] [--json]`. Exit 1 when `ok:false`.

### "Baked sprite is a hollow ring / transparent body center"

Cause: keying or downscale left only an outline (or eyes/hat) as opaque
index-nonzero pixels; the bbox **center** is palette index 0 (OBJ
transparent). Lived failure mode on soft-enemy character bakes.

**Gate (elevated):**

```text
# bake FAILS by default when hollow-center is detected
py sprite.py bake source.png --out x.inc --name X --size 16x16 --bg #00FF00

# intentional rings (UI frames) must opt in:
py sprite.py bake ring.png --out r.inc --name R --allow-hollow

# post-hoc on any .inc:
py sprite.py fill-check x.inc --json
# ok:false + hollow_center:true when center of opaque bbox is mostly transparent
```

Metrics on bake JSON: `fill_ok`, `fill_hollow_center`,
`fill_center_trans_frac`, `fill_overall_trans_frac`, `fill_sparse_warn`.

Recovery: re-gen with solid filled body language; green-key or `--no-chroma`
on solid keys; bake at 32x32 if 16x16 collapses the fill; do **not** ship
with `--allow-hollow` for character/enemy bodies.

### "Walk eyes fuse into one white blob / cycle looks wooden"

Cause: video frames + nearest downscale + thin keyframe pick. On-device
32x32 faces turn two eyes into one clump; sparse picks freeze the gait.

**Gate (elevated):**

```text
py sprite.py anim f1.png ... f8.png --size 32x32 --resample box --strict-motion
# fails if upper-bbox bright clump is oversized / single-mass / asymmetric
# --strict-motion fails near-identical consecutive frames (wooden)
# --no-strict-face disables eye mush fail (not for hero walks)
```

Walk doctrine: pick **k=8**, mid-cycle only, FACE LOCK in walk-video when
anatomy is not forbidden, box resample default on `anim`,
`--cycle-start min-stance` so frame 0 is narrow foot span (not frog-leg).

### Vision judgment layer + rolling observations

Mechanical gates miss some pose/face artifacts. After strip/preview exists:

```text
py sprite.py judge path/to/hero_walk.inc.strip.png --rubric walk-strip \
  --observe path/to/asset.observe.md --json
# exit 1 on FAIL; issues[] names frog-leg start, wrong feet, fused eyes, glitches
# --observe appends the verdict and injects prior journal into the next call
```

Rubrics: `walk-strip` | `sprite-still` | `generic`. Model: `SPRITE_JUDGE_MODEL`
or `grok-4` (chat + image). Same auth as gen. Use before cart entry for
character walks — agent review should also load the strip PNG with the image
reader when a vision model is available mid-session.

**Closed quality loop (character assets):** settle primitives here before volume.

```text
1. gen base still          -> judge --rubric sprite-still --observe ASSET.observe.md
2. if FAIL: re-gen / edit  -> re-judge (journal carries adjustments)
3. video r2v from still    -> extract -> pick k=8 -> anim (box, min-stance, strict)
4. judge strip             -> walk-strip + --observe (FEET/FACE/start-frame)
5. if FAIL: re-vid with    -> adjustment text from judge.adjustment / observe
6. bake to cart .inc       -> fill-check / key-check already on bake path
7. optional: re-judge strip; re-vid only if residual modes remain
```

The observe file is an append-only markdown journal (see `sprite_lib/observe.py`).
Agents may also pass it as a prompt file to a headless CLI session so successive
judges share failure modes without re-pasting chat. Known modes map to
pipeline adjustments (frog-leg -> `--cycle-start min-stance`; outward toes ->
FEET LOCK re-vid; pale/fused eyes -> FACE LOCK + idle from still not walk cell0).

**Idle vs walk eyes:** idle must draw the **canonical still bake**, not walk
frame 0. Walk cells only while moving. Still and walk may use separate OBJ
palettes; do not force one shared palette if it washes pupils.

**Humanoid walks:** pass `--forbid-anatomy ""` so FACE LOCK + FEET LOCK apply
(default forbid_anatomy strips faces for non-human units).

**Side-walk primitive (feet):** when the product needs a side-view walk, do not
r2v from a front-facing still alone — the model often preserves front bias and
duck-splay toes. First `edit` (or gen) a **side-profile still** with both shoes
pointing along facing, then r2v with that still as `--ref`. Idle in-cart should
still use the front canonical still bake (stable dual-eye face), not walk cell 0.

**4-direction walks (free-scroll characters):**

| Cart input | Sheet | Ref still | video flags |
|---|---|---|---|
| pure Left / Right | side walk | side-profile still | `--view "side view" --facing right` |
| pure Down | front/down walk | front canonical | `--view "front view facing the camera" --facing forward` |
| pure Up | back/up walk | back-view still (`edit` from front) | `--view "back view from behind" --facing away` |
| any diagonal (L/R + U/D) | **side walk** | (same side sheet) | — |

Always pass `--forbid-anatomy ""` for humanoid kids. `--facing` is free text
(`left|right|forward|away`). Separate OBJ palettes per sheet are fine; do not
force a shared palette if it washes eyes.

**Front/back gait (anti-duck-waddle):** r2v from a **narrow-stance walk-ready
still** (feet close under hips), not a wide standing pose. Walk-video template
uses subtle Zelda-like track language for `--facing forward|away` (vertical
foot lift, no lateral splay, keep white shoe shapes — no sole-up flaps). If
the bake still waddles, re-edit the still tighter and re-vid; do not paper
over with cart hacks.

### "Reference image apparently ignored / poor adherence in video"

Cause: wrong field shape sent to API. Documented shapes:

- `/v1/images/edits`: `image: {url, type}` (single) or
  `images: [{url, type}, ...]` (multi)
- `/v1/videos/generations`: `image: {url}` (i2v, locks first frame) or
  `reference_images: [{url}, ...]` (r2v, guides style/content)

Recovery: verify the client is on shape-v2 (`SHAPE_VERSION = 2` in
`sprite_lib/xai.py`). Verify `--mode` is `r2v` for character animation
(not `t2v` or `i2v`).

### "Walk animation looks like backwards motion when previewed"

Cause: sampled frames span multiple cycles at a sub-cycle aliasing
interval (wagon-wheel effect).

Recovery: use `sprite pick` (loop-detect + arc-length keyframes) for
animation source; NEVER even-time sampling across the full clip.

### "Video bg vignettes; chroma key partially fails"

Cause: video gen produces darker bg at edges than at center; color-distance
keying either misses the vignette or eats the subject.

Recovery: the brightness-invariant chroma test (`is_magenta_chroma`,
R-G>50 AND B-G>30) handles magenta vignette. Use `--bg-tol 40` minimum
for video frames.

### "Multi-image edit: model ignores one of the refs"

Cause: prompt does not address the refs by index.

Recovery: rewrite prompt to invoke each ref: *"the subject from
`<IMAGE_0>` wearing the color palette of `<IMAGE_1>`."* The `<IMAGE_N>`
tokens are the documented addressing convention.

### "OAuth token expired / 401 from API"

Cause: bearer JWT expired on the OAuth path; the client auto-refreshes
once when `source == oauth`. Under a standing key, 401 is terminal.

Recovery (OAuth): `grok login` to re-issue. If refresh is stuck, delete
`~/.grok/auth.json` and re-login. Recovery (standing key): see the ACL
grant entry above.

### "Same prompt twice = different output (in `gen`)"

Expected. Diffusion models are stochastic at inference. The prompt cache
makes the SAME prompt + params + ref hashes a cache-hit (0 cost, same
file). Different prompt = different output by design.

---

## Pipeline economics

Two entitlement paths (see [Authentication](#authentication)):

- Standing `XAI_API_KEY`: pay-per-use at console.x.ai rates.
- OAuth ride: existing subscription allowance when available.

Approximate costs (same order of magnitude either path; ledger records
`cost_in_usd_ticks` when the API returns them):

| Operation | Approx ticks | Approx USD |
|---|---|---|
| `gen` (1k, quality model) | 500M | $0.05 |
| `edit` 1 ref (1k, quality) | 600M | $0.06 |
| `edit` multi-ref (1k, quality) | 700M-900M | $0.07-$0.09 |
| `video` 6s 720p r2v | 3000M | $0.30 |
| `extract`, `pick`, `bake`, `anim`, `tile`, `emulate`, `review`, `montage`, `gif`, `tile3x3`, `inspect`, `palette`, `diff`, `preview`, `recolor`, `rekey`, `sheet`, `manifest`, `canonical`, `cache`, `cost` | 0 | $0 |

Cost discipline: cache hits cost zero. Re-running with identical inputs
is free. Recolors and palette-swap edits are a fraction of a fresh gen.
Animation has a fixed video cost regardless of frame count -- bake/pick
is cheap iteration.

The ledger default is **cwd**/`ledger.jsonl` (override with `--ledger` or
`SPRITE_LEDGER`). `sprite cost --json` summarizes spend. Tick scale in
code is 1e-9 USD per tick (`USD_PER_TICK` in `sprite_lib/cost.py`).

---

## Isometric tilesets

Dimetric (2:1) ground diamonds and stacked brick cubes for isometric
maps. These commands are **offline geometry compositors**: they emit
directional tile *pieces* that a game stitches by neighbor mask. Do not
hand-paint junction hubs into a single diamond and call it a road bank.

### Geometry contract

| Rule | Value |
|---|---|
| Projection | Dimetric 2:1 (pixel-art standard; ~26.6 deg), not true 30 deg iso |
| Ground diamond | Width W, height H = W/2; both even. Default **32x16** |
| Map half-step | (W/2, H/2) = (16, 8) at default size |
| Diamond fill | `\|dx\|/(W/2) + \|dy\|/(H/2) <= 1` inside the W x H AABB |
| Transparent corners | AABB corners outside the diamond stay key color (magenta #FF00FF) |
| Compact option | 16x8 when VRAM forces it (less readable roads) |
| Brick cube | Precomposed top + left + right faces on a W x W AABB (default 16x16) |
| Vertical step | One stack level shifts screen Y by H/2 (= W/2 for cube width W) |

Modules: `sprite_lib/iso_geom.py` (math + masks), `sprite_lib/iso_compose.py`
(road bank, brick, ghost, shadow, stitch previews).

### Road inventory (Wang 2-edge)

Sixteen pieces indexed by a 4-bit neighbor mask:

| Bit | Neighbor | Value |
|---|---|---|
| N | north (+map Y tip in screen NE-SW terms — see compose docs) | 1 |
| E | east | 2 |
| S | south | 4 |
| W | west | 8 |

Files: `grass.png` + `road_00.png` .. `road_15.png`. Each road tile is a
full diamond: asphalt lanes follow connectivity; grass remains only off-lane
pixels inside the diamond. Consumer code computes mask from 4-neighbors and
selects `road_XX` — it does not paint junctions at runtime.

### Brick + height (Z) affordances

| Asset | Role |
|---|---|
| Solid cube | Placeable block (top/left/right shaded) |
| Ghost cube | Outline-only, same geometry — cursor aim at a height level |
| Ground shadow | Dark disc on the ground diamond under the stack |

Solid and ghost **must** share `iso_cube_faces(w)` so the ghost sits exactly
where a brick would land.

### Commands (all offline)

```bash
# Geometry plate: diamond + solid cube + ghost
python sprite.py iso-geom-preview --size 32x16 --out _gen/iso_geom.png --scale 4

# Full road bank + stitch contact sheets (straight, corner, tee, cross, atlas)
python sprite.py iso-road-bank --size 32x16 --out-dir _gen/iso_roads --scale 3
# Optional textures:
#   --grass path/to/grass.jpg --road path/to/asphalt.jpg

# Brick solid + ghost + shadow
python sprite.py iso-brick --size 16 --out _gen/iso_brick.png

# Re-stitch a bank into one named proof sheet
python sprite.py iso-stitch --bank _gen/iso_roads --pattern cross \
    --size 32x16 --out _gen/stitch_cross.png --scale 3
```

Stitch patterns: `straight_ns`, `straight_ew`, `corner`, `tee`, `cross`,
`atlas` (all 16 masks in a grid).

### Generation doctrine

1. **Geometry first.** Lanes, cube faces, and masks are procedural.
2. **Textures optional.** `gen --template texture` can supply grass/asphalt
   or brick material; pass them into `iso-road-bank --grass/--road` or
   `iso-brick --material`. Never generate all 16 masks as independent AI
   images (seams and identity drift).
3. **Gate on stitch previews.** Before a cart consumes a bank, inspect
   `stitch_straight_*`, `stitch_corner`, `stitch_cross`. If junctions look
   wrong, fix `iso_compose` — do not thrash the cart's neighbor algebra alone.
4. **Bake path.** Road diamonds are BG candidates (`bg-bake` or per-tile
   `bake --linear` depending on consumer layout). Brick cubes are OBJ-sized
   (16x16 / 32x32) via `bake`. Ghost may be a separate OBJ with a bright
   outline palette.

### Acceptance checklist

- [ ] Ground size is 2:1 (default 32x16); half-step documented for the cart
- [ ] Bank has exactly grass + 16 road masks; NS spine != EW spine by eye
- [ ] Stitch sheets show continuous corridors (no hub blob in every cell)
- [ ] Brick solid and ghost align; shadow reads under the stack footprint
- [ ] Offline smoke: `python tests/pipeline_smoke.py --only iso.`

### Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Roads look like freckles / blobs | Cart painted mask algebra onto one tile shape | Use `iso-road-bank` pieces; index by mask |
| Junctions break at edges | Non-2:1 diamond or wrong half-step | Enforce IsoSize 2:1; half-step = (W/2,H/2) |
| Z aim invisible | No ghost/shadow assets | `iso-brick` emits both; cart draws ghost at aim Z |
| AI tiles don't match neighbors | Full AI per mask | Geometry compose + optional single texture |

---

## Extension contracts

The harness is structured so two axes can grow without rewriting the
core (xAI client, cache, ledger, manifest, registry).

### Target axis (which game system)

Today: GBA only (BGR555 palette, 4bpp tile, OBJ tile order, sprite_smoke
validator).

Future plugin contract (when needed):

- `bgr555` / pixel-format conversion -> target-supplied
- Tile-order pack -> target-supplied
- File extension and asset layout -> target-supplied (e.g. `.chr` for NES,
  hex strings for PICO-8)
- Validator (emulator/renderer) -> target-supplied

### Asset kind axis (sprite vs tile vs font vs ui vs ...)

Today the bake paths cover sprite, anim, tile, nine-slice UI, font, and
portrait. Manifest `--kind` choices currently are
`sprite|anim|tile|sheet`; other kinds still bake, they just use one of
those labels or omit registry fields until kinds expand.

Future kinds when needed:

- `tilemap` -- multi-tile scenes; tile-pattern extraction
- `particle` -- effect sprite sequences
- `bg` -- background / parallax layer
- `cutscene` -- sequence composition

Each kind owns its prompt templates, completion checklist, and bake
pipeline. Core stays unchanged across kinds.

---

## Cross-links

- `sprite.py --help` / `sprite.py <subcommand> --help` -- live command surface
- `requirements.txt` -- pip deps for this pipeline
- `docs/graphics-gotchas.md` -- GBA graphics hazards that affect bake targets
- `docs/debugging.md` -- emulator / harness debugging notes
- This file's anchors: [Authentication](#authentication),
  [Configuration](#configuration),
  [Offline vs online](#offline-vs-online-stage-reference),
  [Failure modes](#failure-modes-and-recovery)
