program test_phase_e;
{
  Phase E acceptance tests — sprite (OAM) rendering, window effects,
  color blending (brighten/darken).

  Coverage:
    SPR-1.  Single 8×8 4bpp sprite renders to expected screen position.
    SPR-2.  HFlip mirrors the sprite horizontally.
    SPR-3.  VFlip mirrors the sprite vertically.
    SPR-4.  Sprite outside scanline range produces no pixels.
    SPR-5.  Disable bit (Attr0 bit 9) hides the sprite.
    SPR-6.  8bpp sprite uses 256-color palette (no bank).
    SPR-7.  16×16 sprite (4 tiles) with 1D mapping.
    SPR-8.  16×16 sprite with 2D mapping (32-tile-wide grid).
    SPR-9.  X-wrap: sprite at X=508 places its tail at screen x=0..3.
    SPR-10. Multiple sprites; lower OAM index wins tied priority.
    SPR-11. Lower priority-number wins between sprites.

    PPU-1.  Sprite renders ON TOP of BG at tied priority.
    PPU-2.  BG renders OVER sprite when sprite priority > BG priority.
    PPU-3.  OBJ-disable bit (DISPCNT bit 12) suppresses sprite layer.

    WIN-1.  WIN0 region — only BG0 enabled inside → BG0 visible, BG1 not.
    WIN-2.  WIN-OUT — pixel outside both windows uses winOut layers.
    WIN-3.  WINOBJ — sprite with mode=window defines region; non-mode=window
            sprites in that region render normally per WININ's WINOBJ mask.

    BLD-1.  Brighten (mode 2) with EVY=16 turns target1 pixels white.
    BLD-2.  Darken (mode 3) with EVY=16 turns target1 pixels black.
    BLD-3.  Brighten skips non-target1 layers.

  Build & run:
    fpc -Mobjfpc -Sh -Fusrc -FEbin -FUbin test/test_phase_e.pas
    ./bin/test_phase_e

  Exits non-zero on any failed assertion.
}

