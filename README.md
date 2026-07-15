# pascal-gba

A complete Free Pascal toolchain for Game Boy Advance development, with its own
emulator and debugging rig:

- **Cross-compile toolchain**: build real `.gba` ROMs from Object Pascal with
  FPC's `-Tgba` target, patched and wired up end to end (installers included).
- **Emulator**: a GBA emulator written in Pascal (`bin\gbarun.exe`): full
  ARM7TDMI core, PPU, DMA, timers, IRQ, APU, and cartridge saves, with a
  headless mode built for scripted, deterministic runs.
- **Replay + capture rig**: scripted input replays, multi-shot framebuffer
  screenshots, full state dumps, and a cart-to-host debug logging channel.
- **Asset pipeline**: an image-generation pipeline (`assets/`) that turns AI
  image output into GBA-ready 4bpp tiles, palettes, and sprite sheets.
- **Agent skill**: `skill/SKILL.md` teaches an agent harness to drive all of
  the above.

The emulator boots commercial cartridge images and homebrew alike, and ships
with a bundled MIT-licensed replacement BIOS so nothing else is needed to run.

## Layout

| Path | Contents |
|---|---|
| `src/` | Emulator + cart-side Pascal units |
| `test/` | Host-side test suite + cart smoke ROM sources |
| `tools/` | Toolchain installers, FPC patches, build scripts, `gbafix.py` |
| `bios/` | Bundled replacement BIOS: prebuilt `gba_bios.bin` + buildable source |
| `assets/` | Image-to-GBA asset pipeline (`sprite.py` + `sprite_lib/`) |
| `docs/` | Engineering notes: debug logging, PPU gotchas, RTL limitations |
| `skill/` | The agent skill |
| `build-gba.ps1` | Cross-compile a Pascal source to a `.gba` ROM |

## Prerequisites

Windows x64. Three installs, in order:

