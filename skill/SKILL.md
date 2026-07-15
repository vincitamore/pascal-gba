---
name: pascal-gba
description: Drive the pascal-gba toolchain from an agent harness - cross-compile Object Pascal to GBA ROMs (build-gba.ps1), run them headless in the bundled emulator (bin\gbarun.exe) with scripted replays, multi-shot screenshots, state dumps, and cart-to-host debug logging, and build the host test suite. Load BEFORE building or running anything in this repository. Covers the command surface and the cart-side coding discipline; the docs/ pages carry the deep engineering rationale.
---

# pascal-gba agent skill

The repository is three instruments: a Pascal-to-GBA cross-compile toolchain, a
GBA emulator with a headless replay/capture rig, and an image-to-GBA asset
pipeline. This skill is the command surface. Everything below assumes the
working directory is the repository root.

## Maintaining this skill

A stale skill is worse than no skill: an agent trusts it over the source and
inherits the drift. If you extend the toolchain, this contract keeps the skill
honest:

- **Source is canonical, not this prose.** The runner has no `--help`
  (unknown flags are silently ignored), so per surface the authority is: CLI
  flags and defaults - the arg parser in `test\gbarun.pas`; replay grammar -
  `src\replay.pas` (`TReplayAction`, `ParseButton`); debug-log wire format -
  `src\gba_dbg.pas` + `src\dbg_log.pas` (the addresses must match on both
  sides); exit-code thresholds - `src\gba_runner.pas`. When this file
  disagrees with source, source wins - then fix this file.
- **Update in the same change that moves the surface, never batched.** A new
  flag, replay action, exit code, build step, or failure mode lands here in
  the commit that creates it; the act of noticing is the trigger. The same
  reflex owns the `docs\` pages and the README - a maintained skill does not
  excuse a stale doc.
- **Carry standing content only**: what is true now and how to use it.
  History belongs in git log; project status and plans do not live here at
  all.
- **Admission filter.** Command surface and gotchas that bite repeatedly go
  here; deep rationale and investigation write-ups go to a `docs\` page,
  linked; one-off session detail goes nowhere.
- **Defer only against a concrete trigger** ("when a second cart needs X"),
  never a calendar bucket ("later", "v2") - an undated deferral rots into
  permanent invisible debt.
- **Compress a section when it accretes past utility.** Maintenance is not
  append-only.
- **After editing, verify on a real task**: run the acceptance smoke under
  "Standard verification runs" and judge what an agent actually does with the
  new text, not just whether the commands still pass.

The frontmatter `description` is the only text an agent harness reads when
deciding whether to load this skill: keep it dense - what this is, when to
load it, and when not to.

## Cross-cutting facts

1. **Run from the repo root.** Relative paths in `build-gba.ps1`, `gbarun.exe`
   defaults, and replay output paths all assume it.
2. **The "Util gbafix.exe not found" link error is noise.** FPC tries to run a
   host gbafix and fails; the build script runs `tools\gbafix.py` afterward.
   The build is good when the final line prints `OK: ... bytes`.
3. **The bundled BIOS boots in ~60 frames.** Cart code gets control around
   emulator frame 60 (the smoke ROM's first debug message lands at frame 61).
   Plan replay scripts and `--screenshot-frame` values accordingly.
4. **`bin\gbarun.exe` is the canonical runner.** It loads any ROM via `--rom`
   and defaults to `test\dbg_smoke.gba` and `bios\gba_bios.bin`.
5. **Exit codes**: `0` clean (frame budget reached or window closed), `1`
   ROM/BIOS path missing or load failed, `2` unmapped-memory access flood,
   `3` CPU halted with no IRQ progress for 120 frames.

## Build

```powershell
# Cross-compile a Pascal source to a .gba ROM (emits next to the source)
.\build-gba.ps1 test\dbg_smoke
.\build-gba.ps1 -KeepIntermediates test\dbg_smoke   # keep .o/.s/.ppu

# Host-side emulator + test binaries into bin\
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-host.ps1

# Rebuild the bundled BIOS from bios\src (only needed after editing it)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-bios.ps1

# Windowed launcher (ROM picker; needs Lazarus for lazbuild)
lazbuild shell\gbashell.lpi
```

Toolchain missing? `tools\toolchain-check.ps1` reports OK/MISS per component;
`tools\install-tgba.ps1` and `tools\install-devkitpro.ps1` install the chain.

## Run

```powershell
# Windowed (close the window or Esc to exit; F12 writes a state dump to dumps\)
.\bin\gbarun.exe --rom <path.gba> --frames 0

