unit Ppu;
{
  GBA Picture Processing Unit — scanline-based renderer for tilemap modes.

  ── Output ──

  240 × 160 pixel framebuffer in 32-bit ARGB (TWord). The high byte (A)
  is always $FF on opaque pixels — Win32's StretchBlt ignores alpha but
  keeping the byte set makes the buffer drop-in usable for surfaces that
  do care (Direct2D, etc., if we ever rewrite the display path).

  ── Tile modes (modes 0/1/2) ──

  Mode 0: 4 BG layers, all in tile mode, no affine.
  Mode 1: BG0 + BG1 in tile mode + BG2 in affine mode.
  Mode 2: BG2 + BG3 in affine mode only.

  ── Bitmap modes (modes 3/4/5) ──

  BG2-only framebuffer modes, affine-transformable, rendered by
  RenderBgBitmap (a commercial title's title screen runs mode 4).

  ── BG control register (BG0CNT..BG3CNT, $04000008 + n*2) ──

    bits 1:0   priority (0 = highest)
    bits 3:2   char base block (0..3 ; each is 16 KB of VRAM)
    bit 6      mosaic (deferred)
    bit 7      palette mode (0 = 4bpp 16-color subpalettes; 1 = 8bpp 256-color)
    bits 12:8  screen base block (0..31 ; each is 2 KB of VRAM)
    bit 13     display area overflow (affine only — deferred)
    bits 15:14 screen size:
                  00 → 256 × 256  (32 × 32 tiles, 1 screen block)
                  01 → 512 × 256  (64 × 32 tiles, 2 blocks side-by-side)
                  10 → 256 × 512  (32 × 64 tiles, 2 blocks stacked)
                  11 → 512 × 512  (64 × 64 tiles, 2×2 blocks)

  ── Tilemap entry (16 bits) ──

    bits 9:0     tile index (0..1023)
    bit  10      horizontal flip
    bit  11      vertical flip
    bits 15:12   palette bank (4bpp only ; one of 16 sub-palettes)

  ── Tile data ──

  4bpp: 32 bytes per tile. 8 rows × 4 bytes/row. Each byte holds two
        pixels: low nibble = even-x pixel, high nibble = odd-x pixel.
        Palette index 0 = transparent. Final palette entry = base + index,
        where base = palette_bank * 16.

  8bpp: 64 bytes per tile. 8 rows × 8 bytes/row. One byte per pixel.
        Palette index 0 = transparent. Index used directly into the 256-
        color BG palette (palette bank field is ignored).

  ── Palette ──

  Palette RAM is 1 KB at $05000000. First 512 bytes = BG palette
  (256 × 16-bit BGR555). Second 512 bytes = OBJ palette (same layout).
  Color index 0 in any sub-palette is transparent (and the global
  palette[0] is also the "backdrop" color shown where no BG is opaque).

  BGR555 layout: bit 0 = R LSB ... bit 14 = B MSB. We expand 5 → 8 bits
  by replicating the high 3 bits to the low 3 (matching real GBA LCD
  color reproduction reasonably well — `c8 = (c5 << 3) | (c5 >> 2)`).
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes, Memory, Sprites;

const
  GBA_WIDTH       = 240;
  GBA_HEIGHT      = 160;
  PIXELS_PER_FRAME = GBA_WIDTH * GBA_HEIGHT;

  { I/O register offsets within $04000000. }
  REG_DISPCNT  = $000;
  REG_DISPSTAT = $004;
  REG_VCOUNT   = $006;
  REG_BG0CNT   = $008;
  REG_BG1CNT   = $00A;
  REG_BG2CNT   = $00C;
  REG_BG3CNT   = $00E;
  REG_BG0HOFS  = $010;
  REG_BG0VOFS  = $012;
  REG_BG1HOFS  = $014;
  REG_BG1VOFS  = $016;
  REG_BG2HOFS  = $018;
  REG_BG2VOFS  = $01A;
  REG_BG3HOFS  = $01C;
  REG_BG3VOFS  = $01E;

  { Affine BG transform matrix + reference point.
      PA/PB/PC/PD: signed 8.8 fixed-point per 16-bit halfword.
      X / Y      : signed 19.8 fixed-point per 32-bit word.
    PA = dx along scanline; PB = dmx per scanline; PC = dy along
    scanline; PD = dmy per scanline. (X, Y) is the source-pixel for
    screen pixel (0, 0) of the topmost scanline the BG draws on.
    See GBATEK §4.4 'Bitmap BG modes' and §4.6 'Affine BG modes'. }
  REG_BG2PA    = $020;
  REG_BG2PB    = $022;
  REG_BG2PC    = $024;
  REG_BG2PD    = $026;
  REG_BG2X     = $028;
  REG_BG2Y     = $02C;
  REG_BG3PA    = $030;
  REG_BG3PB    = $032;
  REG_BG3PC    = $034;
  REG_BG3PD    = $036;
  REG_BG3X     = $038;
  REG_BG3Y     = $03C;

  { Phase E — window + blending I/O register offsets. }
  REG_WIN0H    = $040;       { window 0 horizontal extents (x2..x1) }
  REG_WIN1H    = $042;
  REG_WIN0V    = $044;       { window 0 vertical extents (y2..y1) }
  REG_WIN1V    = $046;
  REG_WININ    = $048;       { layer-enable inside WIN0 + WIN1 }
  REG_WINOUT   = $04A;       { layer-enable outside windows + inside WINOBJ }
  REG_BLDCNT   = $050;
  REG_BLDALPHA = $052;
  REG_BLDY     = $054;

  { BLDCNT target-pixel layer bits. }
  BLD_TGT_BG0  = $0001;
  BLD_TGT_BG1  = $0002;
  BLD_TGT_BG2  = $0004;
  BLD_TGT_BG3  = $0008;
  BLD_TGT_OBJ  = $0010;
  BLD_TGT_BD   = $0020;     { backdrop }

  { BLDCNT effect mode (bits 7:6). }
  BLD_MODE_OFF       = 0;
  BLD_MODE_ALPHA     = 1;
  BLD_MODE_BRIGHTEN  = 2;
  BLD_MODE_DARKEN    = 3;

const
  { Layer-type IDs — written into FLayerTop / FLayerBelow at every opaque
    pixel write. These align with BLDCNT's target-bit indices for fast
    masking: layer N matches BLDCNT bit N. }
  LAYER_BG0 = 0;
  LAYER_BG1 = 1;
  LAYER_BG2 = 2;
  LAYER_BG3 = 3;
  LAYER_OBJ = 4;
  LAYER_BD  = 5;

type
  TFrameBuffer  = array[0 .. PIXELS_PER_FRAME - 1] of TWord;
  PFrameBuffer  = ^TFrameBuffer;
  TLayerLine    = array[0 .. GBA_WIDTH - 1] of Byte;
  TColorLine    = array[0 .. GBA_WIDTH - 1] of TWord;
  TWindowMask   = array[0 .. GBA_WIDTH - 1] of Byte;

  TGbaPpu = class
  private
    FMem:            TGbaMemory;
    FFrame:          TFrameBuffer;
    FSprites:        TGbaSprites;
    FSpriteScanline: TSpriteScanline;

    { Phase E: per-pixel layer info, refreshed each scanline. Top tracks
      whatever is currently visible at each x; Below remembers the prior
      top when something opaque writes over it. Used by blending. }
    FLayerTop:    TLayerLine;
    FColorBelow:  TColorLine;
    FLayerBelow:  TLayerLine;
    FWindowMask:  TWindowMask;       { per-x allowed-layers bitmask }

    function  ReadIoHalf(offset: TWord): THalf; inline;
    function  ReadVramHalf(offset: TWord): THalf; inline;
    function  ReadVramByte(offset: TWord): TByte; inline;
    function  BgrToArgb(bgr555: THalf): TWord; inline;
    function  ReadBgPalette(palIndex: Integer): TWord; inline;

    procedure RenderBg(bgIndex, scanline: Integer);
    procedure RenderBgAffine(bgIndex, scanline: Integer);
    procedure RenderBgBitmap(bgMode, scanline: Integer);
    procedure FillBackdrop(scanline: Integer);
    procedure CompositeSpritesAtPriority(scanline, priority: Integer);
    procedure ComputeWindowMask(scanline: Integer);
    procedure ApplyBlending(scanline: Integer);
    procedure WritePixelWithLayer(scanline, x: Integer; color: TWord; layer: Byte); inline;

  public
    constructor Create(mem: TGbaMemory);
    destructor  Destroy; override;

    { Render a single scanline (0..159) into FFrame. }
    procedure RenderScanline(scanline: Integer);

    { Render all 160 scanlines. }
    procedure RenderFrame;

    { Direct framebuffer access (for the display path to blit). }
    function  FrameBufferPtr: PFrameBuffer;

    { Write the framebuffer to a binary PPM file — used by Phase C tests
      to produce visually inspectable output without a windowing layer. }
    procedure DumpPpm(const path: string);

    { Test-helper: read the most-recent sprite-scanline buffer (the one
      produced by the last RenderScanline call). Used by Phase E tests
      to inspect pre-composite sprite output. }
    function  SpriteScanlinePixel(x: Integer): TSpritePixel;
  end;

implementation

constructor TGbaPpu.Create(mem: TGbaMemory);
begin
  inherited Create;
  FMem := mem;
  FSprites := TGbaSprites.Create(mem);
  FillChar(FFrame, SizeOf(FFrame), 0);
  FillChar(FSpriteScanline, SizeOf(FSpriteScanline), 0);
end;

destructor TGbaPpu.Destroy;
begin
  FSprites.Free;
  inherited Destroy;
end;

function TGbaPpu.FrameBufferPtr: PFrameBuffer;
begin
  Result := @FFrame;
end;

function TGbaPpu.SpriteScanlinePixel(x: Integer): TSpritePixel;
begin
  Result := FSpriteScanline[x];
end;

function TGbaPpu.ReadIoHalf(offset: TWord): THalf; inline;
begin
  Result := FMem.ReadHalf($04000000 + offset);
end;

function TGbaPpu.ReadVramHalf(offset: TWord): THalf; inline;
begin
  Result := FMem.ReadHalf($06000000 + offset);
end;

function TGbaPpu.ReadVramByte(offset: TWord): TByte; inline;
begin
  Result := FMem.ReadByte($06000000 + offset);
end;

function TGbaPpu.BgrToArgb(bgr555: THalf): TWord; inline;
{ Convert GBA BGR555 → 8-bit-per-channel ARGB. Expand each 5-bit channel
  to 8 bits by `c8 = (c5 << 3) | (c5 >> 2)` — a standard 5-to-8 expansion
  that places the top 3 bits of the result and replicates them low. }
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

function TGbaPpu.ReadBgPalette(palIndex: Integer): TWord; inline;
{ Read BG palette entry palIndex (0..255), return ARGB. Index 0 wrapped
  per any subpalette is "transparent" — caller must check for that
  separately. This routine returns the actual color regardless. }
var
  raw: THalf;
begin
  raw := FMem.ReadHalf($05000000 + TWord(palIndex) * 2);
  Result := BgrToArgb(raw);
end;

procedure TGbaPpu.WritePixelWithLayer(scanline, x: Integer; color: TWord; layer: Byte); inline;
{ Write a pixel and update layer-info bookkeeping. Saves the current top
  (color + layer) to the "below" slots so the alpha-blend pass can find
  the second-from-top value. Brighten/darken only need top info, but the
  bookkeeping is cheap and lets alpha land cleanly in E.5. }
var
  idx: Integer;
begin
  idx := scanline * GBA_WIDTH + x;
  FColorBelow[x] := FFrame[idx];
  FLayerBelow[x] := FLayerTop[x];
  FFrame[idx]    := color;
  FLayerTop[x]   := layer;
end;

procedure TGbaPpu.FillBackdrop(scanline: Integer);
{ Fill the scanline with palette[0] (the "backdrop" color). Also resets
  the layer-info trackers for this scanline. }
var
  bg: TWord;
  x: Integer;
  base: Integer;
begin
  bg := ReadBgPalette(0);
  base := scanline * GBA_WIDTH;
  for x := 0 to GBA_WIDTH - 1 do
  begin
    FFrame[base + x]  := bg;
    FLayerTop[x]      := LAYER_BD;
    FColorBelow[x]    := bg;
    FLayerBelow[x]    := LAYER_BD;
  end;
end;

procedure TGbaPpu.ComputeWindowMask(scanline: Integer);
{ Build the per-pixel "allowed layers" mask for this scanline based on
  WIN0H/V, WIN1H/V, WININ, WINOUT, and DISPCNT bits 13/14/15.

  Priority of windows at a pixel: WIN0 > WIN1 > WINOBJ > WIN-OUT.
  Mask bits 0..4 = BG0/1/2/3/OBJ enabled; bit 5 = color-effect enabled.

  GBATEK rule for extents: X1 (left, inclusive), X2 (right, exclusive).
  If X1 > X2 the window wraps. Same for Y1/Y2. Values > screen size
  clamp implicitly via the inclusive-range arithmetic.

  When no windows are enabled in DISPCNT, the mask becomes all-on
  ($3F = every layer + color effect) — every layer renders normally. }
var
  dispcnt, winIn, winOut: THalf;
  win0H, win0V, win1H, win1V: THalf;
  win0En, win1En, winObjEn: Boolean;
  win0X1, win0X2, win0Y1, win0Y2: Integer;
  win1X1, win1X2, win1Y1, win1Y2: Integer;
  win0Mask, win1Mask, winObjMask, winOutMask: Byte;
  x: Integer;
  inWin0Y, inWin1Y: Boolean;

  function InHRange(px, x1, x2: Integer): Boolean; inline;
  begin
    if x1 <= x2 then Result := (px >= x1) and (px < x2)
                else Result := (px >= x1) or  (px < x2);
  end;
  function InVRange(py, y1, y2: Integer): Boolean; inline;
  begin
    if y1 <= y2 then Result := (py >= y1) and (py < y2)
                else Result := (py >= y1) or  (py < y2);
  end;

begin
  dispcnt  := ReadIoHalf(REG_DISPCNT);
  win0En   := ((dispcnt shr 13) and 1) = 1;
  win1En   := ((dispcnt shr 14) and 1) = 1;
  winObjEn := ((dispcnt shr 15) and 1) = 1;

  if (not win0En) and (not win1En) and (not winObjEn) then
  begin
    for x := 0 to GBA_WIDTH - 1 do FWindowMask[x] := $3F;
    Exit;
  end;

  winIn  := ReadIoHalf(REG_WININ);
  winOut := ReadIoHalf(REG_WINOUT);
  win0Mask   := winIn  and $3F;
  win1Mask   := (winIn shr 8) and $3F;
  winOutMask := winOut and $3F;
  winObjMask := (winOut shr 8) and $3F;

  win0H := ReadIoHalf(REG_WIN0H);
  win0V := ReadIoHalf(REG_WIN0V);
  win1H := ReadIoHalf(REG_WIN1H);
  win1V := ReadIoHalf(REG_WIN1V);
  win0X1 := (win0H shr 8) and $FF;  win0X2 :=  win0H        and $FF;
  win0Y1 := (win0V shr 8) and $FF;  win0Y2 :=  win0V        and $FF;
  win1X1 := (win1H shr 8) and $FF;  win1X2 :=  win1H        and $FF;
  win1Y1 := (win1V shr 8) and $FF;  win1Y2 :=  win1V        and $FF;

  inWin0Y := win0En and InVRange(scanline, win0Y1, win0Y2);
  inWin1Y := win1En and InVRange(scanline, win1Y1, win1Y2);

  for x := 0 to GBA_WIDTH - 1 do
  begin
    if inWin0Y and InHRange(x, win0X1, win0X2) then
    begin
      FWindowMask[x] := win0Mask;
      Continue;
    end;
    if inWin1Y and InHRange(x, win1X1, win1X2) then
    begin
      FWindowMask[x] := win1Mask;
      Continue;
    end;
    if winObjEn and (FSpriteScanline[x].Mode = SPRITE_MODE_WINDOW) then
    begin
      FWindowMask[x] := winObjMask;
      Continue;
    end;
    FWindowMask[x] := winOutMask;
  end;
end;

procedure TGbaPpu.ApplyBlending(scanline: Integer);
{ Apply BLDCNT/BLDALPHA/BLDY color effects to the scanline post-composite.

  Modes implemented this session: brighten (mode 2) + darken (mode 3).
  Alpha (mode 1) deferred to E.5 — needs proper second-layer-target gating
  and the special sprite-blend-mode-1 forcing semantics. The framework
  (FColorBelow / FLayerBelow tracking) is in place so the alpha
  implementation drops in without further pipeline changes.

  Per-pixel gating: a pixel is blended iff its top-layer is a target1
  layer in BLDCNT (bits 0-5). The color-effect-enable window-mask bit
  (bit 5 of FWindowMask[x]) also gates the effect — if the current
  window disallows color effects at this pixel, blending skips. }
var
  bldcnt, bldalpha: THalf;
  mode: Integer;
  target1, target2: THalf;
  bldy: THalf;
  evy, eva, evb: Integer;
  fbIdx, x: Integer;
  topColor, belowColor: TWord;
  r, g, b: Integer;
  topLayer, belowLayer: Byte;
  layerBitMask, belowBitMask: Byte;
begin
  bldcnt := ReadIoHalf(REG_BLDCNT);
  mode   := (bldcnt shr 6) and $3;
  if mode = BLD_MODE_OFF then Exit;

  target1 := bldcnt and $3F;
  fbIdx := scanline * GBA_WIDTH;

  case mode of
    BLD_MODE_BRIGHTEN:
      begin
        bldy := ReadIoHalf(REG_BLDY) and $1F;
        if bldy > 16 then bldy := 16;
        evy := bldy;
        for x := 0 to GBA_WIDTH - 1 do
        begin
          if (FWindowMask[x] and $20) = 0 then Continue;  { color effect masked }
          topLayer := FLayerTop[x];
          layerBitMask := 1 shl topLayer;
          if (target1 and layerBitMask) = 0 then Continue;
          topColor := FFrame[fbIdx + x];
          b := topColor and $FF;
          g := (topColor shr 8)  and $FF;
          r := (topColor shr 16) and $FF;
          r := r + ((255 - r) * evy) div 16;
          g := g + ((255 - g) * evy) div 16;
          b := b + ((255 - b) * evy) div 16;
          FFrame[fbIdx + x] := $FF000000 or (TWord(r) shl 16) or (TWord(g) shl 8) or TWord(b);
        end;
      end;

    BLD_MODE_DARKEN:
      begin
        bldy := ReadIoHalf(REG_BLDY) and $1F;
        if bldy > 16 then bldy := 16;
        evy := bldy;
        for x := 0 to GBA_WIDTH - 1 do
        begin
          if (FWindowMask[x] and $20) = 0 then Continue;
          topLayer := FLayerTop[x];
          layerBitMask := 1 shl topLayer;
          if (target1 and layerBitMask) = 0 then Continue;
          topColor := FFrame[fbIdx + x];
          b := topColor and $FF;
          g := (topColor shr 8)  and $FF;
          r := (topColor shr 16) and $FF;
          r := r - (r * evy) div 16;
          g := g - (g * evy) div 16;
          b := b - (b * evy) div 16;
          FFrame[fbIdx + x] := $FF000000 or (TWord(r) shl 16) or (TWord(g) shl 8) or TWord(b);
        end;
      end;

    BLD_MODE_ALPHA:
      begin
        { Alpha blend per BLDCNT mode 1. Per GBATEK §6.2:
            result_channel = min(31, target1*eva/16 + target2*evb/16)
          (working in 5-bit BGR555 channel space, then expanded back
          to 8-bit ARGB via our existing color pipeline.) We do the
          math in 8-bit channel space directly since FFrame stores
          ARGB8888 — equivalent precision for the visible output.

          Per-pixel gating:
            (a) color-effect window-mask bit set
            (b) top layer in BLDCNT target1 set
            (c) below layer in BLDCNT target2 set
          If (a)+(b) hold but (c) doesn't, no blend — top renders
          as-is. A commercial title's title-card alpha-blend setup
          (BLDCNT=\$1844: target1=BG2, mode=ALPHA, target2=BG3+OBJ)
          needs proper target2 gating so backdrop pixels don't get
          blended away. }
        bldalpha := ReadIoHalf(REG_BLDALPHA);
        target2  := (bldcnt shr 8) and $3F;
        eva      := bldalpha and $1F;
        if eva > 16 then eva := 16;
        evb      := (bldalpha shr 8) and $1F;
        if evb > 16 then evb := 16;

        for x := 0 to GBA_WIDTH - 1 do
        begin
          if (FWindowMask[x] and $20) = 0 then Continue;
          topLayer := FLayerTop[x];
          layerBitMask := 1 shl topLayer;
          if (target1 and layerBitMask) = 0 then Continue;

          belowLayer := FLayerBelow[x];
          belowBitMask := 1 shl belowLayer;
          if (target2 and belowBitMask) = 0 then Continue;

          topColor := FFrame[fbIdx + x];
          belowColor := FColorBelow[x];
          r := (((topColor   shr 16) and $FF) * eva +
                ((belowColor shr 16) and $FF) * evb) div 16;
          g := (((topColor   shr 8)  and $FF) * eva +
                ((belowColor shr 8)  and $FF) * evb) div 16;
          b := (( topColor          and $FF) * eva +
                ( belowColor        and $FF) * evb) div 16;
          if r > 255 then r := 255;
          if g > 255 then g := 255;
          if b > 255 then b := 255;
          FFrame[fbIdx + x] := $FF000000 or (TWord(r) shl 16) or (TWord(g) shl 8) or TWord(b);
        end;
      end;
  end;
end;

procedure TGbaPpu.RenderBg(bgIndex, scanline: Integer);
{ Render one BG layer's contribution to the given scanline. Overwrites
  framebuffer pixels where this layer is opaque (palette index ≠ 0 in
  the sub-palette). Caller is responsible for layering order.

  Implementation: for each x in 0..239, compute the (sx, sy) in the BG's
  virtual screen space by applying scroll and modular reduction, then
  walk to the correct screen-block / tilemap-entry / tile / pixel. }
var
  cntReg, hofs, vofs: THalf;
  priority: Integer;
  charBase, screenBase: TWord;
  pal8bpp: Boolean;
  screenSize: Integer;
  screenW, screenH: Integer;
  cntOffset, hofsOffset: TWord;
  scrollX, scrollY: Integer;
  x: Integer;
  sx, sy: Integer;
  blockSubIdx: Integer;
  tileX, tileY: Integer;
  inBlockTx, inBlockTy: Integer;
  tilemapAddr: TWord;
  tilemapEntry: THalf;
  tileIdx: Integer;
  hflip, vflip: Boolean;
  palBank: Integer;
  pixelX, pixelY: Integer;
  tileSize: Integer;
  tileAddr: TWord;
  pixByte: TByte;
  palIdx: Integer;
  finalPalIdx: Integer;
  color: TWord;
  fbIndex: Integer;
begin
  { Locate the I/O slots for this BG. }
  cntOffset  := REG_BG0CNT  + TWord(bgIndex) * 2;
  hofsOffset := REG_BG0HOFS + TWord(bgIndex) * 4;
  cntReg := ReadIoHalf(cntOffset);
  hofs   := ReadIoHalf(hofsOffset);
  vofs   := ReadIoHalf(hofsOffset + 2);
  priority := cntReg and $3;
  if priority = priority then ;  { silence unused-var warning until we use it for compositing }

  charBase   := TWord((cntReg shr 2) and $3) * $4000;     { 16 KB per char block }
  pal8bpp    := ((cntReg shr 7) and 1) = 1;
  screenBase := TWord((cntReg shr 8) and $1F) * $800;     { 2 KB per screen block }
  screenSize := (cntReg shr 14) and $3;

  case screenSize of
    0: begin screenW := 256; screenH := 256; end;
    1: begin screenW := 512; screenH := 256; end;
    2: begin screenW := 256; screenH := 512; end;
    3: begin screenW := 512; screenH := 512; end;
  else
    screenW := 256; screenH := 256;
  end;

  scrollX := hofs and $1FF;
  scrollY := vofs and $1FF;

  if pal8bpp then tileSize := 64 else tileSize := 32;
  fbIndex := scanline * GBA_WIDTH;

  for x := 0 to GBA_WIDTH - 1 do
  begin
    { Virtual screen coord with scroll + modular wrap. }
    sx := (x        + scrollX) mod screenW;
    sy := (scanline + scrollY) mod screenH;

    { Which screen sub-block (32x32-tile chunk) holds this pixel? }
    case screenSize of
      0: blockSubIdx := 0;
      1: blockSubIdx := (sx shr 8) and 1;
      2: blockSubIdx := (sy shr 8) and 1;
      3: blockSubIdx := ((sy shr 8) and 1) * 2 + ((sx shr 8) and 1);
    else
      blockSubIdx := 0;
    end;

    tileX := (sx shr 3) and $1F;
    tileY := (sy shr 3) and $1F;
    inBlockTx := tileX;
    inBlockTy := tileY;

    tilemapAddr := screenBase + TWord(blockSubIdx) * $800
                   + (TWord(inBlockTy) * 32 + TWord(inBlockTx)) * 2;
    tilemapEntry := ReadVramHalf(tilemapAddr);

    tileIdx := tilemapEntry and $3FF;
    hflip   := ((tilemapEntry shr 10) and 1) = 1;
    vflip   := ((tilemapEntry shr 11) and 1) = 1;
    palBank := (tilemapEntry shr 12) and $F;

    pixelX := sx and 7;
    pixelY := sy and 7;
    if hflip then pixelX := 7 - pixelX;
    if vflip then pixelY := 7 - pixelY;

    tileAddr := charBase + TWord(tileIdx) * TWord(tileSize);

    if pal8bpp then
    begin
      { 8 bytes per row, 1 byte per pixel, single 256-color palette. }
      pixByte := ReadVramByte(tileAddr + TWord(pixelY) * 8 + TWord(pixelX));
      palIdx := pixByte;
      if palIdx = 0 then Continue;  { transparent }
      finalPalIdx := palIdx;
    end
    else
    begin
      { 4 bytes per row, 2 pixels per byte. }
      pixByte := ReadVramByte(tileAddr + TWord(pixelY) * 4 + TWord(pixelX) shr 1);
      if (pixelX and 1) = 0 then
        palIdx := pixByte and $F
      else
        palIdx := (pixByte shr 4) and $F;
      if palIdx = 0 then Continue;  { transparent within sub-palette }
      finalPalIdx := palBank * 16 + palIdx;
    end;

    color := ReadBgPalette(finalPalIdx);

    { Phase E: window-mask gate. Bit (bgIndex) of FWindowMask[x] must
      be set for this BG to render here. }
    if (FWindowMask[x] and (1 shl bgIndex)) = 0 then Continue;

    WritePixelWithLayer(scanline, x, color, Byte(bgIndex));
  end;
  if fbIndex = fbIndex then ;  { silence unused — fbIndex no longer used directly }
end;

procedure TGbaPpu.RenderBgAffine(bgIndex, scanline: Integer);
{ Render BG2 (mode 1 or 2) or BG3 (mode 2) using its affine transform
  matrix + reference point. The affine pipeline differs from the text
  pipeline in three ways:

    1. Pixel addressing uses a 2D matrix transform (PA, PB, PC, PD)
       around a reference point (X, Y). For screen pixel (sx, sy),
       the source pixel in the BG's own coordinate space is:
         src_x = (X + PA*sx + PB*sy) >> 8
         src_y = (Y + PC*sx + PD*sy) >> 8
       PA/PB/PC/PD are signed 8.8 fixed; X/Y are signed 19.8 fixed.
       This implementation computes src_x/y from scratch each pixel.
       Real hardware keeps internal accumulators across scanlines that
       can be re-seeded by mid-frame writes to X/Y — those special
       cases are deferred.

    2. Tilemap layout is flat: 1 byte per tile (just the index, no
       hflip/vflip/palette-bank fields). Map width × height depends on
       BGCNT screen-size bits 14-15:
         0 -> 128 ×  128 pixels = 16 × 16 tiles =   256 bytes
         1 -> 256 ×  256 pixels = 32 × 32 tiles =  1024 bytes
         2 -> 512 ×  512 pixels = 64 × 64 tiles =  4096 bytes
         3 -> 1024 × 1024 pixels = 128 × 128 tiles = 16384 bytes
       Pixel data is ALWAYS 256-color (64 bytes per tile), no
       sub-palette banks.

    3. Out-of-bounds handling per BGCNT bit 13 (display area overflow):
         0 -> transparent outside the BG area
         1 -> wrap (tile coordinates mod map size)

  A commercial title's mode-1 intro screen uses BG2 affine for the
  cinematic character art. Without this procedure (previous behavior:
  fall through to RenderBg's text-mode path), tile indices were read
  with 2-byte stride and hflip/palette bits, producing a blue-striped
  artifact. }
var
  cntReg: THalf;
  baseOffset: TWord;
  charBase, screenBase: TWord;
  screenSize: Integer;
  mapSizePx: Integer;
  mapSizeTiles: Integer;
  wrap: Boolean;
  bg2pa, bg2pb, bg2pc, bg2pd: Int32;
  bg2x, bg2y: Int32;
  refX, refY: Int32;
  x: Integer;
  srcX, srcY: Int32;
  pxX, pxY: Integer;
  tileX, tileY: Integer;
  tileIdx: Integer;
  tileAddr: TWord;
  pixByte: TByte;
  color: TWord;
begin
  { Per-BG register slots: BG2 uses $020-$02D, BG3 uses $030-$03D. }
  if bgIndex = 2 then baseOffset := REG_BG2PA else baseOffset := REG_BG3PA;

  cntReg     := ReadIoHalf(REG_BG0CNT + TWord(bgIndex) * 2);
  charBase   := TWord((cntReg shr 2) and $3) * $4000;
  screenBase := TWord((cntReg shr 8) and $1F) * $800;
  screenSize := (cntReg shr 14) and $3;
  wrap       := ((cntReg shr 13) and 1) = 1;

  case screenSize of
    0: mapSizePx := 128;
    1: mapSizePx := 256;
    2: mapSizePx := 512;
    3: mapSizePx := 1024;
  else
    mapSizePx := 128;
  end;
  mapSizeTiles := mapSizePx shr 3;

  { Sign-extend PA..PD from 16-bit to 32-bit. }
  bg2pa := SmallInt(ReadIoHalf(baseOffset + 0));
  bg2pb := SmallInt(ReadIoHalf(baseOffset + 2));
  bg2pc := SmallInt(ReadIoHalf(baseOffset + 4));
  bg2pd := SmallInt(ReadIoHalf(baseOffset + 6));

  { X and Y are 28-bit signed (bits 27:0 of the 32-bit register, sign-
    extended from bit 27 per GBATEK). Read as 32-bit then sign-extend. }
  bg2x := Int32(FMem.ReadWord($04000000 + TWord(baseOffset) + 8));
  bg2y := Int32(FMem.ReadWord($04000000 + TWord(baseOffset) + 12));
  if (bg2x and $08000000) <> 0 then bg2x := bg2x or Int32($F0000000);
  if (bg2y and $08000000) <> 0 then bg2y := bg2y or Int32($F0000000);

  { Reference point at start of THIS scanline. Real HW keeps internal
    accumulators that get incremented by (PB, PD) each scanline; we
    compute equivalently from scratch as X + PB*scanline. }
  refX := bg2x + bg2pb * scanline;
  refY := bg2y + bg2pd * scanline;

  for x := 0 to GBA_WIDTH - 1 do
  begin
    { Source coordinate for screen pixel (x, scanline) in 8.8 fixed. }
    srcX := refX + bg2pa * x;
    srcY := refY + bg2pc * x;

    { Integer pixel coordinates inside the BG (drop the 8-bit fraction). }
    pxX := srcX shr 8;
    pxY := srcY shr 8;

    { Bounds: either wrap with modulo or skip the pixel transparent. }
    if wrap then
    begin
      pxX := ((pxX mod mapSizePx) + mapSizePx) mod mapSizePx;
      pxY := ((pxY mod mapSizePx) + mapSizePx) mod mapSizePx;
    end
    else
    begin
      if (pxX < 0) or (pxX >= mapSizePx) or
         (pxY < 0) or (pxY >= mapSizePx) then Continue;
    end;

    tileX := pxX shr 3;
    tileY := pxY shr 3;

    { Affine tilemap: 1 byte per tile, row-major, no flip/palette bits. }
    tileIdx := ReadVramByte(screenBase + TWord(tileY * mapSizeTiles + tileX));

    { Tile data: always 256-color, 64 bytes per tile, row-major within
      tile (8 bytes per row). }
    tileAddr := charBase + TWord(tileIdx) * 64
                + TWord((pxY and 7) * 8 + (pxX and 7));
    pixByte := ReadVramByte(tileAddr);

    if pixByte = 0 then Continue;   { palette idx 0 == transparent }

    color := ReadBgPalette(pixByte);

    { Window-mask gate (matches text-mode RenderBg). }
    if (FWindowMask[x] and (1 shl bgIndex)) = 0 then Continue;

    WritePixelWithLayer(scanline, x, color, Byte(bgIndex));
  end;
end;

procedure TGbaPpu.RenderBgBitmap(bgMode, scanline: Integer);
{ Bitmap modes render BG2 as a framebuffer (GBATEK "Bitmap BG modes"):

    mode 3: 240x160, 15bpp direct color, single frame at VRAM +0
    mode 4: 240x160, 8bpp palette-indexed, two frames (+0 / +$A000)
            page-selected by DISPCNT bit 4; index 0 = transparent
    mode 5: 160x128, 15bpp direct color, two frames (+0 / +$A000)

  BG2's affine matrix + reference point apply to bitmap modes exactly
  as to affine tile modes (same register set, no wrap — out-of-frame
  samples are transparent). A commercial title's title screen runs
  mode 4 with an identity transform; before this procedure existed,
  bitmap modes fell through to backdrop and that screen's art layer
  rendered black. }
var
  baseOffset: TWord;
  bg2pa, bg2pb, bg2pc, bg2pd: Int32;
  bg2x, bg2y: Int32;
  refX, refY: Int32;
  x: Integer;
  srcX, srcY: Int32;
  pxX, pxY: Integer;
  frameW, frameH: Integer;
  pageBase: TWord;
  pixByte: TByte;
  color: TWord;
begin
  frameW := 240; frameH := 160; pageBase := 0;
  case bgMode of
    4: if ((ReadIoHalf(REG_DISPCNT) shr 4) and 1) = 1 then pageBase := $A000;
    5: begin
         frameW := 160; frameH := 128;
         if ((ReadIoHalf(REG_DISPCNT) shr 4) and 1) = 1 then pageBase := $A000;
       end;
  end;

  baseOffset := REG_BG2PA;
  bg2pa := SmallInt(ReadIoHalf(baseOffset + 0));
  bg2pb := SmallInt(ReadIoHalf(baseOffset + 2));
  bg2pc := SmallInt(ReadIoHalf(baseOffset + 4));
  bg2pd := SmallInt(ReadIoHalf(baseOffset + 6));
  bg2x := Int32(FMem.ReadWord($04000000 + TWord(baseOffset) + 8));
  bg2y := Int32(FMem.ReadWord($04000000 + TWord(baseOffset) + 12));
  if (bg2x and $08000000) <> 0 then bg2x := bg2x or Int32($F0000000);
  if (bg2y and $08000000) <> 0 then bg2y := bg2y or Int32($F0000000);

  refX := bg2x + bg2pb * scanline;
  refY := bg2y + bg2pd * scanline;

  for x := 0 to GBA_WIDTH - 1 do
  begin
    srcX := refX + bg2pa * x;
    srcY := refY + bg2pc * x;
    pxX := srcX shr 8;
    pxY := srcY shr 8;

    { No wrap in bitmap modes: out-of-frame samples are transparent. }
    if (pxX < 0) or (pxX >= frameW) or
       (pxY < 0) or (pxY >= frameH) then Continue;

    case bgMode of
      3: color := BgrToArgb(ReadVramHalf(TWord((pxY * frameW + pxX) * 2)));
      4: begin
           pixByte := ReadVramByte(pageBase + TWord(pxY * frameW + pxX));
           if pixByte = 0 then Continue;   { palette idx 0 == transparent }
           color := ReadBgPalette(pixByte);
         end;
      5: color := BgrToArgb(ReadVramHalf(pageBase + TWord((pxY * frameW + pxX) * 2)));
    else
      Continue;
    end;

    { Window-mask gate (BG2 = layer bit 2, matching the other BG paths). }
    if (FWindowMask[x] and (1 shl 2)) = 0 then Continue;

    WritePixelWithLayer(scanline, x, color, 2);
  end;
end;

procedure TGbaPpu.CompositeSpritesAtPriority(scanline, priority: Integer);
{ For each x where the sprite scanline has an opaque pixel with the
  matching priority, write that pixel into the framebuffer + layer info.

  Window-OBJ-mode sprites (Mode=SPRITE_MODE_WINDOW) DO NOT render visible
  pixels — they exist purely to define the WINOBJ region (already consumed
  by ComputeWindowMask). Skip them here.

  Called between BG-priority passes so sprites and BGs of the same
  priority interleave correctly: BG priority-N renders first, then sprite
  priority-N overwrites where the sprite is opaque. Higher-priority
  layers end up on top, with sprites winning tied-priority cases. }
var
  x: Integer;
begin
  for x := 0 to GBA_WIDTH - 1 do
  begin
    if not FSpriteScanline[x].Opaque then Continue;
    if FSpriteScanline[x].Priority <> priority then Continue;
    if FSpriteScanline[x].Mode = SPRITE_MODE_WINDOW then Continue;
    { Window-mask gate: bit 4 = OBJ enabled at this pixel. }
    if (FWindowMask[x] and (1 shl LAYER_OBJ)) = 0 then Continue;
    WritePixelWithLayer(scanline, x, FSpriteScanline[x].Color, LAYER_OBJ);
  end;
end;

procedure TGbaPpu.RenderScanline(scanline: Integer);
{ Composite all enabled BG layers + sprites into the scanline.

  Pipeline:
    1. Sprite layer first — Sprites.RenderScanline rasterizes all 128 OBJ
       entries into FSpriteScanline (a 240-pixel buffer of color+priority+
       mode+opacity records).
    2. Backdrop fills the frame.
    3. For each priority pri = 3 downto 0:
       a. Render BGs with priority pri (BG3 first, BG0 last → lower BG num
          wins tied priority within BG layers).
       b. Composite sprite pixels with priority pri on top (sprites win
          tied priority vs BGs per GBA convention).

  Forced-blank (DISPCNT bit 7) short-circuits to white.

  Bitmap modes 3/4/5 currently fall through to backdrop only — Phase E
  doesn't add bitmap-mode rendering; they remain on the post-capstone
  list. Sprites still render in bitmap modes via the same scanline buffer,
  but for mode-0 commercial titles this path doesn't fire. }
var
  dispcnt: THalf;
  forcedBlank: Boolean;
  bgMode: Integer;
  pri, bg: Integer;
  bgCnt: THalf;
  bgPriority: Integer;
  fbIndex, x: Integer;
  white: TWord;
begin
  dispcnt := ReadIoHalf(REG_DISPCNT);
  forcedBlank := ((dispcnt shr 7) and 1) = 1;

  if forcedBlank then
  begin
    { Per ARM ARM / GBATEK: forced blank fills the screen with white. }
    white := $FFFFFFFF;
    fbIndex := scanline * GBA_WIDTH;
    for x := 0 to GBA_WIDTH - 1 do FFrame[fbIndex + x] := white;
    Exit;
  end;

  { Phase E pipeline: sprites → window mask → backdrop+layer reset →
    priority-ordered BG/sprite composite → blending. }
  FSprites.RenderScanline(scanline, FSpriteScanline);
  ComputeWindowMask(scanline);

  bgMode := dispcnt and $7;
  if bgMode > 2 then
  begin
    { Bitmap modes (3/4/5): BG2 is the only BG layer. Honor its DISPCNT
      enable bit and BG2CNT priority so it interleaves with sprites the
      same way tile-mode BGs do. }
    FillBackdrop(scanline);
    for pri := 3 downto 0 do
    begin
      if (((dispcnt shr 10) and 1) = 1) and
         ((ReadIoHalf(REG_BG0CNT + 4) and $3) = TWord(pri)) then
        RenderBgBitmap(bgMode, scanline);
      CompositeSpritesAtPriority(scanline, pri);
    end;
    ApplyBlending(scanline);
    Exit;
  end;

  FillBackdrop(scanline);

  { Compositing pass: lowest priority drawn first. Sprites of priority N
    composite AFTER BGs of priority N → sprites win tied priority. }
  for pri := 3 downto 0 do
  begin
    for bg := 3 downto 0 do
    begin
      { Is this BG enabled in DISPCNT? Bit (8 + bg). }
      if ((dispcnt shr (8 + bg)) and 1) = 0 then Continue;

      { Mode-specific: in mode 1, BG3 is disabled regardless of DISPCNT bit
        (only BG0/BG1/BG2 valid). In mode 2, only BG2/BG3 valid. }
      case bgMode of
        1: if bg = 3 then Continue;
        2: if (bg = 0) or (bg = 1) then Continue;
      end;

      bgCnt := ReadIoHalf(REG_BG0CNT + TWord(bg) * 2);
      bgPriority := bgCnt and $3;
      if bgPriority <> pri then Continue;

      { Affine BG dispatch: mode 1 makes BG2 affine; mode 2 makes both
        BG2 and BG3 affine. All other (mode, bg) combinations are text.
        Without this dispatch BG2 would read its tilemap as text-mode
        (2 bytes per tile with hflip/palette bits), producing the
        blue-striped artifact a commercial intro scene showed. }
      case bgMode of
        1: if bg = 2                  then RenderBgAffine(bg, scanline) else RenderBg(bg, scanline);
        2: if (bg = 2) or (bg = 3)    then RenderBgAffine(bg, scanline) else RenderBg(bg, scanline);
      else  RenderBg(bg, scanline);
      end;
    end;

    CompositeSpritesAtPriority(scanline, pri);
  end;

  ApplyBlending(scanline);
end;

procedure TGbaPpu.RenderFrame;
var
  y: Integer;
begin
  for y := 0 to GBA_HEIGHT - 1 do
    RenderScanline(y);
end;

procedure TGbaPpu.DumpPpm(const path: string);
{ Write a binary PPM (P6) of the framebuffer to `path`. Useful for
  console-mode tests that want a visually inspectable artifact. }
var
  f: file of Byte;
  header: AnsiString;
  i: Integer;
  px: TWord;
  rgb: array[0..2] of Byte;
  hb: Byte;
begin
  AssignFile(f, path);
  Rewrite(f);
  try
    header := AnsiString(Format('P6'#10'%d %d'#10'255'#10, [GBA_WIDTH, GBA_HEIGHT]));
    for i := 1 to Length(header) do
    begin
      hb := Byte(header[i]);
      BlockWrite(f, hb, 1);
    end;
    for i := 0 to PIXELS_PER_FRAME - 1 do
    begin
      px := FFrame[i];
      rgb[0] := (px shr 16) and $FF;   { R }
      rgb[1] := (px shr 8)  and $FF;   { G }
      rgb[2] :=  px         and $FF;   { B }
      BlockWrite(f, rgb[0], 3);
    end;
  finally
    CloseFile(f);
  end;
end;

end.
