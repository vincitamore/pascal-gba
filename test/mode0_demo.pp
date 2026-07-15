program mode0_demo;
{
  Kit_Bg + Kit_Obj + Kit_Text demo cart.

  Mode-0 scene built entirely from committed test assets:
    BG0  512x160 multi-palette test field (test/bg_input.inc, 13 banks)
         -- d-pad left/right scrolls it through the 64-tile-wide map.
    BG1  text HUD (test/font8.inc glyph bank) showing a title line and
         a live HOFS readout.
    OBJ  slot 0 animates the 4-frame diamond-pulse sprite
         (test/obj_input.inc) while sliding and bouncing between the
         screen edges; A toggles horizontal flip.

  Fully deterministic (no RNG, motion from the frame counter), so
  replay screenshots are byte-stable -- test/regress/mode0_demo.case
  pins a scripted run.

  Build (from the repo root):  .\build-gba.ps1 test\mode0_demo
  Run:  .\bin\gbarun.exe --rom test\mode0_demo.gba --headless --frames 300
}

{$mode objfpc}{$H+}
{$J-}  { typed-const asset data stays in ROM (.rodata), not IWRAM }

uses
  Gba_Dbg, Kit_Input, Kit_Bg, Kit_Obj, Kit_Text;

{$I bg_input.inc}
{$I font8.inc}
{$I obj_input.inc}

const
  REG_VCOUNT = $04000006;

  SB_FIELD   = 8;      { BG0 map: screenblocks 8+9 (64x32) }
  SB_TEXT    = 10;     { BG1 map: screenblock 10 (32x32)   }
  FONT_TILE  = 64;     { font glyphs land above the field tiles }
  FONT_BANK  = 15;     { BG palette bank for text }

  CAM_MAX    = BGDEMO_W - 240;   { 512-wide field, 240-wide screen }
  OBJ_MIN_X  = 40;
  OBJ_MAX_X  = 184;
  OBJ_Y      = 72;

var
  camX:    Integer = 0;
  objX:    Integer = OBJ_MIN_X;
  objDir:  Integer = 1;
  flipped: Boolean = False;
  frame:   LongWord = 0;
  d:       Integer;

procedure WaitVBlank;
begin
  while PWord(REG_VCOUNT)^ >= 160 do ;
  while PWord(REG_VCOUNT)^ <  160 do ;
end;

{ Three-digit decimal readout at tile row 2 (no RTL formatting on -Tgba). }
procedure ShowCam;
begin
  TextPut(7, 2, Chr(Ord('0') + (camX div 100) mod 10));
  TextPut(8, 2, Chr(Ord('0') + (camX div 10) mod 10));
  TextPut(9, 2, Chr(Ord('0') + camX mod 10));
end;

begin
  DbgLogStr('mode0: boot');
  DbgLogWaitConsumedBounded(4);

  { BG0: the scrolling field. Tiles in charblock 0, map in SB 8+9. }
  BgLoadPalette(BGDEMO_PAL);
  BgLoadTiles(0, 0, BGDEMO_TILES);
  BgLoadMap(SB_FIELD, BGDEMO_MAP, BGDEMO_MAP_W, BGDEMO_MAP_H, 64);
  BgControl(0, 0, SB_FIELD, BG_SIZE_64x32, 1);

  { BG1: text HUD. Glyphs share charblock 0 above the field tiles. }
  BgLoadTiles(0, FONT_TILE, FONT8_TILES);
  BgLoadPaletteBank(FONT_BANK, FONT8_PAL);
  BgControl(1, 0, SB_TEXT, BG_SIZE_32x32, 0);
  TextAttach(SB_TEXT, FONT_TILE, FONT8_GLYPH_START, FONT8_GLYPH_COUNT,
             FONT_BANK);
  { Clear the WHOLE text screenblock: uninitialized entries are 0 =
    tile 0 of the shared charblock, which is opaque field art -- an
    uncleared text layer blankets every BG behind it. }
  TextClearRect(0, 0, 32, 32);
  TextWrite(1, 1, 'MODE0 KIT DEMO');
  TextWrite(1, 2, 'HOFS:');
  ShowCam;

  { OBJ: pulse sprite in slot 0. }
  ObjInit;
  ObjLoadTiles(0, OBJPULSE_TILES);
  ObjLoadPalette(0, OBJPULSE_PAL);
  ObjSet(0, 0, 0, OBJ_SQUARE, OBJ_SIZE_1, 0);      { 16x16, front }
  ObjSetPos(0, objX, OBJ_Y);

  BgSetMode(0, DISP_BG0 or DISP_BG1 or DISP_OBJ or DISP_OBJ_1D);

  DbgLogStr('mode0: ready');
  DbgLogWaitConsumedBounded(4);

  while True do
  begin
    WaitVBlank;
    ObjCommit;
    InputUpdate;
    Inc(frame);

    { d-pad scrolls the field }
    if (KeysHeld and KEY_LEFT)  <> 0 then Dec(camX, 2);
    if (KeysHeld and KEY_RIGHT) <> 0 then Inc(camX, 2);
    if camX < 0 then camX := 0;
    if camX > CAM_MAX then camX := CAM_MAX;
    BgScroll(0, camX, 0);
    ShowCam;

    { sprite slides, bounces, pulses }
    Inc(objX, objDir);
    if objX >= OBJ_MAX_X then begin objX := OBJ_MAX_X; objDir := -1; end;
    if objX <= OBJ_MIN_X then begin objX := OBJ_MIN_X; objDir := 1; end;
    ObjSetPos(0, objX, OBJ_Y);
    d := Integer((frame div 8) mod 4);
    ObjSetTile(0, d * 4);                          { 4 tiles per 16x16 frame }

    if (KeysPressed and KEY_A) <> 0 then
    begin
      flipped := not flipped;
      ObjSetFlip(0, flipped, False);
    end;
  end;
end.
