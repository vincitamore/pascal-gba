program test_ppu;
{
  PPU acceptance tests — programmatically populate palette, tile data, and
  tilemap in a TGbaMemory; render a frame via TGbaPpu; assert specific
  pixel values; dump a PPM for visual inspection.

  No CPU involved at this stage — the PPU and Memory are exercised
  directly. Once the dumps look right, Phase C wiring is straightforward.
}

{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, Memory, Ppu;

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

procedure CheckEq(const name: string; expected, actual: TWord);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name, '  (= $', IntToHex(actual, 8), ')');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  ', name, '  expected $', IntToHex(expected, 8),
                              ', got $',     IntToHex(actual, 8));
    Inc(FailCount);
  end;
end;

{ ───── Helpers for setting up scenes ────────────────────────────── }

procedure WriteBgPalette(mem: TGbaMemory; index: Integer; bgr555: THalf);
begin
  mem.WriteHalf($05000000 + TWord(index) * 2, bgr555);
end;

procedure WriteVramHalf(mem: TGbaMemory; offset: TWord; v: THalf);
begin
  mem.WriteHalf($06000000 + offset, v);
end;

procedure WriteVramByte(mem: TGbaMemory; offset: TWord; v: TByte);
begin
  mem.WriteByte($06000000 + offset, v);
end;

procedure SetIoHalf(mem: TGbaMemory; offset: TWord; v: THalf);
begin
  mem.WriteHalf($04000000 + offset, v);
end;

{ Build BGR555 from RGB 0..31 channels. }
function MakeBgr555(r, g, b: Integer): THalf;
begin
  Result := THalf((b and $1F) shl 10) or THalf((g and $1F) shl 5) or THalf(r and $1F);
end;

{ Expand a BGR555 → ARGB exactly as the PPU does (so test assertions know
  what to expect without duplicating the math). }
function ExpandColor(bgr555: THalf): TWord;
var
  r5, g5, b5, r8, g8, b8: TWord;
begin
  r5 :=  TWord(bgr555)         and $1F;
  g5 := (TWord(bgr555) shr 5)  and $1F;
  b5 := (TWord(bgr555) shr 10) and $1F;
  r8 := (r5 shl 3) or (r5 shr 2);
  g8 := (g5 shl 3) or (g5 shr 2);
  b8 := (b5 shl 3) or (b5 shr 2);
  Result := $FF000000 or (r8 shl 16) or (g8 shl 8) or b8;
end;

{ Fill a 4bpp tile (32 bytes at VRAM offset `tileOffs`) with a constant
  palette index in all 64 pixels. Each byte holds 2 pixels so a constant
  index n fills with byte (n | n<<4). }
procedure FillTile4bppConstant(mem: TGbaMemory; tileOffs: TWord; palIdx: Integer);
var
  i: Integer;
  b: TByte;
begin
  b := TByte((palIdx and $F) or ((palIdx and $F) shl 4));
  for i := 0 to 31 do WriteVramByte(mem, tileOffs + TWord(i), b);
end;

{ ───── Tests ────────────────────────────────────────────────────── }

procedure TestBackdropColor;
{ Set palette[0] to a recognizable green ; disable all BG layers ; render
  one scanline ; verify every pixel is the backdrop color. }
var
  mem: TGbaMemory;
  ppu: TGbaPpu;
  expected: TWord;
  x: Integer;
  fb: PFrameBuffer;
  allMatch: Boolean;
begin
  Writeln('--- TestBackdropColor ---');
  mem := TGbaMemory.Create;
  ppu := TGbaPpu.Create(mem);
  try
    { palette[0] = pure green = (0, 31, 0) in BGR555. }
    WriteBgPalette(mem, 0, MakeBgr555(0, 31, 0));
    expected := ExpandColor(MakeBgr555(0, 31, 0));

    { DISPCNT = mode 0, all BGs disabled. }
    SetIoHalf(mem, REG_DISPCNT, $0000);

    ppu.RenderScanline(80);
    fb := ppu.FrameBufferPtr;

    allMatch := True;
    for x := 0 to GBA_WIDTH - 1 do
      if fb^[80 * GBA_WIDTH + x] <> expected then
      begin
        allMatch := False;
        Break;
      end;

    if allMatch then
    begin
      Writeln('  PASS  All 240 pixels of scanline 80 = backdrop green');
      Inc(PassCount);
    end
    else
    begin
      Writeln('  FAIL  Backdrop not uniform — first mismatched pixel x=', x);
      Inc(FailCount);
    end;
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestSingleBg0Tile;
{ Set up BG0 with a single tile filled with palette index 1 ; verify the
  rendered pixel is the configured palette[1] color.

  VRAM layout:
    char base block 0 (offset $0000 = VRAM[0]) — tile 0 at offset $0000
    screen base block 0 (offset $0000 — overlaps with char block 0!  Real
      hardware doesn't restrict this; software just has to be careful. For
      this minimal test we use char block 1 ($4000) for tiles and screen
      block 0 ($0000) for the tilemap.) }