{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, Memory, Sprites, Ppu;

var
  pass, fail: Integer;

procedure Check(cond: Boolean; const msg: string);
begin
  if cond then
  begin
    Inc(pass);
    Writeln('  ok   ', msg);
  end
  else
  begin
    Inc(fail);
    Writeln('  FAIL ', msg);
  end;
end;

procedure CheckEq(actual, expected: TWord; const msg: string);
begin
  if actual = expected then
  begin
    Inc(pass);
    Writeln('  ok   ', msg);
  end
  else
  begin
    Inc(fail);
    Writeln(Format('  FAIL %s  (actual=$%08x expected=$%08x)',
                   [msg, actual, expected]));
  end;
end;

{ Pack BGR555 from 8-bit RGB inputs. }
function MakeBgr555(r, g, b: Byte): THalf;
begin
  Result := THalf((r shr 3) or ((g shr 3) shl 5) or ((b shr 3) shl 10));
end;

{ Write OBJ palette entry. Index 0 of each subpalette is transparent. }
procedure PokeObjPalette(mem: TGbaMemory; idx: Integer; color: THalf);
begin
  mem.WriteHalf($05000200 + TWord(idx) * 2, color);
end;

procedure PokeBgPalette(mem: TGbaMemory; idx: Integer; color: THalf);
begin
  mem.WriteHalf($05000000 + TWord(idx) * 2, color);
end;

{ NOTE: Phase B's Memory.WriteByte duplicates the byte across the
  halfword for VRAM writes (see memory.pas "VRAM byte write" semantics —
  this is a documented Phase B simplification, fixed in a later phase
  with mode-aware BG/OBJ region splits). The seed helpers below therefore
  pack each pair of distinct bytes into a halfword and write the
  halfword, side-stepping the duplication trap. }

{ Build an 8x8 4bpp tile where every pixel uses sub-palette index `palIdx`.
  Solid-fill — every byte identical so byte-duplication is harmless. }
procedure SeedSolidTile4bpp(mem: TGbaMemory; slot: Integer; palIdx: Byte);
var
  i: Integer;
  base: TWord;
  packed_: Byte;
  hw: THalf;
begin
  base := $06010000 + TWord(slot) * 32;
  packed_ := (palIdx and $F) or ((palIdx and $F) shl 4);
  hw := THalf(packed_) or (THalf(packed_) shl 8);
  for i := 0 to 15 do
    mem.WriteHalf(base + TWord(i) * 2, hw);
end;

procedure SeedSolidTile8bpp(mem: TGbaMemory; slot: Integer; palIdx: Byte);
var
  i: Integer;
  base: TWord;
  hw: THalf;
begin
  base := $06010000 + TWord(slot) * 32;
  hw := THalf(palIdx) or (THalf(palIdx) shl 8);
  for i := 0 to 31 do
    mem.WriteHalf(base + TWord(i) * 2, hw);
end;

{ Rowwise tile: each row uses a single sub-palette index = row+1. Used
  by vflip test. }
procedure SeedRowwiseTile4bpp(mem: TGbaMemory; slot: Integer);
var
  row, halfCol: Integer;
  base: TWord;
  packed_: Byte;
  palIdx: Byte;
  hw: THalf;
begin
  base := $06010000 + TWord(slot) * 32;
  for row := 0 to 7 do
  begin
    palIdx := Byte(row + 1);
    packed_ := palIdx or (palIdx shl 4);
    hw := THalf(packed_) or (THalf(packed_) shl 8);
    for halfCol := 0 to 1 do
      mem.WriteHalf(base + TWord(row * 4 + halfCol * 2), hw);
  end;
end;

{ Columnwise tile: cols 0..7 use sub-palette indices 1..8. Used by hflip
  test. Each row of 4 bytes (= 1 halfword pair = 2 halfwords) needs to
  encode pixels 0..7 = palIdx 1..8 — packed as low/high nibbles. }
procedure SeedColumnwiseTile4bpp(mem: TGbaMemory; slot: Integer);
var
  row, halfCol: Integer;
  base: TWord;
  pixLow0, pixHigh0, pixLow1, pixHigh1: Byte;
  packed_0, packed_1: Byte;
  hw: THalf;
begin
  base := $06010000 + TWord(slot) * 32;
  for row := 0 to 7 do
    for halfCol := 0 to 1 do
    begin
      { Each halfword covers 2 bytes = 4 pixels. halfCol selects bytes
        (0,1) or (2,3); the pixels covered are (halfCol*4)..(halfCol*4+3). }
      pixLow0  := Byte(halfCol * 4 + 1);
      pixHigh0 := Byte(halfCol * 4 + 2);
      packed_0 := pixLow0 or (pixHigh0 shl 4);
      pixLow1  := Byte(halfCol * 4 + 3);
      pixHigh1 := Byte(halfCol * 4 + 4);
      packed_1 := pixLow1 or (pixHigh1 shl 4);
      hw := THalf(packed_0) or (THalf(packed_1) shl 8);
      mem.WriteHalf(base + TWord(row * 4 + halfCol * 2), hw);
    end;
end;

{ Hide every OAM slot by setting Attr0 bit 9 (disable). Tests that use
  specific sprite slots re-enable just those. Without this, the 128
  zero-initialized OAM entries all render as 8x8 sprites at (0,0) using
  tile 0 — which silently corrupts every test that seeds tile 0. }
procedure HideAllSprites(mem: TGbaMemory);
var
  i: Integer;
begin
  for i := 0 to 127 do
    mem.WriteHalf($07000000 + TWord(i) * 8, $0200);   { Attr0 with disable bit }
end;

function GetFramePixel(ppu: TGbaPpu; x, y: Integer): TWord;
begin
  Result := ppu.FrameBufferPtr^[y * GBA_WIDTH + x];
end;

procedure SetupForSpriteTest(mem: TGbaMemory; dispcnt: THalf);
begin
  HideAllSprites(mem);                                { critical — see helper note }
  mem.WriteHalf($04000000, dispcnt);
  PokeBgPalette(mem, 0, MakeBgr555(0, 0, 0));        { backdrop = black }
  PokeObjPalette(mem, 1, MakeBgr555(255, 0, 0));     { red }
  PokeObjPalette(mem, 2, MakeBgr555(0, 255, 0));     { green }
  PokeObjPalette(mem, 3, MakeBgr555(0, 0, 255));     { blue }
  PokeObjPalette(mem, 16 + 1, MakeBgr555(255, 255, 0)); { palette bank 1, idx 1 → yellow }
end;

{ ───── Sprite tests ──────────────────────────────────────────────── }

procedure TestSpriteBasic;
{ 8×8 sprite at (X=10, Y=20), tile-base=0, palette bank 0, sub-palette 1
  (red). DISPCNT mode 0 + OBJ enable + 1D mapping. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
  redArgb: TWord;
begin
  Writeln('SPR-1: single 8x8 sprite renders at (10,20)..(17,27)');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1040);  { mode 0 + 1D mapping + OBJ }
    SeedSolidTile4bpp(mem, 0, 1);
    PokeOamAttr(mem, 0,
      THalf(20) or 0,                                 { Y=20, shape=0=square }
      THalf(10) or 0,                                 { X=10, size=0=8x8 }
      THalf(0));                                      { tile=0, prio=0, palBank=0 }
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    redArgb := $FFFF0000;
    Check(GetFramePixel(ppu, 10, 20) = redArgb, '  px(10,20) red');
    Check(GetFramePixel(ppu, 17, 27) = redArgb, '  px(17,27) red');
    Check(GetFramePixel(ppu,  9, 20) = $FF000000, '  px(9,20) backdrop');
    Check(GetFramePixel(ppu, 18, 20) = $FF000000, '  px(18,20) backdrop');
    Check(GetFramePixel(ppu, 10, 19) = $FF000000, '  px(10,19) above sprite');
    Check(GetFramePixel(ppu, 10, 28) = $FF000000, '  px(10,28) below sprite');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSpriteHFlip;
{ Column-wise tile: cols 0..7 have palette indices 1..8. With HFlip,
  rendered pixel at sprite-col 0 should hold the palette of original col 7. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
  palidx_at_screen_0: TWord;
  palidx_at_screen_7: TWord;
begin
  Writeln('SPR-2: HFlip mirrors columns');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1040);
    SeedColumnwiseTile4bpp(mem, 0);
    { Use palette colors that uniquely identify cols. Cols 0..7 in tile use
      sub-palette indices 1..8. Set OBJ palette[1..8] to a recognizable pattern. }
    PokeObjPalette(mem, 1, MakeBgr555(8, 0, 0));
    PokeObjPalette(mem, 2, MakeBgr555(16, 0, 0));
    PokeObjPalette(mem, 3, MakeBgr555(24, 0, 0));
    PokeObjPalette(mem, 4, MakeBgr555(32, 0, 0));
    PokeObjPalette(mem, 5, MakeBgr555(40, 0, 0));
    PokeObjPalette(mem, 6, MakeBgr555(48, 0, 0));
    PokeObjPalette(mem, 7, MakeBgr555(56, 0, 0));
    PokeObjPalette(mem, 8, MakeBgr555(64, 0, 0));

    PokeOamAttr(mem, 0,
      THalf(20),                                       { Y=20 }
      THalf(10) or $1000,                              { X=10, HFlip=1 (bit 12) }
      THalf(0));
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);

    palidx_at_screen_0 := GetFramePixel(ppu, 10, 20);  { sprite-col 0 with hflip → was col 7, palIdx=8 }
    palidx_at_screen_7 := GetFramePixel(ppu, 17, 20);  { sprite-col 7 with hflip → was col 0, palIdx=1 }
    { 5-to-8 expansion: r5=1 → r8 = (1<<3) | (1>>2) = 8;
                          r5=8 → r8 = (8<<3) | (8>>2) = 66 = $42. }
    CheckEq(palidx_at_screen_0, $FF420000, '  screen-x 10 = orig col 7 (palIdx 8, r8=$42)');
    CheckEq(palidx_at_screen_7, $FF080000, '  screen-x 17 = orig col 0 (palIdx 1, r8=$08)');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSpriteVFlip;
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('SPR-3: VFlip mirrors rows');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1040);
    SeedRowwiseTile4bpp(mem, 0);
    PokeObjPalette(mem, 1, MakeBgr555( 8, 0, 0));
    PokeObjPalette(mem, 8, MakeBgr555(66, 0, 0));     { unique pattern at top/bottom }
    PokeOamAttr(mem, 0,
      THalf(20),                                       { Y=20 }
      THalf(10) or $2000,                              { X=10, VFlip=1 (bit 13) }
      THalf(0));
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    { Row 0 of sprite under vflip uses original row 7 (palIdx=8 → r5=66's expansion = $42). }
    Check(GetFramePixel(ppu, 10, 20) = $FF420000, '  px(10,20) = orig row 7 (palIdx 8)');
    Check(GetFramePixel(ppu, 10, 27) = $FF080000, '  px(10,27) = orig row 0 (palIdx 1)');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSpriteOutsideScanline;
{ Sprite at Y=100, size=8. Scanline 50 should be backdrop. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('SPR-4: sprite outside scanline range produces no pixels');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1040);
    SeedSolidTile4bpp(mem, 0, 1);
    PokeOamAttr(mem, 0, THalf(100), THalf(10), THalf(0));
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 10, 50) = $FF000000, '  scanline 50 = backdrop');
    Check(GetFramePixel(ppu, 10, 99) = $FF000000, '  scanline 99 = backdrop (just above)');
    Check(GetFramePixel(ppu, 10, 100) = $FFFF0000, '  scanline 100 = sprite');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSpriteDisable;
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('SPR-5: disable bit hides sprite');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1040);
    SeedSolidTile4bpp(mem, 0, 1);
    PokeOamAttr(mem, 0, THalf(20) or $0200, THalf(10), THalf(0));  { bit 9 = disable }
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 10, 20) = $FF000000, '  px(10,20) backdrop (sprite disabled)');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSprite8Bpp;
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('SPR-6: 8bpp sprite uses full 256-color OBJ palette');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1040);
    PokeObjPalette(mem, 100, MakeBgr555(255, 0, 255));     { magenta }
    SeedSolidTile8bpp(mem, 0, 100);
    { Attr0 bit 13 = pal8bpp; tile-base must be even (here, 0 is even). }
    PokeOamAttr(mem, 0,
      THalf(20) or $2000,                              { Y=20, pal8bpp }
      THalf(10),                                       { X=10, 8x8 }
      THalf(0));                                       { tile=0 }
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 10, 20) = $FFFF00FF, '  px(10,20) = magenta');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSprite16x16_1D;
{ 16×16 sprite uses 4 tiles. With 1D mapping (DISPCNT bit 6 = 1), the
  tiles are layed out sequentially: tile-slot 0,1,2,3 cover the four
  8×8 quadrants in row-major. We seed each slot with a different solid
  color and check that screen pixels in each quadrant get the right color. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('SPR-7: 16x16 sprite with 1D tile mapping');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1040);                    { DISPCNT bit 6=1 → 1D }
    SeedSolidTile4bpp(mem, 0, 1);                      { red top-left }
    SeedSolidTile4bpp(mem, 1, 2);                      { green top-right }
    SeedSolidTile4bpp(mem, 2, 3);                      { blue bottom-left }
    SeedSolidTile4bpp(mem, 3, 1);                      { red bottom-right }
    PokeOamAttr(mem, 0,
      THalf(20),                                       { Y=20, shape=0 square }
      THalf(10) or $4000,                              { X=10, size=1 (16x16) }
      THalf(0));
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 10, 20) = $FFFF0000, '  top-left = red');
    Check(GetFramePixel(ppu, 18, 20) = $FF00FF00, '  top-right = green');
    Check(GetFramePixel(ppu, 10, 28) = $FF0000FF, '  bottom-left = blue');
    Check(GetFramePixel(ppu, 18, 28) = $FFFF0000, '  bottom-right = red');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSprite16x16_2D;
{ With 2D mapping, the second tile of a multi-tile sprite at (Tx=1, Ty=0)
  uses tile-slot base+1, but at (Tx=0, Ty=1) uses base+32 (next "row" of
  the 32-wide grid). Seed slots accordingly. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('SPR-8: 16x16 sprite with 2D tile mapping');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1000);                    { DISPCNT bit 6=0 → 2D }
    SeedSolidTile4bpp(mem, 0,  1);                     { red top-left }
    SeedSolidTile4bpp(mem, 1,  2);                     { green top-right }
    SeedSolidTile4bpp(mem, 32, 3);                     { blue bottom-left (row 1, col 0) }
    SeedSolidTile4bpp(mem, 33, 1);                     { red bottom-right }
    PokeOamAttr(mem, 0,
      THalf(20),
      THalf(10) or $4000,                              { 16x16 }
      THalf(0));
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 10, 20) = $FFFF0000, '  top-left = red');
    Check(GetFramePixel(ppu, 18, 20) = $FF00FF00, '  top-right = green');
    Check(GetFramePixel(ppu, 10, 28) = $FF0000FF, '  bottom-left = blue');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSpriteXWrap;
{ Sprite at X=508 (= 240 + 268 wrapped to be off-screen-right, but with
  X mod 512 it shows columns 0..3 mapping to screen x=508..511 (invisible)
  and columns 4..7 mapping to screen x=0..3. So pixels at screen x=0..3
  on the sprite's Y row should be red. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('SPR-9: X-wrap places sprite tail at screen left edge');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1040);
    SeedSolidTile4bpp(mem, 0, 1);
    PokeOamAttr(mem, 0, THalf(20), THalf(508), THalf(0));   { X=508 wraps }
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 0, 20) = $FFFF0000, '  px(0,20) = red (wrapped tail)');
    Check(GetFramePixel(ppu, 3, 20) = $FFFF0000, '  px(3,20) = red (wrapped tail)');
    Check(GetFramePixel(ppu, 4, 20) = $FF000000, '  px(4,20) = backdrop');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSpriteOverlapOamOrder;
{ Two sprites at the same pixel, both priority=0. OAM[0] is red, OAM[1]
  is green. Lower OAM index wins → red. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('SPR-10: lower OAM index wins tied priority');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1040);
    SeedSolidTile4bpp(mem, 0, 1);   { red }
    SeedSolidTile4bpp(mem, 1, 2);   { green }
    PokeOamAttr(mem, 0, THalf(20), THalf(10), THalf(0));   { tile 0 (red) }
    PokeOamAttr(mem, 1, THalf(20), THalf(10), THalf(1));   { tile 1 (green) }
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 10, 20) = $FFFF0000, '  px(10,20) = red (OAM[0] wins)');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSpritePriorityBetweenSprites;
{ Two sprites at same pixel; OAM[0] has priority=2, OAM[1] has priority=0.
  Lower priority number wins → OAM[1]'s green should show even though OAM[0]
  is rendered first. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('SPR-11: lower priority number wins between sprites');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1040);
    SeedSolidTile4bpp(mem, 0, 1);
    SeedSolidTile4bpp(mem, 1, 2);
    PokeOamAttr(mem, 0, THalf(20), THalf(10), THalf(0) or $0800);  { red, pri=2 }
    PokeOamAttr(mem, 1, THalf(20), THalf(10), THalf(1));            { green, pri=0 }
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 10, 20) = $FF00FF00, '  px(10,20) = green (pri=0 wins over pri=2)');
  finally
    ppu.Free; mem.Free;
  end;