1. **FPC with the `-Tgba` cross target** — `tools\install-tgba.ps1` installs
   FPC via fpcupdeluxe to `C:\fpcupdeluxe`, then `tools\build-gba-rtl.ps1`
   builds the arm-gba RTL with the shipped patches (`tools\fpc-patches\`).
2. **devkitARM** — `tools\install-devkitpro.ps1` installs to `C:\devkitPro`
   (binutils + libgba; also used to build the BIOS).
3. **Python 3.10+** — used by `gbafix.py` (ROM header patching) and the asset
   pipeline.

`tools\toolchain-check.ps1` verifies the whole chain; `tools\survey.ps1`
inspects an FPC install when something is off.

## Quick start

```powershell
# Build the smoke ROM
.\build-gba.ps1 test\dbg_smoke
# The FPC line "Util gbafix.exe not found" is harmless noise; the build is
# good when the final line reads OK: ... bytes.

# Build the emulator and host-side test binaries
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-host.ps1

# Run the ROM headless
.\bin\gbarun.exe --rom test\dbg_smoke.gba --headless --frames 300
```

Expected: ten `dbg_smoke msg N of 10` debug-log lines around frames 61-70 and
exit code 0. That one run exercises the compiler, the linker script, the ROM
header patch, the BIOS, the CPU core, the IRQ path, and the debug channel.

## The emulator

`bin\gbarun.exe` loads any `.gba` ROM. Windowed by default; `--headless` skips
the window and audio and runs as fast as the host allows.

| Flag | Effect |
|---|---|
| `--rom PATH` | ROM to load (default `test\dbg_smoke.gba`) |
| `--bios PATH` | BIOS image (default `bios\gba_bios.bin`) |
| `--frames N` | Frames to simulate (0 = run until the window closes) |
| `--headless` | No window, no audio, no frame pacing |
| `--screenshot PATH` | Write the framebuffer as PNG at end of run |
| `--screenshot-frame N` | Capture at the end of frame N instead |
| `--replay PATH` | Drive scripted input from a replay file |
| `--record PATH` | Record keypad input to a replay file |
| `--dbglog-out PATH` | Dump the captured debug-log tail at shutdown |
| `--dump-audio PATH` | Dump APU output to a WAV file |

Exit codes: `0` clean, `1` ROM/BIOS missing or unloadable, `2` unmapped-memory
flood, `3` CPU halted with no IRQ progress. In windowed mode, F12 writes a
full state dump (CPU, IRQ, timers, DMA, OAM, debug log) to `dumps\`.

Scope: full ARM + THUMB instruction set, PPU modes 0/1/2 (tile, affine,
sprites, windows, blending), all four DMA channels and timers, all IRQ
sources, PSG + Direct Sound FIFO audio, SRAM/Flash/EEPROM saves with
autodetection. Bitmap modes 3/4/5, serial link, and cycle-accurate prefetch
timing are out of scope.

## Replay scripts

Plain text, one event per line; frame numbers are emulator frames (cart code
starts around frame 60 with the bundled BIOS).

| Action | Meaning |
|---|---|
| `press BUTTON` / `release BUTTON` | Hold / release a button |
| `tap BUTTON` | Press this frame, release next frame |
| `screenshot PATH` | Capture the framebuffer at this frame |
| `dump-state PATH` | Write a full state dump at this frame |
| `dump-game PATH` | Decode a cart-published snapshot struct (see `src\game_snapshot.pas`) |

Buttons: `A B START SELECT UP DOWN LEFT RIGHT L R` (case-insensitive).
`test\scripts\multi-shot.replay` captures three screenshots and a state dump
from a single run:

```powershell
.\bin\gbarun.exe --rom test\dbg_smoke.gba --headless `
    --replay test\scripts\multi-shot.replay --frames 300
```

## Debug logging

Cart code prints to the host through a 127-byte ring in EWRAM: `uses Gba_Dbg`
and call `DbgLogStr('message')`. The emulator polls once per frame and prints
`[dbglog fN L1] message`. The wire format, the placement rationale, and two
register-clobber footguns are documented in `docs\debugging.md` — read it
before instrumenting cart code. `docs\graphics-gotchas.md` and
`docs\rtl-limitations.md` cover the PPU/VRAM hazards and the `-Tgba` RTL
restrictions (no `Format()`/`IntToStr` in cart code) respectively.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\run_all_tests.ps1   # host-side unit suites
powershell -NoProfile -ExecutionPolicy Bypass -File test\headless_smoke.ps1  # CLI exit-code matrix
.\bin\sprite_smoke.exe    # OBJ render path against the shipped test sprite
```

The host suites cover the CPU core, PPU, BIOS HLE, saves, replay parsing, and
the debug channel. `test\sprite_input.inc` is a generated geometric test
sprite; `tools\gen-test-sprite.py` regenerates it.

## The bundled BIOS

`bios\gba_bios.bin` is built from the MIT-licensed Cult-of-GBA BIOS source
vendored under `bios\src\` — no Nintendo code. It boots in about 60 frames and
skips the logo/checksum lockout of the original console. Rebuild with
`tools\build-bios.ps1`. Provenance, license, and coverage notes: `bios\README.md`.

## Asset pipeline

`assets\sprite.py` drives an image-generation workflow (xAI Imagine API) into
GBA-ready assets: prompt scaffolds for sprites, terrain, UI chrome and
portraits, background-key removal, palette quantization, 4bpp tile baking,
seamless-tile wrapping, and an emulator-in-the-loop review step that renders
baked output through the real PPU.

```powershell
cd assets
python -m pip install -r requirements.txt
```

Set `XAI_API_KEY` for image generation (create a key at console.x.ai and grant
it the endpoints/models you use); every other stage runs offline with no
credentials. Full doctrine, configuration, and authentication details:
`assets\PIPELINE.md`.

## License

MIT (see `LICENSE`). The vendored BIOS source retains its own MIT copyright
notice (`bios\LICENSE`).