# Headless, deterministic
.\bin\gbarun.exe --rom <path.gba> --headless --frames 600
.\bin\gbarun.exe --rom <path.gba> --headless --frames 600 --screenshot out.png --screenshot-frame 300
```

| Flag | Effect |
|---|---|
| `--rom PATH` | ROM to load (cwd-relative, then exe-relative) |
| `--bios PATH` | BIOS image (default `bios\gba_bios.bin`) |
| `--frames N` | Frame budget; 0 = until the window closes (windowed only) |
| `--headless` | No window, no audio, no 60 FPS pacing |
| `--scale N` | Window size multiplier, 1-8 (default 3) |
| `--screenshot PATH` | PNG of the framebuffer at end of run |
| `--screenshot-frame N` | Capture at the end of frame N (1-indexed) |
| `--replay PATH` | Scripted input (grammar below) |
| `--record PATH` | Record keypad input to a replay script |
| `--dbglog-out PATH` | Write the debug-log tail to a file at shutdown |
| `--dump-audio PATH` | APU output to WAV |
| `--poke HEX_ADDR HEX_VAL` | Force a byte into IWRAM every frame (debug) |

## Replay scripts

One event per line; frame numbers are emulator frames (cart control ~frame 60).

```
0    press      START
1    release    START
60   tap        A               # press at N, release at N+1
150  screenshot bin/f150.png    # framebuffer at this frame
200  dump-state bin/s200.txt    # full CPU/IRQ/DMA/OAM/debug-log dump
250  dump-game  bin/g250.txt    # decode a cart-published snapshot struct
```

Buttons: `A B START SELECT UP DOWN LEFT RIGHT L R` (case-insensitive).
Output paths are relative to the emulator's working directory (the repo root).
`test\scripts\multi-shot.replay` is a working example: several screenshots and
a state dump from one run, no re-boot between captures — the canonical way to
verify time-varying behavior.

## Standard verification runs

```powershell
# 1. Toolchain + emulator + debug channel end to end (the acceptance smoke):
.\build-gba.ps1 test\dbg_smoke
.\bin\gbarun.exe --rom test\dbg_smoke.gba --headless --frames 300
#    -> ten "dbg_smoke msg N of 10" lines around frames 61-70, exit 0

# 2. Host-side unit suites (CPU, PPU, BIOS HLE, saves, replay, debug channel):
powershell -NoProfile -ExecutionPolicy Bypass -File test\run_all_tests.ps1

# 3. CLI exit-code matrix:
powershell -NoProfile -ExecutionPolicy Bypass -File test\headless_smoke.ps1

# 4. OBJ render path against the shipped generated test sprite:
.\bin\sprite_smoke.exe     # writes bin\sprite_f0..f3.ppm

# 5. Real-device / third-party-core verification cart (boot, input echo,
#    PSG blip per key, SRAM boot counter with read-back verify):
.\build-gba.ps1 test\device_smoke
.\bin\gbarun.exe --rom test\device_smoke.gba --headless --frames 300 --screenshot bin\smoke.png
#    run twice: BOOT count increments via test\device_smoke.sav; screen
#    shows SAVE NEW on first boot, SAVE OK after. Copy the .gba to a
#    device or another emulator to smoke-test it the same way.
#    test\scripts\device-smoke.replay exercises the input echo + blips.

# 6. Framework-kit demo (scene machine, input edges, seeded RNG,
#    fixed-point movement, verified SRAM saves):
.\build-gba.ps1 test\kit_demo
.\bin\gbarun.exe --rom test\kit_demo.gba --headless --frames 300 --replay test\scripts\kit-demo.replay
#    deterministic play field: screenshots are byte-stable across runs.

# 7. Kit audio demo (looping tune + six SFX voices; START toggles music):
.\build-gba.ps1 test\audio_demo_cart
.\bin\gbarun.exe --rom test\audio_demo_cart.gba --frames 0            # ear check
.\bin\gbarun.exe --rom test\audio_demo_cart.gba --headless --frames 600 --dump-audio bin\tune.wav
#    tune data: tools\song.py test\songs\demo.song (docs\kit.md has the format)

# 7b. Kit DirectSound sample demo (FIFO A + Timer 0 + DMA1):
.\build-gba.ps1 test\sample_demo
.\bin\gbarun.exe --rom test\sample_demo.gba --headless --frames 120 --dump-audio bin\sample.wav
#    expect FIFO-A pushes >> 32 and DMA1 transfers; A replays, B stops.
#    sample data: tools\voice.py <wav> -o test\samples\hi.inc --name Hi

# 8. Mode-0 kit demo (multi-palette scrolling BG + OAM sprite + text HUD):
.\build-gba.ps1 test\mode0_demo
.\bin\gbarun.exe --rom test\mode0_demo.gba --headless --frames 400 --replay test\scripts\mode0-demo.replay
#    d-pad scrolls a 512-wide 13-bank field; the HUD readout tracks HOFS;
#    A flips the pulsing sprite. Deterministic: screenshots byte-stable.

# 9. Replay regression: pinned-hash verification of deterministic replay runs:
python tools\regress.py test\regress\kit_demo.case test\regress\mode0_demo.case
#    --update re-pins after an intended change; review the diff first.