var
  mem: TGbaMemory;
  ppu: TGbaPpu;
  red: THalf;
  expected: TWord;
  fb: PFrameBuffer;
  bg0cnt: THalf;
begin
  Writeln('--- TestSingleBg0Tile ---');
  mem := TGbaMemory.Create;
  ppu := TGbaPpu.Create(mem);
  try
    { Palette: index 0 = blue (so backdrop is distinguishable), index 1 = red. }
    WriteBgPalette(mem, 0, MakeBgr555(0, 0, 31));
    red := MakeBgr555(31, 0, 0);
    WriteBgPalette(mem, 1, red);
    expected := ExpandColor(red);

    { Tile 0 at char-block 1 (VRAM offset $4000): all pixels = palette index 1. }
    FillTile4bppConstant(mem, $4000, 1);

    { Tilemap entry (0,0) at screen-block 0 (VRAM offset $0000): tile 0, no flip,
      palette bank 0. So entry value = 0. The tilemap is already zero-initialized
      by Create, but write explicitly for clarity. }
    WriteVramHalf(mem, $0000, $0000);

    { BG0CNT: priority 0, char base block 1 (bits 3:2 = 01), 4bpp, screen base
      block 0, screen size 0. = bit2 set = $0004. }
    bg0cnt := $0004;
    SetIoHalf(mem, REG_BG0CNT, bg0cnt);
    SetIoHalf(mem, REG_BG0HOFS, 0);
    SetIoHalf(mem, REG_BG0VOFS, 0);

    { DISPCNT: mode 0, BG0 enabled (bit 8). }
    SetIoHalf(mem, REG_DISPCNT, $0100);

    ppu.RenderScanline(0);
    fb := ppu.FrameBufferPtr;

    CheckEq('Pixel (0,0) is palette[1] red', expected, fb^[0]);
    CheckEq('Pixel (7,0) is still palette[1] red (inside tile 0)', expected, fb^[7]);

    { Pixel (8,0) is outside tile 0 — the next tilemap entry (1,0) is also 0
      because we initialized memory to 0, which points to tile 0. So it's
      still red. Past the tilemap entry (32 tiles × 8 pixels = 256 px) we'd
      wrap to (0,0) again — and tile 0 is still all red. The whole scanline
      is red. }
    CheckEq('Pixel (100,0) still red (everything maps to tile 0)', expected, fb^[100]);
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestTransparentPixelShowsBackdrop;
{ Tile 0 filled with palette index 0 (transparent). Tilemap points at tile 0.
  Result: every pixel is the backdrop (palette[0]) — the tile's "transparent"
  index falls through to the backdrop. }
var
  mem: TGbaMemory;
  ppu: TGbaPpu;
  expected: TWord;
  fb: PFrameBuffer;
begin
  Writeln('--- TestTransparentPixelShowsBackdrop ---');
  mem := TGbaMemory.Create;
  ppu := TGbaPpu.Create(mem);
  try
    WriteBgPalette(mem, 0, MakeBgr555(31, 31, 0));   { backdrop = yellow }
    WriteBgPalette(mem, 1, MakeBgr555(0, 0, 31));    { irrelevant — never used }
    expected := ExpandColor(MakeBgr555(31, 31, 0));

    { Tile 0: all pixels = index 0 (transparent). Memory is already zero,
      but write explicit zeros for clarity. }
    FillTile4bppConstant(mem, $4000, 0);

    SetIoHalf(mem, REG_BG0CNT, $0004);
    SetIoHalf(mem, REG_DISPCNT, $0100);

    ppu.RenderScanline(50);
    fb := ppu.FrameBufferPtr;

    CheckEq('Transparent tile shows backdrop at (10, 50)',
            expected, fb^[50 * GBA_WIDTH + 10]);
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestPaletteBankSelection;
{ 4bpp tiles use a sub-palette selected by the tilemap entry's palette bank
  (bits 15:12). Verify the same tile rendered with two different palette
  banks produces two different colors.

  Tile 0: every pixel = sub-palette-index 1.
  Tilemap entry (0,0): tile 0, palette bank 0  → uses palette[0 * 16 + 1] = palette[1]
  Tilemap entry (1,0): tile 0, palette bank 2  → uses palette[2 * 16 + 1] = palette[33] }
