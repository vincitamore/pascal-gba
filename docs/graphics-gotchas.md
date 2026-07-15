# PPU and VRAM gotchas

Three failure modes recur when writing GBA sprite and background code by
hand. Each produces a visually obvious defect with a non-obvious cause, and
each is a documented property of the hardware rather than a bug in this
emulator, so the same code paths matter on real hardware too.

## OAM cold-init defaults to visible, not hidden

OAM (Object Attribute Memory, at `$07000000`) holds 128 OBJ entries of 8
bytes each. On a clean-init run, every entry's bytes are zero. Reading the
attribute fields of a zeroed entry:

- `attr0 = 0`: bit 8 (rotation/scaling) clear, bit 9 (hide, meaningful only
  when bit 8 is clear) clear, meaning **visible**; shape bits clear
  (square); Y position 0.
- `attr1 = 0`: X position 0; size bits clear (8x8).
- `attr2 = 0`: tile index 0 (first tile in OBJ VRAM); priority 0; palette
  bank 0.

Net effect: every one of the 128 slots is configured as a visible 8x8
sprite at screen position (0,0), drawing OBJ VRAM tile 0 with palette bank
0. As soon as you configure one real sprite with actual tile data, the
other 127 slots render that same tile stacked on top of each other in the
screen's upper-left corner.

The symptom is a small block of the active sprite's colors pinned to the
top-left corner regardless of gameplay. It doesn't respond to display-mode
changes short of disabling OBJs outright, and it's invisible whenever your
own sprite also happens to sit at (0,0), since the phantom and the real
sprite exactly overlap. That overlap is why the bug is easy to miss during
early development and only shows up once a sprite moves away from the
origin.

The fix: before configuring any OAM entry you intend to use, explicitly
hide all 128 slots by setting attr0 bit 9.

```pascal
const
  OAM_BASE = $07000000;
var
  i: Integer;
begin
  for i := 0 to 127 do
    PWord(OAM_BASE + i * 8)^ := $0200;  { attr0 bit 9: hide }
  { now write your real OAM entries }
end;
```

`$0200` is bit 9 of a 16-bit halfword. The rest of attr0 and the full
attr1/attr2 don't matter once the hide bit is set; the PPU short-circuits
on hidden OBJs and never reads the remaining fields.

Note that real-hardware BIOS does not guarantee OAM is zeroed on cold boot
the way a clean emulator init does. Retail games that work correctly on
real hardware clear OAM themselves at startup rather than relying on
whatever state it happened to power on in. Treat the clear-all-128-slots
step as mandatory cart-side startup code, not an emulator-specific
workaround.

## VRAM: no byte writes

GBA VRAM hardware has a documented quirk (see GBATEK): an 8-bit write to
VRAM duplicates that byte across both halves of the containing 16-bit
halfword, rather than writing only the addressed byte. In 4bpp tile data,
each byte packs two 4-bit pixel indices, so a single-byte store meant to
set one pixel pair also stomps the neighboring byte, which is a different
pixel pair, with the same value.

The rule is unconditional: never issue a single-byte write against the
`$06000000` VRAM region. Always assemble the two bytes you want and write
them together as one 16-bit halfword store.

```pascal
{ WRONG: each byte write also clobbers its sibling byte in the
  same halfword, corrupting the adjacent pixel pair. }
PByte(VRAM_ADDR)^     := loByte;
PByte(VRAM_ADDR + 1)^ := hiByte;

{ RIGHT: pack both bytes and issue one halfword write. }
hw := Word(loByte) or (Word(hiByte) shl 8);
PWord(VRAM_ADDR)^ := hw;
```

This applies to tile data and tilemap entries alike, and to any code path
that issues direct byte-granularity stores against a VRAM address, whether
that's cart code building tiles at runtime or a build-time tool assembling
data destined for a block copy. A build-time buffer that is itself
byte-addressable is fine as long as the final transfer into VRAM moves data
in halfword (or word) units; the corruption only happens at the point
where a single byte actually lands on the VRAM bus.

## BG palette slot 0 is always backdrop in 4bpp BG modes

In 4bpp background tile modes, pixel index 0 within any tile always
resolves to BG palette entry 0, the screen's backdrop color, regardless of
which of the 16 palette banks that tile's attributes select. This is
documented GBA behavior, not a bug: index 0 means "show the backdrop" on
background layers.

If a tile-baking pipeline places a real, opaque color at index 0 of a
palette bank instead of reserving that slot for transparency, every tile
using that bank shows a transparent hole wherever the source art used
index 0, because the hardware substitutes the shared backdrop color there
instead of the bank's own color 0. The effect looks like missing pixels in
otherwise-solid terrain or UI tiles, and it only appears once you look at
tiles that actually use index 0 for real content, which makes it easy to
miss in a spot check of one or two tiles.

The fix is to shift every pixel index in baked BG tile data by +1 at bake
or load time, and to place an unused or transparent-looking color at index
0 of each palette bank so nothing ever actually depends on it being read as
real content. The bake's original colors then occupy indices 1 through 15
instead of 0 through 14.

OBJ (sprite) layers are not affected by this rule: OBJ palette index 0 is
genuinely transparent per bank on that layer. The backdrop substitution at
index 0 is specific to BG layers.
