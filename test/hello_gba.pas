program hello_gba;
{
  Phase C smoke test — first pixels on screen from the real PPU pipeline.

  Constructs Memory + PPU + Display, populates palette/VRAM with a
  recognizable pattern (a checkerboard with scrolling), and runs a 60 FPS
  main loop that scrolls the BG horizontally so the operator can see
  motion (proving the loop isn't just rendering one static frame).

  No CPU involved — this is the PPU + Display path. The CPU integration
  comes next (running real ARM/THUMB code that writes the registers we're
  writing here directly). Esc closes the window.
}

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, GbaTypes, Memory, Ppu, Display;

procedure SetupScene(mem: TGbaMemory);
const
  ColorCount = 5;
  Colors: array[0..ColorCount-1] of record r, g, b: Integer end = (
    (r:  3; g:  3; b:  5),     { backdrop: dark blue }
    (r: 31; g: 12; b: 16),     { warm red }
    (r:  4; g: 28; b: 18),     { teal }
    (r: 28; g: 24; b:  6),     { gold }
    (r: 18; g: 10; b: 28)      { violet }
  );
var
  i, tileX, tileY: Integer;
  tileIdx: Integer;
  tilemapEntry: THalf;
  r, g, b: Integer;
  bgr: THalf;
  byteVal: TByte;
  halfVal: THalf;
  row: Integer;
begin
  { Palette entries 0..4. }
  for i := 0 to ColorCount - 1 do
  begin
    r := Colors[i].r;
    g := Colors[i].g;
    b := Colors[i].b;
    bgr := THalf((b and $1F) shl 10) or THalf((g and $1F) shl 5) or THalf(r and $1F);
    mem.WriteHalf($05000000 + TWord(i) * 2, bgr);
  end;

  { Tile 0 = transparent (palette index 0). Tile 1..4 = solid palette
    indices 1..4. We use halfword writes for tile data (byte writes to
    VRAM duplicate the byte across the halfword which corrupts adjacent
    pixels — that quirk is correct GBA behavior). }
  for tileIdx := 0 to 4 do
  begin
    byteVal := TByte((tileIdx and $F) or ((tileIdx and $F) shl 4));
    halfVal := THalf(byteVal) or (THalf(byteVal) shl 8);
    for row := 0 to 7 do
    begin
      mem.WriteHalf($06000000 + $4000 + TWord(tileIdx) * 32 + TWord(row) * 4 + 0, halfVal);
      mem.WriteHalf($06000000 + $4000 + TWord(tileIdx) * 32 + TWord(row) * 4 + 2, halfVal);
    end;
  end;

  { Tilemap at screen-block 0. 32×32 entries. Pattern: small diamonds
    centered on a 5×5 grid of cells, with tile indices cycling through
    1..4 so we get four distinct colors. }
  for tileY := 0 to 31 do
    for tileX := 0 to 31 do
    begin
      if ((tileX mod 5) = 0) and ((tileY mod 5) = 0) then
        tilemapEntry := $0001                { red blocks at grid intersections }
      else if (((tileX + tileY) mod 4) = 0) then
        tilemapEntry := $0002                { teal }
      else if (((tileX + tileY * 2) mod 7) = 0) then
        tilemapEntry := $0003                { gold }
      else if (((tileX * 3 + tileY) mod 9) = 0) then
        tilemapEntry := $0004                { violet }
      else
        tilemapEntry := $0000;               { transparent → backdrop shows }
      mem.WriteHalf($06000000 + TWord(tileY) * 32 * 2 + TWord(tileX) * 2, tilemapEntry);
    end;

  { BG0CNT: char base block 1, screen base block 0, 4bpp, screen size 0. }
  mem.WriteHalf($04000000 + $008, $0004);
  { BG0HOFS, BG0VOFS — initialized to 0; will be animated by the main loop. }
  mem.WriteHalf($04000000 + $010, 0);
  mem.WriteHalf($04000000 + $012, 0);

  { DISPCNT: mode 0, BG0 enabled. }
  mem.WriteHalf($04000000 + $000, $0100);
end;

procedure CopyFrameBuffer(src, dst: Pointer; pixelCount: Integer);
begin
  Move(src^, dst^, pixelCount * 4);
end;

const
  WindowScale = 3;

var
  mem: TGbaMemory;
  gpu: TGbaPpu;
  disp: TGbaDisplay;
  frame: Int64;
  scrollX, scrollY: Integer;
  qpcFreq, startTs, endTs: Int64;
  elapsedSec: Double;
begin
  Writeln('Hello, GBA — first pixels on screen.');
  Writeln('Esc closes the window.');

  mem := TGbaMemory.Create;
  gpu := TGbaPpu.Create(mem);
  disp := TGbaDisplay.Create(WindowScale, 'Pascal GBA — Phase C');
  try
    SetupScene(mem);

    QueryPerformanceFrequency(qpcFreq);
    QueryPerformanceCounter(startTs);

    frame := 0;
    while disp.IsOpen do
    begin
      { Animate: scroll BG0 horizontally + vertically over time. The PPU
        reads BG0HOFS/VOFS on each scanline, so updating these between
        frames produces motion. }
      scrollX := Integer(frame) and $FF;
      scrollY := (Integer(frame) shr 1) and $FF;
      mem.WriteHalf($04000000 + $010, THalf(scrollX));
      mem.WriteHalf($04000000 + $012, THalf(scrollY));

      gpu.RenderFrame;

      { Copy the PPU framebuffer into the display's DIB. Both are 240×160
        words; one Move is enough. (Future optimization: have the PPU
        write directly into the DIB. For now we keep them separate so the
        PPU has no Win32 dependency.) }
      CopyFrameBuffer(gpu.FrameBufferPtr, disp.FrameBufferPtr,
                      GBA_DISPLAY_W * GBA_DISPLAY_H);

      if not disp.Present then Break;

      Inc(frame);

      { Run for ~5 seconds then auto-close (so a hands-off test doesn't
        hang the build pipeline). Operator can still close early with Esc. }
      if frame >= 300 then Break;
    end;

    QueryPerformanceCounter(endTs);
    elapsedSec := (endTs - startTs) / qpcFreq;
    Writeln(Format('Rendered %d frames in %.2f s (%.1f FPS).',
                   [disp.FramesShown, elapsedSec, disp.FramesShown / elapsedSec]));
  finally
    disp.Free;
    gpu.Free;
    mem.Free;
  end;
end.