var
  mem: TGbaMemory;
  ppu: TGbaPpu;
  exp1, exp33: TWord;
  fb: PFrameBuffer;
begin
  Writeln('--- TestPaletteBankSelection ---');
  mem := TGbaMemory.Create;
  ppu := TGbaPpu.Create(mem);
  try
    WriteBgPalette(mem, 0,  MakeBgr555(0, 0, 0));     { backdrop black }
    WriteBgPalette(mem, 1,  MakeBgr555(31, 0, 0));    { palette[1]  = red }
    WriteBgPalette(mem, 33, MakeBgr555(0, 31, 0));    { palette[33] = green }
    exp1  := ExpandColor(MakeBgr555(31, 0, 0));
    exp33 := ExpandColor(MakeBgr555(0, 31, 0));

    FillTile4bppConstant(mem, $4000, 1);

    { Tilemap entry (0,0): tile=0, pal bank 0 = $0000. }
    WriteVramHalf(mem, $0000, $0000);
    { Tilemap entry (1,0): tile=0, pal bank 2 = $2000. }
    WriteVramHalf(mem, $0002, $2000);

    SetIoHalf(mem, REG_BG0CNT, $0004);
    SetIoHalf(mem, REG_DISPCNT, $0100);

    ppu.RenderScanline(0);
    fb := ppu.FrameBufferPtr;

    CheckEq('Pixel (0,0) uses palette bank 0 → palette[1] (red)',  exp1,  fb^[0]);
    CheckEq('Pixel (8,0) uses palette bank 2 → palette[33] (green)', exp33, fb^[8]);
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestHorizontalScroll;
{ Place a tile with index 5 at tilemap entry (1, 0). With scroll=0, this
  tile is at screen x ∈ [8..15]. With BG0HOFS=8, this tile shifts left to
  screen x ∈ [0..7] (because scroll moves the viewing window right, so the
  tile appears to move left).

  Tile 0 is "transparent" (palette index 0).
  Tile 1 is "red" (palette index 1 fill).

  Tilemap [0,0]=0, [1,0]=1, all others = 0. Backdrop = blue (palette[0]). }
var
  mem: TGbaMemory;
  ppu: TGbaPpu;
  expRed, expBackdrop: TWord;
  fb: PFrameBuffer;
begin
  Writeln('--- TestHorizontalScroll ---');
  mem := TGbaMemory.Create;
  ppu := TGbaPpu.Create(mem);
  try
    WriteBgPalette(mem, 0, MakeBgr555(0, 0, 31));    { backdrop = blue }
    WriteBgPalette(mem, 1, MakeBgr555(31, 0, 0));    { red }
    expRed      := ExpandColor(MakeBgr555(31, 0, 0));
    expBackdrop := ExpandColor(MakeBgr555(0, 0, 31));

    { Tile 0: transparent ; Tile 1: solid index 1. }
    FillTile4bppConstant(mem, $4000 + 0 * 32, 0);
    FillTile4bppConstant(mem, $4000 + 1 * 32, 1);
    { Tilemap: entry (0,0) = tile 0 (transparent), entry (1,0) = tile 1 (red). }
    WriteVramHalf(mem, $0000, $0000);
    WriteVramHalf(mem, $0002, $0001);

    SetIoHalf(mem, REG_BG0CNT, $0004);
    SetIoHalf(mem, REG_BG0HOFS, $0008);    { scroll right by 8 pixels }
    SetIoHalf(mem, REG_DISPCNT, $0100);

    ppu.RenderScanline(0);
    fb := ppu.FrameBufferPtr;

    CheckEq('Pixel (0,0): red tile scrolled into view', expRed, fb^[0]);
    CheckEq('Pixel (8,0): past the red tile, transparent → backdrop',
            expBackdrop, fb^[8]);
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestHorizontalFlip;
{ Build a tile with a horizontal pattern: pixel 0 = pal 1 (red), pixels
  1..7 = pal 2 (green). Render it twice in the tilemap — once unflipped,
  once with HFlip — and verify the leftmost pixel of the flipped instance
  is green (the originally-rightmost pixel). }