end;

{ ───── PPU sprite/BG compositing tests ───────────────────────────── }

procedure SetupBgLayer(mem: TGbaMemory);
{ Enable BG0 in mode 0, fill BG0 with a single tile at every position so
  the entire BG0 region renders solid yellow. }
var
  i: Integer;
begin
  { BG palette index 1 = yellow. }
  PokeBgPalette(mem, 1, MakeBgr555(255, 255, 0));
  { Char block 0 ($06000000), tile 1 — 4bpp solid index 1. }
  for i := 0 to 31 do mem.WriteByte($06000000 + 32 + TWord(i), $11);
  { Screen block 0 ($06000000+$0000) — for size=0 tilemap is at base+0.
    Set BG0 to use screen block 0, char block 0; here we use a different
    screen block to keep char/screen separate. Actually let's use the
    same block since char takes only 32 bytes of slot 0. The tilemap
    starts at $06000800 then so screen base = 1 → 2KB offset. }
  { BG0CNT: priority=2 (so sprites at pri=0,1 cover it), char base=0,
    screen base=1, size=0, 4bpp. }
  mem.WriteHalf($04000008, $0102);     { screen base 1 = $800, priority 2 }
  { Tilemap at $06000800: every entry = tile 1. }
  for i := 0 to 1023 do
    mem.WriteHalf($06000800 + TWord(i) * 2, $0001);
