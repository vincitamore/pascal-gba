# Cart framework kit

`src/kit/` holds small, independent units for building real carts on this
toolchain. Each unit is usable alone; none imposes a framework. Cart code
adds `src/kit` to its unit path automatically when built through
`build-gba.ps1`.

Current units (the spine — sprite/BG/text units land as game production
pulls them):

| Unit | Provides | Host-testable |
|------|----------|---------------|
| `Kit_Scene` | scene machine + id registry | yes (`test_kit`) |
| `Kit_Input` | per-frame keypad state, edge detection | demo cart |
| `Kit_Rng` | seeded deterministic xorshift32 | yes (`test_kit`) |
| `Kit_Fixed` | 24.8 fixed-point arithmetic | yes (`test_kit`) |
| `Kit_Save` | byte-wide SRAM access, verified writes, checksum | checksum yes; SRAM via demo cart |

`test/kit_demo.pp` exercises every unit in one cart; `test/test_kit.pas`
pins the pure parts (RNG sequence, fixed-point identities, scene
semantics, checksum). The RNG sequence test is a determinism contract:
changing the generator breaks every recorded game replay.

## Frame shape

```pascal
uses Kit_Scene, Kit_Input;

begin
  { register scenes, switch to the first one }
  while True do
  begin
    WaitVBlank;      { your vblank sync }
    InputUpdate;     { once per frame, before game logic }
    SceneTick;       { pending switch (Init), then current Update }
  end;
end.
```

## Adding a game (recipe)

A "game" is a scene id plus game-side data. The kit deliberately holds no
game metadata — icon, name, unlock rules live in YOUR tables, indexed by
the same id.

1. Pick the next free scene id (`MAX_SCENES` = 32).
2. Write `Init` (load art, reset state, `RngSeed(fixed_seed)`) and
   `Update` (read `KeysHeld`/`KeysPressed`, advance one deterministic
   step, draw).
3. `SceneRegister(id, @MyInit, @MyUpdate)` at boot; enter with
   `SceneSwitch(id)`; leave with `SceneSwitch(HUB_ID)` on your back
   button.
4. Add the game's row to your own metadata tables (menu icon, save slot).
5. Record a replay of one full run; keep it with the cart as its
   regression scenario (screenshots of deterministic scenes are
   byte-stable across runs — see `test/scripts/kit-demo.replay`).

## Determinism rules (what makes replays regress-able)

- One `InputUpdate` + one `SceneTick` per frame, nothing in between that
  reads the keypad register directly.
- All randomness through `Kit_Rng`, seeded from fixed data. Never from
  wall-clock or uninitialized memory.
- Game state advances only in `Update` — one fixed step per frame.

## Save pattern (recommended)

`Kit_Save` provides primitives only; the schema is yours. The pattern
that survives power loss mid-write:

```pascal
SramInit;                            { boot: marker + wait state }

{ layout: magic + version + payload + XOR checksum, }
{ primary copy at $0000, backup copy at $0100        }
if not LoadFrom(PRIMARY) then LoadFrom(BACKUP);

{ save: write+verify primary, then mirror to backup }
ok := SramWriteVerified(PRIMARY, @rec, SizeOf(rec));
if ok then SramWriteVerified(BACKUP, @rec, SizeOf(rec));
```

Linking `Kit_Save` embeds the `SRAM_V113` marker, so save-type
autodetection (this emulator, mGBA, flashcarts) maps 32 KB SRAM without
any per-cart work. All SRAM access is byte-wide — the region is an 8-bit
bus; `Kit_Save`'s block helpers already respect that.

## Debug narration in kit-based carts

Use `DbgLogStr` + `DbgLogWaitConsumedBounded(4)` (from `Gba_Dbg`). The
unbounded `DbgLogWaitConsumed` is for emulator-only test carts — nothing
clears the ready byte on real hardware, so it hangs a device
(`docs/debugging.md` has the full mechanism).