var
  mem: TGbaMemory;
  ppu: TGbaPpu;
  expRed, expGreen: TWord;
  fb: PFrameBuffer;
  row: Integer;
  b: TByte;
begin
  Writeln('--- TestHorizontalFlip ---');
  mem := TGbaMemory.Create;
  ppu := TGbaPpu.Create(mem);
  try
    WriteBgPalette(mem, 0, MakeBgr555(0, 0, 0));     { backdrop black }
    WriteBgPalette(mem, 1, MakeBgr555(31, 0, 0));    { red }
    WriteBgPalette(mem, 2, MakeBgr555(0, 31, 0));    { green }
    expRed   := ExpandColor(MakeBgr555(31, 0, 0));
    expGreen := ExpandColor(MakeBgr555(0, 31, 0));

    { Tile 0 — 8 rows of [1, 2, 2, 2, 2, 2, 2, 2].
      Each row is 4 bytes = 2 halfwords (2 pixels per byte, low nibble = even x).
        halfword [b0,b1] = ($22 << 8) | $21 = $2221  → px0=1, px1=2, px2=2, px3=2
        halfword [b2,b3] = ($22 << 8) | $22 = $2222  → px4=2, px5=2, px6=2, px7=2
      Important: must use halfword writes because VRAM byte-writes
      duplicate the byte to fill a halfword (per GBA spec) which would
      clobber neighboring pixels. Real GBA software never byte-writes
      tile data — it DMAs in word chunks. }
    for row := 0 to 7 do
    begin
      WriteVramHalf(mem, $4000 + TWord(row) * 4 + 0, $2221);
      WriteVramHalf(mem, $4000 + TWord(row) * 4 + 2, $2222);
    end;
    b := 0; if b = 0 then ;   { silence unused }

    { Tilemap: entry (0,0) = tile 0 unflipped. Entry (1,0) = tile 0 with HFlip. }
    WriteVramHalf(mem, $0000, $0000);
    WriteVramHalf(mem, $0002, $0400);    { HFlip = bit 10 }

    SetIoHalf(mem, REG_BG0CNT, $0004);
    SetIoHalf(mem, REG_DISPCNT, $0100);

    ppu.RenderScanline(0);
    fb := ppu.FrameBufferPtr;

    CheckEq('Pixel (0,0) unflipped: red',          expRed,   fb^[0]);
    CheckEq('Pixel (7,0) unflipped: green',        expGreen, fb^[7]);
    CheckEq('Pixel (8,0) HFlip: now green (was leftmost-of-unflipped tile = red)',
            expGreen, fb^[8]);
    CheckEq('Pixel (15,0) HFlip: now red (was rightmost of unflipped tile = green)',
            expRed,   fb^[15]);
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestWideMap64x32;
{ Text-BG screen size 1 (512x256 = 64x32 tiles): columns 0..31 come from
  the base screenblock, columns 32..63 from base+1. Layout mirrors a real
  wide-map cart: tiles in charblock 0, maps in screenblocks 8 and 9.

  Tile 1 = solid index 1. Map: SB8 entry (0,0) = tile 1 bank 0 (red);
  SB9 entry (0,0) = tile 1 bank 2 (green); SB9 entry (31,0) = tile 1
  bank 3 (yellow) = map column 63. Everything else transparent tile 0.

  HOFS=0   -> screen x0 shows map col 0  (red from SB8)
  HOFS=256 -> screen x0 shows map col 32 (green from SB9)
  HOFS=504 -> screen x0 shows map col 63 (yellow), x8 wraps to col 0 (red) }
var
  mem: TGbaMemory;
  ppu: TGbaPpu;
  expRed, expGreen, expYellow, expBd: TWord;
  fb: PFrameBuffer;
