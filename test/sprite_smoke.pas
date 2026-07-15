program sprite_smoke;
{
  Host-side OBJ sprite smoke test - renders a baked sprite animation through the
  emulator's REAL PPU OBJ path, exactly the OBJ code path commercial games exercise. No ARM,
  no ROM: we poke OBJ palette + tile VRAM + OAM + DISPCNT directly (same technique
  as hello_gba.pas for BG), then dump one PPM per animation frame.

  Generic: consumes `{$I sprite_input.inc}` with canonical SPRITE_* names so
  driving any baked .inc through this harness is just `assets/sprite.py emulate`
  staging a renamed copy at the include path. Supports both byte orders:

    SPRITE_OBJ_ORDER = 1  -> tile bytes already in GBA 8x8-tile / 1D-mapping order;
                            copy directly to OBJ VRAM (the canonical bake path).
    SPRITE_OBJ_ORDER = 0  -> linear scanline order; transpose into tile order here.

  Hardware OBJ sizes are 8/16/32/64 per axis. shape: 0=square, 1=wide, 2=tall;
  size 0..3 per the GBA table -- derived from SPRITE_W/SPRITE_H automatically.

  Output: bin/sprite_f0.ppm .. bin/sprite_fN-1.ppm (one per frame).
}
{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, Memory, Ppu;

{$I sprite_input.inc}

const
  OBJ_PAL     = $05000200;  { sprite palette bank 0 (16 entries for 4bpp) }
  OBJ_VRAM    = $06010000;  { object character data base }
  OAM         = $07000000;
  REG_DISPCNT = $04000000;
  BG_BACKDROP = $05000000;  { BG palette[0] = backdrop colour }

{ Pixel-index extractor for SCANLINE-ordered tile data. Only called when
  SPRITE_OBJ_ORDER = 0. Returns the 4-bit palette index of pixel (x,y) of frame f. }
function PixelIndexLinear(f, x, y: Integer): Byte;
var
  pixelNo, byteIdx: Integer;
  b: Byte;
begin
  pixelNo := y * SPRITE_W + x;
  byteIdx := f * (SPRITE_W * SPRITE_H div 2) + (pixelNo div 2);
  b := SPRITE_TILES[byteIdx];
  if (x and 1) = 0 then
    Result := b and $0F
  else
    Result := (b shr 4) and $0F;
end;

{ Copy frame f's tile bytes into OBJ VRAM. Branches on SPRITE_OBJ_ORDER:
  - OBJ-order data: copy bytes verbatim (the bake already laid them out for VRAM).
  - linear data:    reshape into 8x8-tile order, then write.
  Output addressing assumes 1D mapping (DISPCNT bit 6 = 1). }
procedure LoadFrameTiles(mem: TGbaMemory; f: Integer);
var
  buf: array[0 .. (64 * 64 div 2) - 1] of Byte;
  frameBytes, i, x, y, tx, ty, tileNo, row, col, byteOff: Integer;
  hw: THalf;
  base: TWord;
begin
  frameBytes := SPRITE_W * SPRITE_H div 2;
  base := OBJ_VRAM + TWord(f) * TWord(frameBytes);
  if SPRITE_OBJ_ORDER <> 0 then
  begin
    i := 0;
    while i < frameBytes do
    begin
      hw := THalf(SPRITE_TILES[f * frameBytes + i]) or
            (THalf(SPRITE_TILES[f * frameBytes + i + 1]) shl 8);
      mem.WriteHalf(base + TWord(i), hw);
      Inc(i, 2);
    end;
  end
  else
  begin
    FillChar(buf, SizeOf(buf), 0);
    for y := 0 to SPRITE_H - 1 do
      for x := 0 to SPRITE_W - 1 do
      begin
        tx := x div 8;  ty := y div 8;
        tileNo := ty * (SPRITE_W div 8) + tx;
        row := y mod 8;  col := x mod 8;
        byteOff := tileNo * 32 + row * 4 + (col div 2);
        if (col and 1) = 0 then
          buf[byteOff] := buf[byteOff] or PixelIndexLinear(f, x, y)
        else
          buf[byteOff] := buf[byteOff] or (PixelIndexLinear(f, x, y) shl 4);
      end;
    i := 0;
    while i < frameBytes do
    begin
      hw := THalf(buf[i]) or (THalf(buf[i + 1]) shl 8);
      mem.WriteHalf(base + TWord(i), hw);
      Inc(i, 2);
    end;
  end;
end;

{ Derive OAM[0] shape+size from the baked W/H and center the sprite on screen.
  GBA OBJ size table:
    shape 0 (square): size 0..3 -> 8x8, 16x16, 32x32, 64x64
    shape 1 (wide)  : size 0..3 -> 16x8, 32x8, 32x16, 64x32
    shape 2 (tall)  : size 0..3 -> 8x16, 8x32, 16x32, 32x64 }
procedure ConfigObj(mem: TGbaMemory);
var
  shape, size, x, y: Integer;
begin
  shape := 0; size := 0;
  if SPRITE_W = SPRITE_H then
  begin
    shape := 0;
    case SPRITE_W of  8: size := 0; 16: size := 1; 32: size := 2; else size := 3; end;
  end
  else if SPRITE_W > SPRITE_H then
  begin
    shape := 1;
    if SPRITE_W = 64 then size := 3
    else if SPRITE_H = 16 then size := 2
    else if SPRITE_W = 32 then size := 1
    else size := 0;
  end
  else
  begin
    shape := 2;
    if SPRITE_H = 64 then size := 3
    else if SPRITE_W = 16 then size := 2
    else if SPRITE_H = 32 then size := 1
    else size := 0;
  end;
  x := (240 - SPRITE_W) div 2;
  y := (160 - SPRITE_H) div 2;
  mem.WriteHalf(OAM + 0, THalf(y and $FF) or THalf(shape shl 14));
  mem.WriteHalf(OAM + 2, THalf(x and $1FF) or THalf(size shl 14));
  mem.WriteHalf(OAM + 4, $0000);
end;

procedure Setup(mem: TGbaMemory);
var
  i: Integer;
begin
  { Backdrop = dark slate so transparent pixels read clearly. }
  mem.WriteHalf(BG_BACKDROP, THalf((6 shl 10) or (6 shl 5) or 4));
  { OBJ palette bank 0. }
  for i := 0 to High(SPRITE_PAL) do
    mem.WriteHalf(OBJ_PAL + TWord(i) * 2, THalf(SPRITE_PAL[i]));
  { All frames into VRAM (frame f at byte base f * frameBytes). }
  for i := 0 to SPRITE_FRAMES - 1 do
    LoadFrameTiles(mem, i);
  { Hide all 128 OAM slots before configuring OAM[0]. Without this, OAM[1..127]
    default to attr0=0 -> position (0,0), 8x8 square, tile 0, NOT hidden -- so
    127 phantom sprites render at (0,0) using the active sprite's first 8x8 tile.
    The visible artifact is faction-colored junk in the upper-left corner.
    Bit 9 of attr0 is the hide flag when rotation/scale (bit 8) is off. }
  for i := 0 to 127 do
    mem.WriteHalf(OAM + TWord(i) * 8, THalf($0200));
  ConfigObj(mem);
  { DISPCNT: OBJ enable (bit 12) + 1D mapping (bit 6). }
  mem.WriteHalf(REG_DISPCNT, $1040);
end;

var
  mem: TGbaMemory;
  gpu: TGbaPpu;
  f, tilesPerFrame: Integer;
begin
  Writeln('sprite_smoke: ', SPRITE_FRAMES, ' frames of ',
          SPRITE_W, 'x', SPRITE_H, ' OBJ sprite, obj_order=',
          SPRITE_OBJ_ORDER);
  mem := TGbaMemory.Create;
  gpu := TGbaPpu.Create(mem);
  try
    Setup(mem);
    tilesPerFrame := (SPRITE_W div 8) * (SPRITE_H div 8);
    for f := 0 to SPRITE_FRAMES - 1 do
    begin
      mem.WriteHalf(OAM + 4, THalf(f * tilesPerFrame));  { attr2 = tile base }
      gpu.RenderFrame;
      gpu.DumpPpm(Format('bin/sprite_f%d.ppm', [f]));
      Writeln('  frame ', f, ' -> bin/sprite_f', f, '.ppm');
    end;
  finally
    gpu.Free;
    mem.Free;
  end;
  Writeln('done.');
end.
