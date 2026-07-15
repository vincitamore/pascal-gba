unit Sprites;
{
  GBA sprite (OBJ) rendering — Object Attribute Memory at $07000000.

  ── OAM layout ──

  128 sprites, each occupying 8 bytes (the OAM region is 1 KB; the last
  half of each 8-byte slot is interleaved affine-matrix data, accessed via
  separate offset arithmetic — see Affine section below).

    Attr0 (halfword at OAM[i*8 + 0]):
      bits 0-7    Y coord (unsigned 0-255; values >159 are off-screen-bottom
                   or wrap-around — see Y-wrap discussion below)
      bit 8       Rotation/scaling enable (affine flag — 1=affine sprite)
      bit 9       If affine=0: Disable bit (1=hidden).
                  If affine=1: Double-size bounding box.
      bits 10-11  Mode (0=normal, 1=alpha-blend object, 2=window object,
                   3=prohibited)
      bit 12      Mosaic enable
      bit 13      Palette mode (0=4bpp/16-color subpalette, 1=8bpp/256-color)
      bits 14-15  Shape (0=square, 1=horizontal-wide, 2=vertical-tall)

    Attr1 (halfword at OAM[i*8 + 2]):
      bits 0-8    X coord (unsigned 0-511; off-screen-left expressed as
                   X≥256 conceptually — see X-wrap discussion below)
      bits 9-13   If affine=0: bit 12 = HFlip, bit 13 = VFlip
                  If affine=1: 5-bit affine-parameter-block index (0..31)
      bits 14-15  Size (combined with Shape: see SHAPE_SIZE table below)

    Attr2 (halfword at OAM[i*8 + 4]):
      bits 0-9    Tile-base index (in 32-byte slots; 8bpp consumes 2 slots
                   per visible tile, so 8bpp sprites must use even tile_base)
      bits 10-11  Priority
      bits 12-15  Palette bank (4bpp only)

  ── Shape × Size → pixel dimensions ──

    Shape\Size   0       1        2        3
    0 (square)   8×8     16×16    32×32    64×64
    1 (horiz)    16×8    32×8     32×16    64×32
    2 (vert)     8×16    8×32     16×32    32×64

  ── X/Y coordinate wrap ──

  Both X and Y are intentionally narrow (8 and 9 bits) so a sprite can be
  positioned partially off-screen by wrapping. Convention used here matches
  mGBA / real hardware:

    Y: 8-bit unsigned. A sprite at Y=240 with height=32 is logically at
       screen-rows 240..255, 0..15. We render rows 0..15 (the visible-on-
       screen portion of the wrap). The test (scanline - Y) mod 256 < H
       captures this — `<H` includes wrap-around because mod 256 wraps the
       difference.

    X: 9-bit unsigned (0..511). A sprite at X=496 with width=32 occupies
       screen-cols 496..511, 0..15 → only cols 0..15 are on-screen-visible.
       Same wrap-aware test: for screen_x in 0..239, check if there's a
       sprite column at (screen_x - X) mod 512 < W. The trick: for sprites
       partially off-screen-left (X=500..511 area), the wrap puts the
       sprite's last few cols on-screen-left.

  ── Tile mapping (DISPCNT bit 6) ──

    0 = 2D mapping: sprite tile sheet treated as a 32-tile-wide grid.
                    tile(Tx, Ty) within sprite uses tile-slot
                    (base + Ty*32 + Tx)  [4bpp]
                    (base + Ty*32 + Tx*2) [8bpp; tile-slot units]
    1 = 1D mapping: sprite tiles laid out sequentially.
                    tile(Tx, Ty) uses tile-slot
                    (base + Ty*spriteTileW + Tx)        [4bpp]
                    (base + Ty*spriteTileW*2 + Tx*2)    [8bpp]

  ── Tile data location ──

  OBJ tile data lives at $06010000–$06017FFF (32 KB) in tile modes 0/1/2.
  Tile-slot index N is at offset N * 32 within this region.
  (In bitmap modes 3/4/5 only slots 512..1023 are available because the
  lower 16 KB overlaps the bitmap — not relevant for our current focus.)

  ── Output protocol ──

  RenderScanline writes into the caller-provided TSpriteScanline buffer
  (240 entries). Each entry holds Color (ARGB), Priority, Mode (for
  blending), and Opaque flag. The PPU composites this with its BG-walk
  respecting per-pixel priority.

  Multiple sprites can overlap; the lowest OAM index wins at tied priority,
  matching real hardware. We iterate OAM 0→127 and write a pixel only if
  the current entry is transparent OR the new sprite has strictly higher
  priority. (Higher priority = lower number, so "new pri < current pri".)

  ── Status (Phase E session 8, 2026-05-18) ──

  Shipped this session:
    [x] All 12 size/shape combinations
    [x] 2D + 1D tile mapping
    [x] 4bpp + 8bpp palette modes
    [x] HFlip / VFlip (regular sprites)
    [x] Disable bit
    [x] X/Y wrap-around for partially-off-screen sprites
    [x] Priority pass-through to caller
    [x] Mode tracking (normal / blend / window — flagged to caller; the
        actual blend/window handling lives in PPU)

  Deferred:
    [ ] Affine sprites (Phase E.5). The affine flag is recognized; affine
        sprites currently render as if regular (using the rotation-center
        cell of the matrix). This produces a slightly wrong result for
        rotated sprites but doesn't crash. Typical splash screens use
        few/no affine.
    [ ] Mosaic (post-capstone; typical commercial splash screens skip it)
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes, Memory;

const
  GBA_WIDTH_E   = 240;
  GBA_HEIGHT_E  = 160;

  OAM_BASE      = $07000000;
  OBJ_VRAM_BASE = $06010000;
  OBJ_PAL_BASE  = $05000200;     { OBJ palette: second half of palette RAM }

  REG_DISPCNT_E = $04000000;

  SPRITE_MODE_NORMAL = 0;
  SPRITE_MODE_BLEND  = 1;
  SPRITE_MODE_WINDOW = 2;

type
  TSpritePixel = record
    Color:    TWord;
    Priority: Byte;
    Mode:     Byte;
    Opaque:   Boolean;
  end;

  TSpriteScanline = array[0 .. GBA_WIDTH_E - 1] of TSpritePixel;
  PSpriteScanline = ^TSpriteScanline;

  TGbaSprites = class
  private
    FMem: TGbaMemory;

    function  ReadOamHalf(idx, attrOffset: Integer): THalf; inline;
    function  ReadObjPalette(palIndex: Integer): TWord; inline;
    function  BgrToArgb(bgr555: THalf): TWord; inline;

    procedure RenderRegularSprite(spriteIdx, scanline: Integer;
                                   var outBuf: TSpriteScanline;
                                   tileMap1D: Boolean);
  public
    constructor Create(mem: TGbaMemory);

    { Clear the output buffer (all transparent) and rasterize every visible
      sprite's contribution to this scanline. }
    procedure RenderScanline(scanline: Integer; var outBuf: TSpriteScanline);
  public
    { Diagnostic — count of sprites that contributed at least one pixel
      to the last RenderScanline call. Useful for tests. Separate public
      block because Pascal requires fields to precede methods within one
      visibility section (same constraint as TGbaDma.TransferCount). }
    LastSpritesRendered: Integer;
  end;

{ Helper used by tests to populate OAM entries cleanly. Public utility
  so test fixtures and (eventually) BIOS HLE OAM-reset routines can share. }
procedure PokeOamAttr(mem: TGbaMemory; idx: Integer; a0, a1, a2: THalf);

implementation

const
  { SHAPE_W[shape, size] / SHAPE_H[shape, size] in pixels. }
  SHAPE_W: array[0..2, 0..3] of Integer = (
    ( 8, 16, 32, 64),   { shape 0: square }
    (16, 32, 32, 64),   { shape 1: horizontal }
    ( 8,  8, 16, 32)    { shape 2: vertical }
  );
  SHAPE_H: array[0..2, 0..3] of Integer = (
    ( 8, 16, 32, 64),   { shape 0: square }
    ( 8,  8, 16, 32),   { shape 1: horizontal }
    (16, 32, 32, 64)    { shape 2: vertical }
  );

procedure PokeOamAttr(mem: TGbaMemory; idx: Integer; a0, a1, a2: THalf);
var
  base: TWord;
begin
  base := OAM_BASE + TWord(idx) * 8;
  mem.WriteHalf(base + 0, a0);
  mem.WriteHalf(base + 2, a1);
  mem.WriteHalf(base + 4, a2);
  { OAM[i*8 + 6] is affine-matrix-element storage (shared across sprite
    slots in groups of 4); leave as-is for the regular-sprite case. }
end;

constructor TGbaSprites.Create(mem: TGbaMemory);
begin
  inherited Create;
  FMem := mem;
  LastSpritesRendered := 0;
end;

function TGbaSprites.ReadOamHalf(idx, attrOffset: Integer): THalf; inline;
begin
  Result := FMem.ReadHalf(OAM_BASE + TWord(idx) * 8 + TWord(attrOffset));
end;

function TGbaSprites.BgrToArgb(bgr555: THalf): TWord; inline;
var
  r5, g5, b5: TWord;
  r8, g8, b8: TWord;
begin
  r5 :=  TWord(bgr555)         and $1F;
  g5 := (TWord(bgr555) shr 5)  and $1F;
  b5 := (TWord(bgr555) shr 10) and $1F;
  r8 := (r5 shl 3) or (r5 shr 2);
  g8 := (g5 shl 3) or (g5 shr 2);
  b8 := (b5 shl 3) or (b5 shr 2);
  Result := $FF000000 or (r8 shl 16) or (g8 shl 8) or b8;
end;

function TGbaSprites.ReadObjPalette(palIndex: Integer): TWord; inline;
{ Read OBJ palette entry palIndex (0..255), return ARGB. Index 0 of any
  sub-palette = transparent; caller checks. The OBJ palette occupies
  bytes 512..1023 of palette RAM (entries 256..511 in global index space,
  but we keep this routine's input range as 0..255 for OBJ-local indexing). }
var
  raw: THalf;
begin
  raw := FMem.ReadHalf(OBJ_PAL_BASE + TWord(palIndex) * 2);
  Result := BgrToArgb(raw);
end;

procedure TGbaSprites.RenderRegularSprite(spriteIdx, scanline: Integer;
                                            var outBuf: TSpriteScanline;
                                            tileMap1D: Boolean);
{ Rasterize sprite N's contribution to the given scanline.

  Wrap-aware Y test: (scanline - Y) mod 256 < spriteH lets us handle
  sprites whose Y wraps from e.g. 240..255 onto 0..15. Same for X mod 512.

  Pixel writing uses "priority replaces" semantics: a new pixel overwrites
  outBuf[x] iff outBuf[x] is transparent OR the new pixel has strictly
  lower priority number. This handles intra-scanline sprite overlap
  correctly (lower OAM index wins at tied priority because we iterate
  0→127 and only-strictly-better overwrites). }
var
  a0, a1, a2: THalf;
  isAffine: Boolean;
  disable:  Boolean;
  shape, size: Integer;
  spriteW, spriteH: Integer;
  spriteTileW, spriteTileH: Integer;
  yCoord, xCoord: Integer;
  rowInSprite: Integer;
  hflip, vflip: Boolean;
  pal8bpp: Boolean;
  mode: Integer;
  baseTile: Integer;
  priority: Integer;
  palBank: Integer;

  effRow, effCol: Integer;
  tileX, tileY:   Integer;
  pixX, pixY:     Integer;
  tileSlot:       Integer;
  tileAddr:       TWord;
  pixByte:        TByte;
  palIdx:         Integer;
  finalPalIdx:    Integer;
  color:          TWord;

  col, screenX: Integer;
  hadPixel:     Boolean;
begin
  a0 := ReadOamHalf(spriteIdx, 0);
  a1 := ReadOamHalf(spriteIdx, 2);
  a2 := ReadOamHalf(spriteIdx, 4);

  isAffine := ((a0 shr 8) and 1) = 1;
  disable  := (not isAffine) and (((a0 shr 9) and 1) = 1);
  if disable then Exit;

  shape   := (a0 shr 14) and $3;
  size    := (a1 shr 14) and $3;
  if (shape > 2) then Exit;        { shape 3 prohibited }
  spriteW := SHAPE_W[shape, size];
  spriteH := SHAPE_H[shape, size];
  spriteTileW := spriteW shr 3;
  spriteTileH := spriteH shr 3;
  if spriteTileH = 0 then ;        { silence unused — used in 2D-affine work later }

  yCoord := a0 and $FF;
  xCoord := a1 and $1FF;

  { Y test: visible row 0..spriteH-1 within sprite that maps to `scanline`. }
  rowInSprite := (scanline - yCoord) and $FF;   { mod 256 }
  if rowInSprite >= spriteH then Exit;

  hflip := (not isAffine) and (((a1 shr 12) and 1) = 1);
  vflip := (not isAffine) and (((a1 shr 13) and 1) = 1);
  pal8bpp := ((a0 shr 13) and 1) = 1;
  mode    := (a0 shr 10) and $3;

  baseTile := a2 and $3FF;
  priority := (a2 shr 10) and $3;
  palBank  := (a2 shr 12) and $F;

  if vflip then effRow := spriteH - 1 - rowInSprite
           else effRow := rowInSprite;
  tileY := effRow shr 3;
  pixY  := effRow and 7;

  hadPixel := False;

  for col := 0 to spriteW - 1 do
  begin
    screenX := (xCoord + col) and $1FF;   { mod 512 }
    if screenX >= GBA_WIDTH_E then Continue;

    if hflip then effCol := spriteW - 1 - col
             else effCol := col;
    tileX := effCol shr 3;
    pixX  := effCol and 7;

    { Resolve tile-slot index for tile (tileX, tileY) within the sprite. }
    if tileMap1D then
    begin
      if pal8bpp then
        tileSlot := baseTile + tileY * spriteTileW * 2 + tileX * 2
      else
        tileSlot := baseTile + tileY * spriteTileW + tileX;
    end
    else
    begin
      { 2D mapping — fixed 32-tile-wide grid in the OBJ tile-data region. }
      if pal8bpp then
        tileSlot := baseTile + tileY * 32 + tileX * 2
      else
        tileSlot := baseTile + tileY * 32 + tileX;
    end;
    tileSlot := tileSlot and $3FF;

    tileAddr := OBJ_VRAM_BASE + TWord(tileSlot) * 32;

    if pal8bpp then
    begin
      { 8 bytes per row, 1 byte per pixel. }
      pixByte := FMem.ReadByte(tileAddr + TWord(pixY) * 8 + TWord(pixX));
      palIdx := pixByte;
      if palIdx = 0 then Continue;
      finalPalIdx := palIdx;
    end
    else
    begin
      { 4 bytes per row, 2 pixels per byte. }
      pixByte := FMem.ReadByte(tileAddr + TWord(pixY) * 4 + TWord(pixX shr 1));
      if (pixX and 1) = 0 then
        palIdx := pixByte and $F
      else
        palIdx := (pixByte shr 4) and $F;
      if palIdx = 0 then Continue;
      finalPalIdx := palBank * 16 + palIdx;
    end;

    color := ReadObjPalette(finalPalIdx);

    { Priority-aware write. Lower priority number wins; ties go to the
      first writer (we iterate OAM 0→127). }
    if (not outBuf[screenX].Opaque) or (priority < outBuf[screenX].Priority) then
    begin
      outBuf[screenX].Color    := color;
      outBuf[screenX].Priority := priority;
      outBuf[screenX].Mode     := mode;
      outBuf[screenX].Opaque   := True;
      hadPixel := True;
    end;
  end;

  if hadPixel then Inc(LastSpritesRendered);
end;

procedure TGbaSprites.RenderScanline(scanline: Integer; var outBuf: TSpriteScanline);
var
  i: Integer;
  dispcnt: THalf;
  objEnable: Boolean;
  tileMap1D: Boolean;
begin
  for i := 0 to GBA_WIDTH_E - 1 do
  begin
    outBuf[i].Color    := 0;
    outBuf[i].Priority := 4;       { higher than any valid (0-3) → "no pixel" }
    outBuf[i].Mode     := SPRITE_MODE_NORMAL;
    outBuf[i].Opaque   := False;
  end;
  LastSpritesRendered := 0;

  dispcnt := FMem.ReadHalf(REG_DISPCNT_E);
  objEnable := ((dispcnt shr 12) and 1) = 1;
  if not objEnable then Exit;

  tileMap1D := ((dispcnt shr 6) and 1) = 1;

  for i := 0 to 127 do
    RenderRegularSprite(i, scanline, outBuf, tileMap1D);
end;

end.