begin
  Writeln('--- TestWideMap64x32 ---');
  mem := TGbaMemory.Create;
  ppu := TGbaPpu.Create(mem);
  try
    WriteBgPalette(mem, 0,  MakeBgr555(0, 0, 31));     { backdrop blue }
    WriteBgPalette(mem, 1,  MakeBgr555(31, 0, 0));     { bank 0 red }
    WriteBgPalette(mem, 33, MakeBgr555(0, 31, 0));     { bank 2 green }
    WriteBgPalette(mem, 49, MakeBgr555(31, 31, 0));    { bank 3 yellow }
    expRed    := ExpandColor(MakeBgr555(31, 0, 0));
    expGreen  := ExpandColor(MakeBgr555(0, 31, 0));
    expYellow := ExpandColor(MakeBgr555(31, 31, 0));
    expBd     := ExpandColor(MakeBgr555(0, 0, 31));

    { Charblock 0: tile 0 transparent, tile 1 solid index 1. }
    FillTile4bppConstant(mem, 0 * 32, 0);
    FillTile4bppConstant(mem, 1 * 32, 1);

    { SB8 ($4000): entry (0,0) = tile 1, bank 0. }
    WriteVramHalf(mem, $4000, $0001);
    { SB9 ($4800): entry (0,0) = tile 1, bank 2 -> map column 32. }
    WriteVramHalf(mem, $4800, $2001);
    { SB9 entry (31,0) = tile 1, bank 3 -> map column 63. }
    WriteVramHalf(mem, $4800 + 31 * 2, $3001);

    { BG0CNT: prio 0, charblock 0, 4bpp, screenbase 8, size 1 (64x32). }
    SetIoHalf(mem, REG_BG0CNT, THalf((8 shl 8) or (1 shl 14)));
    SetIoHalf(mem, REG_DISPCNT, $0100);

    SetIoHalf(mem, REG_BG0HOFS, 0);
    ppu.RenderScanline(0);
    fb := ppu.FrameBufferPtr;
    CheckEq('HOFS=0: x0 = map col 0 from SB8 (red)',   expRed, fb^[0]);
    CheckEq('HOFS=0: x8 = transparent -> backdrop',    expBd,  fb^[8]);

    SetIoHalf(mem, REG_BG0HOFS, 256);
    ppu.RenderScanline(0);
    CheckEq('HOFS=256: x0 = map col 32 from SB9 (green)', expGreen, fb^[0]);

    SetIoHalf(mem, REG_BG0HOFS, 504);
    ppu.RenderScanline(0);
    CheckEq('HOFS=504: x0 = map col 63 from SB9 (yellow)', expYellow, fb^[0]);
    CheckEq('HOFS=504: x8 wraps to map col 0 (red)',       expRed,    fb^[8]);
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestPriorityCompositing;
{ Two BGs with different priorities. BG0 has priority 1, BG1 has priority 0
  (higher). Where both layers are opaque, BG1 must show through. Where BG1
  is transparent, BG0 must show.

  Setup:
    Tile 0 = transparent
    Tile 1 = solid red (palette index 1, will use pal bank 0)
    Tile 2 = solid green
  BG0:
    char-base = block 1 ($4000), screen-base = 0
    tilemap: every entry = tile 1 (red)
    priority = 1
  BG1:
    char-base = block 1 ($4000)  (shared char data)
    screen-base = 1 ($0800)
    tilemap [0,0] = tile 2 (green), all other entries = 0 (transparent)
    priority = 0  (higher than BG0)

  Expected scanline 0:
    pixel (0..7) = green (BG1 on top of BG0)
    pixel (8..239) = red  (BG1 transparent, BG0 red shows through) }
var
  mem: TGbaMemory;
  ppu: TGbaPpu;
  expRed, expGreen: TWord;
  fb: PFrameBuffer;
  i: Integer;
