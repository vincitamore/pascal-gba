unit Kit_Bg;
{
  Text-BG (mode 0/1) setup, bg-bake asset loading, and scrolling.

  Consumes the asset pipeline's bg-bake .inc format: <NAME>_TILES (4bpp,
  linear within each 8x8 tile), <NAME>_MAP (row-major MAP_W x MAP_H
  entries carrying tile index, flip bits, and palette-bank bits) and
  <NAME>_PAL (one compact palette, or PAL_BANKS contiguous 16-slot
  banks). Typical scene init for a wide scrolling background:

    BgLoadPalette(PLAZA_PAL);
    BgLoadTiles(0, 0, PLAZA_TILES);
    BgLoadMap(8, PLAZA_MAP, PLAZA_MAP_W, PLAZA_MAP_H, 64);
    BgControl(0, 0, 8, BG_SIZE_64x32, 0);
    BgSetMode(0, DISP_BG0 or DISP_OBJ or DISP_OBJ_1D);
    ...
    BgScroll(0, camX, 0);      per frame

  Charblocks and screenblocks share the same 64 KB of BG VRAM: charblock
  N starts at 16 KB * N, screenblock N at 2 KB * N. A 4bpp charblock
  holds 512 tiles; keep tile data and maps from overlapping (tiles in
  charblock 0 run up to screenblock 7, so screenblocks 8+ are safe with
  a single charblock of art).

  All VRAM stores are halfword writes -- byte writes to VRAM corrupt the
  adjacent pixel (hardware quirk).
}

{$mode objfpc}{$H+}

interface

const
  { DISPCNT layer/mode flags for BgSetMode. }
  DISP_BG0    = $0100;
  DISP_BG1    = $0200;
  DISP_BG2    = $0400;
  DISP_BG3    = $0800;
  DISP_OBJ    = $1000;
  DISP_OBJ_1D = $0040;

  { BGxCNT size field (text BGs). }
  BG_SIZE_32x32 = 0;    { 256 x 256 px }
  BG_SIZE_64x32 = 1;    { 512 x 256 px }
  BG_SIZE_32x64 = 2;    { 256 x 512 px }
  BG_SIZE_64x64 = 3;    { 512 x 512 px }

{ DISPCNT := mode or flags. Mode 0 = four text BGs. }
procedure BgSetMode(mode, flags: Word);

{ Configure BGx (0..3) as a 4bpp text BG: character base block (0..3),
  screen base block (0..31), size (BG_SIZE_*), priority (0..3, 0 front). }
procedure BgControl(bg, charBase, screenBase, size, prio: Integer);

{ Copy a whole PAL array into BG palette RAM starting at slot 0.
  Multi-bank bg-bake palettes are laid out as contiguous 16-slot banks,
  so one call lands every bank at its hardware offset. }
procedure BgLoadPalette(const pal: array of Word);

{ Copy a PAL array into one 16-slot BG palette bank (0..15) -- for a
  second asset sharing the screen, e.g. a font on its own bank. }
procedure BgLoadPaletteBank(bank: Integer; const pal: array of Word);

{ Copy tile data into a charblock, starting at tile index `firstTile`.
  Data length must be a multiple of 32 (one 4bpp 8x8 tile). }
procedure BgLoadTiles(charBase, firstTile: Integer; const tiles: array of Byte);

{ Lay a row-major mapW x mapH entry array into the screenblock(s) of a
  text BG that is `bgTilesW` tiles wide (32 or 64). A 64-wide BG splits
  columns 0..31 / 32..63 across screenblock pairs base / base+1 (the
  hardware's screenblock stride). Cells outside the map are zeroed. }
procedure BgLoadMap(screenBase: Integer; const map_: array of Word;
                    mapW, mapH, bgTilesW: Integer);

{ Write BGx scroll registers (write-only). x/y wrap in hardware. }
procedure BgScroll(bg, x, y: Integer);

implementation

const
  REG_DISPCNT = $04000000;
  REG_BG0CNT  = $04000008;
  REG_BG0HOFS = $04000010;
  BG_PAL_RAM  = $05000000;
  VRAM_BASE   = $06000000;

procedure BgSetMode(mode, flags: Word);
begin
  PWord(REG_DISPCNT)^ := mode or flags;
end;

procedure BgControl(bg, charBase, screenBase, size, prio: Integer);
begin
  if (bg < 0) or (bg > 3) then Exit;
  PWord(REG_BG0CNT + bg * 2)^ :=
    Word(prio and 3) or
    Word((charBase and 3) shl 2) or
    Word((screenBase and 31) shl 8) or
    Word((size and 3) shl 14);
end;

procedure BgLoadPalette(const pal: array of Word);
var
  k: Integer;
begin
  for k := 0 to High(pal) do
    PWord(BG_PAL_RAM + k * 2)^ := pal[k];
end;

procedure BgLoadPaletteBank(bank: Integer; const pal: array of Word);
var
  k: Integer;
begin
  for k := 0 to High(pal) do
  begin
    if k > 15 then Exit;
    PWord(BG_PAL_RAM + (bank and 15) * 32 + k * 2)^ := pal[k];
  end;
end;

procedure BgLoadTiles(charBase, firstTile: Integer; const tiles: array of Byte);
var
  base: LongWord;
  k: Integer;
begin
  base := VRAM_BASE + LongWord(charBase and 3) * $4000 +
          LongWord(firstTile) * 32;
  k := 0;
  while k + 1 <= High(tiles) do
  begin
    PWord(base + LongWord(k))^ := Word(tiles[k]) or (Word(tiles[k + 1]) shl 8);
    Inc(k, 2);
  end;
end;

procedure BgLoadMap(screenBase: Integer; const map_: array of Word;
                    mapW, mapH, bgTilesW: Integer);
var
  x, y, sb: Integer;
  entry: Word;
  addr: LongWord;
begin
  if bgTilesW <> 64 then bgTilesW := 32;
  for y := 0 to 31 do
    for x := 0 to bgTilesW - 1 do
    begin
      if (x < mapW) and (y < mapH) then
        entry := map_[y * mapW + x]
      else
        entry := 0;
      sb := screenBase + (x shr 5);            { 64-wide: right half in base+1 }
      addr := VRAM_BASE + LongWord(sb and 31) * $800 +
              LongWord((y * 32 + (x and 31)) * 2);
      PWord(addr)^ := entry;
    end;
end;

procedure BgScroll(bg, x, y: Integer);
begin
  if (bg < 0) or (bg > 3) then Exit;
  PWord(REG_BG0HOFS + bg * 4)^     := Word(x);
  PWord(REG_BG0HOFS + bg * 4 + 2)^ := Word(y);
end;

end.