# 10. Cross-validate a ROM against mGBA (independent reference core):
powershell -File tools\mgba-shot.ps1 -Rom test\mode0_demo.gba -Out bin\mgba.png
#    boots the ROM in mGBA's SDL build and captures its window to a PNG
#    (mGBA 0.10 has no headless screenshot surface). Locates mgba-sdl.exe
#    via -MgbaSdl, the MGBA_SDL env var, or PATH.
```

## Cart-side coding discipline

Cart code is `{$mode objfpc}{$H+}` Pascal compiled with `-Tgba`. Real carts
build on the framework kit (`src\kit\`: scene machine, input edge-detect,
seeded RNG, fixed-point, SRAM save, PSG audio driver + `tools\song.py`
score authoring, DirectSound sample playback via `SamplePlay` +
`tools\voice.py` (WAV -> signed 8-bit `.inc`), text-BG loader + scroll,
OAM sprite manager, tile-grid text — `docs\kit.md` has the unit reference,
frame shape, add-a-game recipe, determinism rules, score format, and
sample path). The RTL rules that bite are documented with full rationale
in `docs\`:

- **Debug logging** (`docs\debugging.md`): `uses Gba_Dbg`, `DbgLogStr` with
  STATIC strings only; call `DbgLogWaitConsumed` between two logs on the same
  code path; promote locals that must survive a log call to unit-level vars
  (caller-saved-register clobber). CAUTION for carts that also run on real
  hardware or third-party emulators: nothing clears the ready byte there, so
  an unbounded `DbgLogWaitConsumed` hangs the cart — call
  `DbgLogWaitConsumedBounded(4)` instead (same unit; waits for consumption
  but gives up after N vblank edges).
- **No `Format()`/`IntToStr`/`Str()` in cart code** (`docs\rtl-limitations.md`):
  the `-Tgba` RTL's numeric formatting is broken; build strings by explicit
  char assignment or pre-built variants.
- **Graphics** (`docs\graphics-gotchas.md`): never byte-write VRAM (halfwords
  only); hide all 128 OAM slots before configuring any (write `$0200` to each
  attr0); BG palette slot 0 is always the backdrop in 4bpp modes (shift pixel
  indices +1 at load).
- **VBlank sync** (poll-based, no IRQ setup needed):

```pascal
procedure WaitVBlank;
begin
  while PWord($04000006)^ >= 160 do ;   { VCOUNT }
  while PWord($04000006)^ <  160 do ;
end;
```

- **Key input is active-low**: `keys := (PWord($04000130)^ and $03FF) xor $03FF;`
  Edge-detect with `edge := keys and (keys xor prevKeys);`.

## Failure modes

| Symptom | Cause |
|---|---|
| Link "error" about gbafix.exe, but `OK:` prints | Harmless (fact 2) |
| ROM stalls on the BIOS splash | `gbafix.py` did not run; rebuild via `build-gba.ps1` |
| Debug lines truncated or missing | Missing `DbgLogWaitConsumed` between same-frame logs |
| Garbage in a local var after a log call | Register clobber; promote the local to a unit var |
| Phantom sprites in the top-left corner | OAM slots not hidden on init |
| Terrain tiles show holes | BG palette slot-0 backdrop; shift indices +1 |
| Exit 3, `halted=1` | Cart never progressed past an IRQ wait; check IE/IME setup |
| Replay action ignored | Unknown button/action name; see the grammar table |

## Asset pipeline

`assets\sprite.py` turns AI-generated images into GBA-ready tiles, palettes,
and sprite sheets, with an emulator-in-the-loop review stage. Install its two
dependencies with `python -m pip install -r assets\requirements.txt`. Only
`gen`/`edit`/`video` need credentials (`--api-key` flag > `XAI_API_KEY` env >
OAuth file); the other stages run offline. Path roots are flag-or-env driven:
`--cache-dir`/`SPRITE_CACHE_DIR`, `--manifest-dir`/`SPRITE_MANIFEST_DIR`,
`--ledger`/`SPRITE_LEDGER` (defaults are cwd-relative). Full documentation:
`assets\PIPELINE.md`.

Bakers: `bake`/`anim` (OBJ sprites), `tile` (seamless terrain), `ui-bake`
(nine-slice chrome), `font-bake` (pixel-font glyph banks), and `bg-bake`
(full image -> deduplicated BG tile set + tilemap + palette for text-BG
modes; mirror tiles dedup through the map-entry flip bits, and a round-trip
preview PNG proves the bake reconstructs the quantized source exactly).
Consumer projects keep art walkable: `art/src` (generation sources),
`art/bg` (BG bakes), `art/sprites` (OBJ bakes), `shots/` (replay
screenshots + logs); the staging dir is scratch and empties at the end
of every production wave (`PIPELINE.md`, Asset hygiene).

`bg-bake --palettes N` (2..16) clusters tiles into independent 16-color
palette banks via the map-entry palette bits -- the fix for multi-region
images (night sky + gold banner) that bleed through one shared 15-color
palette. Tile data is bank-agnostic, so identical index patterns share
storage across banks. `bg-bake --max-tiles N` vector-quantizes the tile
set to a budget for organic sources whose noise defeats dedup (the
1024-tile guard); judge the budget against the round-trip preview.
