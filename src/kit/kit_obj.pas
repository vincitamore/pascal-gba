unit Kit_Obj;
{
  OAM sprite manager: shadow attribute table, hidden cold-init,
  attribute setters, vblank commit, OBJ VRAM/palette loaders.

  Zeroed OAM means 128 VISIBLE 8x8 sprites stacked at (0,0) -- the
  cold-boot phantom-sprite artifact. ObjInit hides every slot and
  commits immediately; call it once at boot, before enabling OBJ in
  DISPCNT.

  All setters write the IWRAM shadow only. Call ObjCommit once per
  frame right after your vblank sync, so the OAM copy lands inside
  the blanking window:

    WaitVBlank;
    ObjCommit;       -- push last frame's shadow while in vblank
    InputUpdate;
    SceneTick;       -- game logic mutates the shadow for next frame

  Sprite tile data comes from the asset pipeline's OBJ-order bakes
  (<NAME>_OBJ_ORDER = 1): ObjLoadTiles copies them VRAM-ready. With
  1D mapping (DISP_OBJ_1D), a WxH sprite occupies (W/8)*(H/8)
  consecutive 32-byte tiles starting at its attr2 tile index; frame N
  of an animation starts at firstTile + N * tilesPerFrame.

  In bitmap modes (3-5) the framebuffer overlaps the first half of OBJ
  VRAM: only tile indices 512+ are usable there, and switching a scene
  from a bitmap mode to a tiled mode must reload OBJ tiles it expects
  below 512.
}

{$mode objfpc}{$H+}

interface

const
  { attr0 shape }
  OBJ_SQUARE = 0;
  OBJ_WIDE   = 1;
  OBJ_TALL   = 2;

  { attr1 size index; pixel dims depend on shape:
      size   SQUARE   WIDE     TALL
      0      8x8      16x8     8x16
      1      16x16    32x8     8x32
      2      32x32    32x16    16x32
      3      64x64    64x32    32x64  }
  OBJ_SIZE_0 = 0;
  OBJ_SIZE_1 = 1;
  OBJ_SIZE_2 = 2;
  OBJ_SIZE_3 = 3;

{ Hide all 128 slots and commit. Once at boot. }
procedure ObjInit;

{ Configure a slot and make it visible. tileIndex is the 4bpp tile
  number (0..1023), palBank the OBJ palette bank (0..15), prio 0..3
  (0 = front). Position is set separately. }
procedure ObjSet(slot, tileIndex, palBank, shape, sizeIdx, prio: Integer);

{ Move a slot. x is 9-bit, y 8-bit signed-wrapped by hardware, so
  sprites can enter smoothly from off-screen (e.g. x = -16). }
procedure ObjSetPos(slot, x, y: Integer);

{ Swap the slot's tile index (animation frames). }
procedure ObjSetTile(slot, tileIndex: Integer);

{ Set/clear horizontal + vertical flip. }
procedure ObjSetFlip(slot: Integer; h, v: Boolean);

procedure ObjHide(slot: Integer);
procedure ObjShow(slot: Integer);

{ Copy the shadow into OAM. Call once per frame, inside vblank. }
procedure ObjCommit;

{ Copy OBJ-order tile bytes into OBJ VRAM starting at tile index
  `firstTile` (0..1023; 32 bytes per 4bpp tile). Halfword writes. }
procedure ObjLoadTiles(firstTile: Integer; const data: array of Byte);

{ Copy a PAL array into one 16-slot OBJ palette bank (0..15). }
procedure ObjLoadPalette(bank: Integer; const pal: array of Word);

implementation

const
  OAM_BASE     = $07000000;
  OBJ_VRAM     = $06010000;
  OBJ_PAL_RAM  = $05000200;
  ATTR0_HIDDEN = $0200;
  MAX_OBJ      = 128;

type
  TObjEntry = record
    attr0, attr1, attr2, fill: Word;
  end;

var
  shadow: array[0..MAX_OBJ - 1] of TObjEntry;

procedure ObjInit;
var
  k: Integer;
begin
  for k := 0 to MAX_OBJ - 1 do
  begin
    shadow[k].attr0 := ATTR0_HIDDEN;
    shadow[k].attr1 := 0;
    shadow[k].attr2 := 0;
    shadow[k].fill  := 0;
  end;
  ObjCommit;
end;

procedure ObjSet(slot, tileIndex, palBank, shape, sizeIdx, prio: Integer);
begin
  if (slot < 0) or (slot >= MAX_OBJ) then Exit;
  shadow[slot].attr0 := (shadow[slot].attr0 and $00FF)      { keep y }
                        or Word((shape and 3) shl 14);
  shadow[slot].attr1 := (shadow[slot].attr1 and $01FF)      { keep x }
                        or Word((sizeIdx and 3) shl 14);
  shadow[slot].attr2 := Word(tileIndex and $3FF)
                        or Word((prio and 3) shl 10)
                        or Word((palBank and 15) shl 12);
end;

procedure ObjSetPos(slot, x, y: Integer);
begin
  if (slot < 0) or (slot >= MAX_OBJ) then Exit;
  shadow[slot].attr0 := (shadow[slot].attr0 and $FF00) or Word(y and $FF);
  shadow[slot].attr1 := (shadow[slot].attr1 and $FE00) or Word(x and $1FF);
end;

procedure ObjSetTile(slot, tileIndex: Integer);
begin
  if (slot < 0) or (slot >= MAX_OBJ) then Exit;
  shadow[slot].attr2 := (shadow[slot].attr2 and $FC00) or Word(tileIndex and $3FF);
end;

procedure ObjSetFlip(slot: Integer; h, v: Boolean);
begin
  if (slot < 0) or (slot >= MAX_OBJ) then Exit;
  shadow[slot].attr1 := shadow[slot].attr1 and $CFFF;
  if h then shadow[slot].attr1 := shadow[slot].attr1 or $1000;
  if v then shadow[slot].attr1 := shadow[slot].attr1 or $2000;
end;

procedure ObjHide(slot: Integer);
begin
  if (slot < 0) or (slot >= MAX_OBJ) then Exit;
  shadow[slot].attr0 := shadow[slot].attr0 or ATTR0_HIDDEN;
end;

procedure ObjShow(slot: Integer);
begin
  if (slot < 0) or (slot >= MAX_OBJ) then Exit;
  shadow[slot].attr0 := shadow[slot].attr0 and not ATTR0_HIDDEN;
end;

procedure ObjCommit;
var
  src: PLongWord;
  k: Integer;
begin
  src := PLongWord(@shadow[0]);
  for k := 0 to (MAX_OBJ * 2) - 1 do
    PLongWord(OAM_BASE + LongWord(k) * 4)^ := src[k];
end;

procedure ObjLoadTiles(firstTile: Integer; const data: array of Byte);
var
  base: LongWord;
  k: Integer;
begin
  base := OBJ_VRAM + LongWord(firstTile) * 32;
  k := 0;
  while k + 1 <= High(data) do
  begin
    PWord(base + LongWord(k))^ := Word(data[k]) or (Word(data[k + 1]) shl 8);
    Inc(k, 2);
  end;
end;

procedure ObjLoadPalette(bank: Integer; const pal: array of Word);
var
  k: Integer;
begin
  for k := 0 to High(pal) do
  begin
    if k > 15 then Exit;
    PWord(OBJ_PAL_RAM + (bank and 15) * 32 + k * 2)^ := pal[k];
  end;
end;

end.