end;

procedure TestSpriteOverBgTiedPriority;
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('PPU-1: sprite at priority=2 covers BG0 at priority=2 (tied → sprite wins)');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1140);   { mode 0 + BG0 enable + OBJ + 1D map }
    SetupBgLayer(mem);
    SeedSolidTile4bpp(mem, 0, 1);
    PokeOamAttr(mem, 0,
      THalf(20),
      THalf(10),
      THalf(0) or $0800);             { priority=2 — tied with BG0 }
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    CheckEq(GetFramePixel(ppu, 10, 20), $FFFF0000, '  px(10,20) = red sprite (wins tied prio)');
    CheckEq(GetFramePixel(ppu,  0,  0), $FFFFFF00, '  px(0,0)   = yellow BG0 (no sprite)');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestBgOverSpriteHigherPriority;
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('PPU-2: BG at priority=0 covers sprite at priority=2');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $1140);
    SetupBgLayer(mem);
    { Re-enable BG0 with priority 0 instead. }
    mem.WriteHalf($04000008, $0100);                  { screen base 1, priority 0 }
    SeedSolidTile4bpp(mem, 0, 1);
    PokeOamAttr(mem, 0, THalf(20), THalf(10), THalf(0) or $0800);  { pri=2 }
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 10, 20) = $FFFFFF00, '  px(10,20) = yellow BG0 covers sprite');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestObjDisableInDispcnt;
var
  mem: TGbaMemory; ppu: TGbaPpu;
  y: Integer;
