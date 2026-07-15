# bios/ - the bundled open-source GBA BIOS

This directory ships a buildable, MIT-licensed replacement GBA BIOS so a fresh
clone can run ROMs immediately. `gba_bios.bin` is the prebuilt artifact; the
runner (`bin\gbarun.exe`) loads it from this path by default.

## Provenance and license

The source under `src/` is vendored from the Cult-of-GBA BIOS project
(https://github.com/Cult-of-GBA/BIOS, commit `a30e9a9`), copyright 2020-2021
DenSinH and fleroviux, MIT license (see `LICENSE` in this directory). The MIT
notice applies to the source and to binaries built from it, including the
bundled `gba_bios.bin`. Local modifications, when made, are documented here.

Local modifications (all derived from GBATEK documentation, never from
Nintendo BIOS disassembly):
- SWI $19 SoundBias - ramps SOUNDBIAS bits 0-9 toward 0 or 0x200 per GBATEK,
  preserving amplitude bits; replaces the upstream no-op stub.
- SWI $1B SoundDriverMode - updates the SoundDriverInit-registered work
  area's reverb and max-channel fields and maps the documented D/A-bits
  field (mode bits 20-23) onto SOUNDBIAS bits 14-15.
- SWI $1E SoundChannelClear - stops direct sound: disables both sound DMA
  channels, resets the two FIFOs, and clears the registered work area's
  PCM buffer (ident-guarded).
- SWI $25 MultiBoot - returns the documented failure code (r0=1); this
  BIOS targets hardware with no serial-link peers, so the no-clients
  outcome is the correct result.
- SWI $2A SoundGetJumpList - two upstream defects fixed: the 36 pointers
  were stored byte-indexed (overlapping writes within 36 bytes), and the
  loop clobbered r3, which the SWI dispatcher does not save.
- SWI $1A SoundDriverInit / $28 SoundDriverVSyncOff - upstream zero-fill
  passed a source address one word below the pushed zero, filling the
  work area / PCM buffer with stack garbage; corrected.
- SWI $1C SoundDriverMain and the undocumented $20-$24 entries are
  labeled, deterministic immediate returns (registers preserved) - see
  the coverage table below for why that is the correct behavior here.
- Boot splash - "PASCAL GBA" wordmark and maintainer name, replacing the
  upstream splash text (MIT attribution retained here and in LICENSE).
  Same renderer, assets regenerated (`names.bmp`/`names.dat`).

This is NOT the Nintendo BIOS and contains no Nintendo code. It boots with its
own splash screen, does not verify the cartridge Nintendo-logo bytes or header
complement checksum, and reaches cart code in roughly 60 frames (the original
console takes about 267). Frame-numbered test expectations in this repo assume
the bundled BIOS.

## Building

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-bios.ps1
```

Requires devkitARM (`arm-none-eabi-as` / `arm-none-eabi-objcopy`), installed by
`tools\install-devkitpro.ps1`. The build assembles `src\entrypoint.s` (which
includes the rest of the source tree) and objcopies it to a 16384-byte flat
binary at `bios\gba_bios.bin`. Rebuild and commit the binary in the same change
whenever the source changes.

## Sound-family SWI coverage ($19-$2A)

| SWI | Function | Status |
|-----|----------|--------|
| $19 | SoundBias | implemented (local) |
| $1A | SoundDriverInit | implemented (upstream; zero-fill defect fixed locally) |
| $1B | SoundDriverMode | implemented (local) |
| $1C | SoundDriverMain | deterministic return - see note |
| $1D | SoundDriverVSync | implemented (upstream) |
| $1E | SoundChannelClear | implemented (local) |
| $1F | MidiKey2Freq | implemented (upstream) |
| $20-$24 | undocumented sound entries | deterministic return - see note |
| $25 | MultiBoot | implemented (local: documented no-clients failure) |
| $28 | SoundDriverVSyncOff | implemented (upstream; zero-fill defect fixed locally) |
| $29 | SoundDriverVSyncOn | implemented (upstream) |
| $2A | SoundGetJumpList | implemented (upstream; two defects fixed locally) |

Note on $1C and $20-$24: SoundDriverMain is the per-frame mix entry of the
BIOS-resident music driver, and $20-$24 have no documented semantics at all
(GBATEK lists them as undocumented). This BIOS ships no resident music
driver, and instrumented runs show no caller: two commercial mp2k titles
exercised for 12,000 frames each (boot through title, menus, and gameplay,
with a per-SWI call tally hooked at the CPU's SWI dispatch) invoked no
sound-family SWI whatsoever - cartridge-linked drivers own the sound path
on every title tested. The handlers are labeled, deterministic immediate
returns with all registers preserved.

`test/swi_sound.pp` is the cart-side proof harness for the implemented
handlers (jump-list layout and canaries, SoundDriverMode's SOUNDBIAS
mapping, SoundChannelClear's DMA stop, MultiBoot's failure return, and
clean returns from $1C/$20/$24); every check reports PASS over DbgLog.