begin
  Writeln('--- TestPriorityCompositing ---');
  mem := TGbaMemory.Create;
  ppu := TGbaPpu.Create(mem);
  try
    WriteBgPalette(mem, 0, MakeBgr555(0, 0, 0));      { backdrop black }
    WriteBgPalette(mem, 1, MakeBgr555(31, 0, 0));     { red }
    WriteBgPalette(mem, 2, MakeBgr555(0, 31, 0));     { green }
    expRed   := ExpandColor(MakeBgr555(31, 0, 0));
    expGreen := ExpandColor(MakeBgr555(0, 31, 0));

    FillTile4bppConstant(mem, $4000 + 0 * 32, 0);     { tile 0 transparent }
    FillTile4bppConstant(mem, $4000 + 1 * 32, 1);     { tile 1 red }
    FillTile4bppConstant(mem, $4000 + 2 * 32, 2);     { tile 2 green }

    { BG0 tilemap at screen-block 0: every entry = tile 1. }
    for i := 0 to 31 * 32 + 31 do
      WriteVramHalf(mem, TWord(i) * 2, $0001);

    { BG1 tilemap at screen-block 1 ($0800): entry (0,0) = tile 2,
      rest = tile 0 (transparent). }
    WriteVramHalf(mem, $0800, $0002);
    for i := 1 to 31 * 32 + 31 do
      WriteVramHalf(mem, $0800 + TWord(i) * 2, $0000);

    { BG0CNT: priority 1, char-base 1 ($0001 in priority field, $0004 in char base) → $0005. }
    SetIoHalf(mem, REG_BG0CNT, $0005);
    { BG1CNT: priority 0, char-base 1, screen-base 1 ($0100 in screen-base bits 12:8). }
    SetIoHalf(mem, REG_BG1CNT, $0004 or $0100);
    { DISPCNT: mode 0, BG0 (bit 8) and BG1 (bit 9) enabled. }
    SetIoHalf(mem, REG_DISPCNT, $0300);

    ppu.RenderScanline(0);
    fb := ppu.FrameBufferPtr;

    CheckEq('Pixel (0,0): BG1 green wins (higher priority)',  expGreen, fb^[0]);
    CheckEq('Pixel (8,0): BG1 transparent → BG0 red shows',   expRed,   fb^[8]);
    CheckEq('Pixel (100,0): same — BG0 red',                  expRed,   fb^[100]);
  finally
    ppu.Free; mem.Free;
  end;
end;

procedure TestPpmDump;
{ End-to-end visual smoke test: build a checkerboard pattern, render a
  full frame, dump it to a PPM. We don't assert on the file contents (the
  rendering math is already covered by other tests) — this is the artifact
  the operator can open to confirm the PPU renders something sensible. }
var
  mem: TGbaMemory;
  ppu: TGbaPpu;
  i: Integer;
  outPath: string;
  tileIdx: Integer;
begin
  Writeln('--- TestPpmDump ---');
  mem := TGbaMemory.Create;
  ppu := TGbaPpu.Create(mem);
  try
    { Palette: 0=dark, 1=red, 2=cyan, 3=yellow, 4=magenta. }
    WriteBgPalette(mem, 0, MakeBgr555(2, 2, 2));
    WriteBgPalette(mem, 1, MakeBgr555(31, 0, 0));
    WriteBgPalette(mem, 2, MakeBgr555(0, 31, 31));
    WriteBgPalette(mem, 3, MakeBgr555(31, 31, 0));
    WriteBgPalette(mem, 4, MakeBgr555(31, 0, 31));

    { Tiles 0..3 solid in palette indexes 1..4. }
    for i := 0 to 3 do
      FillTile4bppConstant(mem, $4000 + TWord(i) * 32, i + 1);

    { Tilemap: for each tile (tx,ty), set entry = tile index = (tx + ty) & 3. }
    for i := 0 to 31 * 32 + 31 do
    begin
      tileIdx := (((i mod 32) + (i div 32)) and 3);
      WriteVramHalf(mem, TWord(i) * 2, THalf(tileIdx));
    end;

    SetIoHalf(mem, REG_BG0CNT, $0004);
    SetIoHalf(mem, REG_DISPCNT, $0100);

    ppu.RenderFrame;

    outPath := ExtractFilePath(ParamStr(0)) + 'ppu_frame.ppm';
    ppu.DumpPpm(outPath);
    Writeln('  INFO  PPM dumped to ', outPath);
    Writeln('  PASS  Frame rendered without crashing');
    Inc(PassCount);
  finally
    ppu.Free; mem.Free;
  end;
end;

begin
  Writeln('PPU acceptance tests');
  Writeln('==========================================');
  Writeln('');
  TestBackdropColor;                 Writeln('');
  TestSingleBg0Tile;                 Writeln('');
  TestTransparentPixelShowsBackdrop; Writeln('');
  TestPaletteBankSelection;          Writeln('');
  TestHorizontalScroll;              Writeln('');
  TestHorizontalFlip;                Writeln('');
  TestWideMap64x32;                  Writeln('');
  TestPriorityCompositing;           Writeln('');
  TestPpmDump;                       Writeln('');
  Writeln('==========================================');
  Writeln(Format('Result: %d pass, %d fail', [PassCount, FailCount]));
  if FailCount > 0 then Halt(1);
end.