begin
  Writeln('PPU-3: DISPCNT bit 12=0 suppresses OBJ layer');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    SetupForSpriteTest(mem, $0040);   { OBJ disabled, 1D mapping }
    SeedSolidTile4bpp(mem, 0, 1);
    PokeOamAttr(mem, 0, THalf(20), THalf(10), THalf(0));
    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 10, 20) = $FF000000, '  px(10,20) = backdrop (OBJ disabled)');
  finally
    ppu.Free; mem.Free;
  end;
end;

{ ───── Window tests ──────────────────────────────────────────────── }

procedure TestWin0BgOnly;
{ WIN0 enabled, mask = BG0 only. Inside the rectangle BG0 renders, BG1
  doesn't. Outside, WIN-OUT mask says BG0+BG1 both render. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  i, y: Integer;
begin
  Writeln('WIN-1: WIN0 mask gates BG layers inside the window');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    { Mode 0 + BG0 + BG1 + WIN0. DISPCNT bits 8/9 = BG0/1, 13 = WIN0. }
    mem.WriteHalf($04000000, THalf($2300));
    PokeBgPalette(mem, 0, MakeBgr555(  0,   0,   0));    { backdrop = black }
    PokeBgPalette(mem, 1, MakeBgr555(255, 255,   0));    { yellow for BG0 }
    PokeBgPalette(mem, 2, MakeBgr555(  0, 255, 255));    { cyan for BG1 }

    { BG0 char $11 (4bpp solid pal 1). }
    for i := 0 to 31 do mem.WriteByte($06000000 + 32 + TWord(i), $11);
    { BG1 char $22 (4bpp solid pal 2). }
    for i := 0 to 31 do mem.WriteByte($06000000 + 64 + TWord(i), $22);
    { BG0 tilemap at $06000800: tile 1. BG1 tilemap at $06001000: tile 2. }
    for i := 0 to 1023 do mem.WriteHalf($06000800 + TWord(i) * 2, $0001);
    for i := 0 to 1023 do mem.WriteHalf($06001000 + TWord(i) * 2, $0002);
    mem.WriteHalf($04000008, $0101);                     { BG0CNT: pri=1, screen base 1 }
    mem.WriteHalf($0400000A, $0102);                     { BG1CNT: pri=2, screen base 2 }

    { WIN0: x1=50, x2=100, y1=30, y2=80. }
    mem.WriteHalf($04000040, THalf((50 shl 8) or 100));   { WIN0H }
    mem.WriteHalf($04000044, THalf((30 shl 8) or  80));   { WIN0V }
    mem.WriteHalf($04000048, THalf($0001));               { WININ: WIN0 → BG0 only }
    mem.WriteHalf($0400004A, THalf($0003));               { WINOUT: BG0+BG1 outside }
    mem.WriteHalf($0400000A, $0202);                      { BG1CNT corrected: pri=2, screen base 2 }

    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);

    Check(GetFramePixel(ppu, 60, 50) = $FFFFFF00,
          '  inside WIN0: yellow (BG0 only — BG1 masked off)');
    Check(GetFramePixel(ppu, 10, 10) = $FFFFFF00,
          '  outside WIN0: yellow (BG0 priority 1, beats BG1 priority 2)');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestWin0Outside;
{ Same as above but check that outside-window pixel respects WIN-OUT mask
  showing both BG0 and BG1. With BG0 priority=1 and BG1 priority=2, BG0
  is on top — so outside WIN0 = yellow (BG0). Setting BG0 disabled
  outside would let BG1 show, but for now WIN-OUT enables both so BG0
  still wins. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  i, y: Integer;
begin
  Writeln('WIN-2: WIN-OUT mask gates layers outside windows');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    mem.WriteHalf($04000000, THalf($2300));
    PokeBgPalette(mem, 0, MakeBgr555(  0,   0,   0));
    PokeBgPalette(mem, 1, MakeBgr555(255, 255,   0));
    PokeBgPalette(mem, 2, MakeBgr555(  0, 255, 255));
    for i := 0 to 31 do mem.WriteByte($06000000 + 32 + TWord(i), $11);
    for i := 0 to 31 do mem.WriteByte($06000000 + 64 + TWord(i), $22);
    for i := 0 to 1023 do mem.WriteHalf($06000800 + TWord(i) * 2, $0001);
    for i := 0 to 1023 do mem.WriteHalf($06001000 + TWord(i) * 2, $0002);
    mem.WriteHalf($04000008, $0101);             { BG0CNT pri=1 screen base 1 }
    mem.WriteHalf($0400000A, $0202);             { BG1CNT pri=2 screen base 2 (corrected) }
    mem.WriteHalf($04000040, THalf((50 shl 8) or 100));
    mem.WriteHalf($04000044, THalf((30 shl 8) or  80));
    mem.WriteHalf($04000048, THalf($0001));   { WININ: WIN0 → BG0 only }
    mem.WriteHalf($0400004A, THalf($0002));   { WINOUT: outside → BG1 only }

    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);

    CheckEq(GetFramePixel(ppu, 60, 50), $FFFFFF00,
            '  inside WIN0: yellow (BG0 — BG1 masked)');
    CheckEq(GetFramePixel(ppu, 10, 10), $FF00FFFF,
            '  outside WIN0: cyan (BG1 — BG0 masked by WINOUT)');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestWinObj;
{ WINOBJ enabled. Sprite with mode=2 (window OBJ) defines the region.
  Inside that region, WININ-high (winObjMask) gates layers; outside, the
  WIN-OUT mask applies. Test fixture: WINOBJ shows BG0 only; WIN-OUT
  shows neither. So a region with the window sprite = yellow (BG0),
  everywhere else = backdrop. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  i, y: Integer;
begin
  Writeln('WIN-3: WINOBJ region uses winObjMask, outside uses winOut');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    { Mode 0 + BG0 + OBJ + WINOBJ. DISPCNT bits 8=BG0, 12=OBJ, 15=WINOBJ. }
    mem.WriteHalf($04000000, THalf($9140));
    PokeBgPalette(mem, 0, MakeBgr555(  0,   0,   0));
    PokeBgPalette(mem, 1, MakeBgr555(255, 255,   0));
    PokeObjPalette(mem, 1, MakeBgr555(255, 0, 0));    { not visible — window-mode sprite }

    for i := 0 to 31 do mem.WriteByte($06000000 + 32 + TWord(i), $11);
    for i := 0 to 1023 do mem.WriteHalf($06000800 + TWord(i) * 2, $0001);
    mem.WriteHalf($04000008, $0102);                   { BG0CNT: pri=2, screen base 1 }

    SeedSolidTile4bpp(mem, 0, 1);
    { Sprite 0: mode=2 (window OBJ), at (X=50, Y=50), 8x8. }
    PokeOamAttr(mem, 0,
      THalf(50) or $0800,                              { Y=50, mode=2 (bits 10-11) }
      THalf(50),
      THalf(0));

    { WININ low byte unused (no WIN0/1 active); high byte (winObj) = BG0 only. }
    mem.WriteHalf($04000048, $0000);
    { WINOUT: low byte = nothing outside; high byte = winObjMask = $0001 = BG0. }
    mem.WriteHalf($0400004A, THalf($0100));

    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);

    Check(GetFramePixel(ppu, 53, 53) = $FFFFFF00,
          '  inside WINOBJ sprite: yellow BG0');
    Check(GetFramePixel(ppu, 10, 10) = $FF000000,
          '  outside (WIN-OUT mask = 0): backdrop only');
  finally
    ppu.Free; mem.Free;
  end;
end;

{ ───── Blending tests ────────────────────────────────────────────── }

procedure TestBrightenFullEvy;
{ Mode 2 brighten with EVY=16 — target1 pixels go full white. Set BG0
  to red, BLDCNT.target1 = BG0, EVY=16. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  i, y: Integer;
begin
  Writeln('BLD-1: brighten mode 2 with EVY=16 → target1 → white');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    mem.WriteHalf($04000000, $0100);
    PokeBgPalette(mem, 0, MakeBgr555(0, 0, 0));
    PokeBgPalette(mem, 1, MakeBgr555(255, 0, 0));      { red }
    for i := 0 to 31 do mem.WriteByte($06000000 + 32 + TWord(i), $11);
    for i := 0 to 1023 do mem.WriteHalf($06000800 + TWord(i) * 2, $0001);
    mem.WriteHalf($04000008, $0100);                   { BG0CNT pri=0 screen base 1 }
    { BLDCNT: target1=BG0 (bit 0=1), mode=brighten (bits 6:7 = 10 = 2). }
    mem.WriteHalf($04000050, THalf($0081));
    { BLDY: EVY=16. }
    mem.WriteHalf($04000054, $0010);

    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 0, 0) = $FFFFFFFF, '  BG0 pixel → white after brighten');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestDarkenFullEvy;
var
  mem: TGbaMemory; ppu: TGbaPpu;
  i, y: Integer;
begin
  Writeln('BLD-2: darken mode 3 with EVY=16 → target1 → black');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    mem.WriteHalf($04000000, $0100);
    PokeBgPalette(mem, 0, MakeBgr555(255, 255, 255));    { backdrop white }
    PokeBgPalette(mem, 1, MakeBgr555(255, 0, 0));        { red }
    for i := 0 to 31 do mem.WriteByte($06000000 + 32 + TWord(i), $11);
    for i := 0 to 1023 do mem.WriteHalf($06000800 + TWord(i) * 2, $0001);
    mem.WriteHalf($04000008, $0100);
    { BLDCNT: target1=BG0, mode=darken (bits 6:7 = 11 = 3). }
    mem.WriteHalf($04000050, THalf($00C1));
    mem.WriteHalf($04000054, $0010);

    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    Check(GetFramePixel(ppu, 0, 0) = $FF000000, '  BG0 pixel → black after darken');
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestBrightenSkipsNonTarget;
{ BG0 is target1, but BG1 is not. With BG1 on top (priority 0) and BG0
  priority 1, the visible pixel is BG1 (cyan) — which should NOT be
  affected by brighten because it's not target1. }
var
  mem: TGbaMemory; ppu: TGbaPpu;
  i, y: Integer;
begin
  Writeln('BLD-3: brighten skips non-target1 pixels');
  mem := TGbaMemory.Create; ppu := TGbaPpu.Create(mem);
  try
    mem.WriteHalf($04000000, $0300);                   { BG0 + BG1 + mode 0 }
    PokeBgPalette(mem, 0, MakeBgr555(0, 0, 0));
    PokeBgPalette(mem, 1, MakeBgr555(255, 0, 0));      { BG0 red (sub-pal 1) }
    PokeBgPalette(mem, 2, MakeBgr555(0, 255, 255));    { BG1 cyan (sub-pal 2) }
    for i := 0 to 31 do mem.WriteByte($06000000 + 32 + TWord(i), $11);
    for i := 0 to 31 do mem.WriteByte($06000000 + 64 + TWord(i), $22);
    for i := 0 to 1023 do mem.WriteHalf($06000800 + TWord(i) * 2, $0001);
    for i := 0 to 1023 do mem.WriteHalf($06001000 + TWord(i) * 2, $0002);
    mem.WriteHalf($04000008, $0101);                   { BG0 pri=1 screen base 1 }
    mem.WriteHalf($0400000A, $0200);                   { BG1 pri=0 screen base 2 (corrected) }
    mem.WriteHalf($04000050, THalf($0081));            { target1=BG0 only, mode=brighten }
    mem.WriteHalf($04000054, $0010);

    for y := 0 to GBA_HEIGHT - 1 do ppu.RenderScanline(y);
    CheckEq(GetFramePixel(ppu, 0, 0), $FF00FFFF, '  BG1 cyan unchanged (not target1)');
  finally
    ppu.Free; mem.Free;
  end;
end;

begin
  pass := 0; fail := 0;
  Writeln('=== Phase E acceptance tests ===');

  TestSpriteBasic;
  TestSpriteHFlip;
  TestSpriteVFlip;
  TestSpriteOutsideScanline;
  TestSpriteDisable;
  TestSprite8Bpp;
  TestSprite16x16_1D;
  TestSprite16x16_2D;
  TestSpriteXWrap;
  TestSpriteOverlapOamOrder;
  TestSpritePriorityBetweenSprites;

  TestSpriteOverBgTiedPriority;
  TestBgOverSpriteHigherPriority;
  TestObjDisableInDispcnt;

  TestWin0BgOnly;
  TestWin0Outside;
  TestWinObj;

  TestBrightenFullEvy;
  TestDarkenFullEvy;
  TestBrightenSkipsNonTarget;

  Writeln;
  Writeln(Format('=== Phase E summary: %d passed, %d failed ===', [pass, fail]));
  if fail > 0 then Halt(1);
end.
