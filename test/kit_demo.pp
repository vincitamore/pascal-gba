program kit_demo;
{
  Framework-kit demo cart: exercises every spine unit on real cart
  code paths.

    Kit_Scene  two scenes (menu <-> play), switch semantics
    Kit_Input  edge-detected A/B, held d-pad
    Kit_Rng    seeded deterministic block field (same layout every run)
    Kit_Fixed  sub-pixel player movement (1.5 px/frame)
    Kit_Save   verified SRAM writes with checksum (press counter
               persists across power cycles)
    Gba_Dbg    bounded ready-byte flush (device-safe narration)

  Menu: dark screen, pulsing center bar. A -> play.
  Play: green field, 12 seed-fixed blocks, orange player block moves
  with the d-pad at 1.5 px/frame; A stamps a new block at a random
  spot and bumps the persisted counter; B -> menu.

  Build:  .\build-gba.ps1 test\kit_demo
  Run:    .\bin\gbarun.exe --rom test\kit_demo.gba --headless --frames 300
  The block field is deterministic (seed 1), so screenshots of the
  play scene are replay-stable.
}

{$mode objfpc}{$H+}

uses
  Gba_Dbg, Kit_Scene, Kit_Input, Kit_Rng, Kit_Fixed, Kit_Save;

const
  REG_DISPCNT = $04000000;
  REG_VCOUNT  = $04000006;
  VRAM_BASE   = $06000000;
  SCREEN_W    = 240;
  SCREEN_H    = 160;

  SCENE_MENU = 0;
  SCENE_PLAY = 1;

  COL_NIGHT  = 5 or (4 shl 5) or (11 shl 10);
  COL_BAR    = 31 or (28 shl 5) or (6 shl 10);
  COL_BAR_DIM = 12 or (11 shl 5) or (6 shl 10);
  COL_FIELD  = 9 or (20 shl 5) or (12 shl 10);
  COL_PLAYER = 31 or (17 shl 5) or (6 shl 10);

  { Demo save layout: magic 'KDEM' + press count (LE word) + XOR
    checksum of bytes 0..5. }
  DEMO_MAGIC: array[0..3] of Char = ('K','D','E','M');

{ Globals only — locals do not survive DbgLogStr (docs/debugging.md). }
var
  pressCount: Word;
  saveFresh: Boolean;
  px, py: TFixed;              { player position, 24.8 }
  oldX, oldY: Integer;
  i: Integer;

procedure WaitVBlank;
begin
  while PWord(REG_VCOUNT)^ >= 160 do ;
  while PWord(REG_VCOUNT)^ <  160 do ;
end;

procedure PutPixel(x, y: Integer; c: Word);
begin
  if (x < 0) or (x >= SCREEN_W) or (y < 0) or (y >= SCREEN_H) then Exit;
  PWord(VRAM_BASE + (y * SCREEN_W + x) * 2)^ := c;
end;

procedure FillRect(x, y, w, h: Integer; c: Word);
var
  ax, ay: Integer;
begin
  for ay := y to y + h - 1 do
    for ax := x to x + w - 1 do
      PutPixel(ax, ay, c);
end;

{ ── Save helpers ── }

procedure SaveLoad;
var
  buf: array[0..6] of Byte;
  k: Integer;
  ok: Boolean;
begin
  SramReadBlock(0, @buf[0], 7);
  ok := True;
  for k := 0 to 3 do
    if buf[k] <> Byte(DEMO_MAGIC[k]) then ok := False;
  if ok and (KitXorChecksum(@buf[0], 6) <> buf[6]) then ok := False;

  if ok then
  begin
    pressCount := Word(buf[4]) or (Word(buf[5]) shl 8);
    saveFresh := False;
  end
  else
  begin
    pressCount := 0;
    saveFresh := True;
  end;
end;

function SaveStore: Boolean;
var
  buf: array[0..6] of Byte;
  k: Integer;
begin
  for k := 0 to 3 do buf[k] := Byte(DEMO_MAGIC[k]);
  buf[4] := Byte(pressCount and $FF);
  buf[5] := Byte(pressCount shr 8);
  buf[6] := KitXorChecksum(@buf[0], 6);
  Result := SramWriteVerified(0, @buf[0], 7);
end;

{ ── Menu scene ── }

procedure MenuInit;
begin
  FillRect(0, 0, SCREEN_W, SCREEN_H, COL_NIGHT);
  DbgLogStr('kit_demo: menu');
  DbgLogWaitConsumedBounded(4);
end;

procedure MenuUpdate;
begin
  { Pulsing center bar — SceneFrames drives the blink. }
  if (SceneFrames mod 30) = 0 then
    FillRect(70, 74, 100, 12, COL_BAR)
  else if (SceneFrames mod 30) = 15 then
    FillRect(70, 74, 100, 12, COL_BAR_DIM);

  if (KeysPressed and KEY_A) <> 0 then
    SceneSwitch(SCENE_PLAY);
end;

{ ── Play scene ── }

procedure StampRandomBlock;
var
  bx, by: Integer;
  c: Word;
begin
  bx := 8 + Integer(RngRange(SCREEN_W - 24));
  by := 8 + Integer(RngRange(SCREEN_H - 24));
  c  := Word(RngRange(32768)) or $0421;   { keep it visibly bright }
  FillRect(bx, by, 8, 8, c);
end;

procedure PlayInit;
begin
  FillRect(0, 0, SCREEN_W, SCREEN_H, COL_FIELD);

  { Deterministic field: same seed, same layout, every run — this is
    what makes play-scene screenshots replay-stable. }
  RngSeed(1);
  for i := 0 to 11 do
    StampRandomBlock;

  px := FixFromInt(114);
  py := FixFromInt(74);
  oldX := FixToInt(px);
  oldY := FixToInt(py);
  FillRect(oldX, oldY, 12, 12, COL_PLAYER);

  DbgLogStr('kit_demo: play');
  DbgLogWaitConsumedBounded(4);
end;

procedure PlayUpdate;
const
  SPEED = FIX_ONE + FIX_HALF;   { 1.5 px/frame through Kit_Fixed }
var
  nx, ny: Integer;
begin
  if (KeysHeld and KEY_LEFT)  <> 0 then px := px - SPEED;
  if (KeysHeld and KEY_RIGHT) <> 0 then px := px + SPEED;
  if (KeysHeld and KEY_UP)    <> 0 then py := py - SPEED;
  if (KeysHeld and KEY_DOWN)  <> 0 then py := py + SPEED;

  if px < 0 then px := 0;
  if px > FixFromInt(SCREEN_W - 12) then px := FixFromInt(SCREEN_W - 12);
  if py < 0 then py := 0;
  if py > FixFromInt(SCREEN_H - 12) then py := FixFromInt(SCREEN_H - 12);

  nx := FixToInt(px);
  ny := FixToInt(py);
  if (nx <> oldX) or (ny <> oldY) then
  begin
    FillRect(oldX, oldY, 12, 12, COL_FIELD);
    FillRect(nx, ny, 12, 12, COL_PLAYER);
    oldX := nx;
    oldY := ny;
  end;

  if (KeysPressed and KEY_A) <> 0 then
  begin
    StampRandomBlock;
    Inc(pressCount);
    if SaveStore then
      DbgLogStr('kit_demo: save ok')
    else
      DbgLogStr('kit_demo: save FAIL');
  end;

  if (KeysPressed and KEY_B) <> 0 then
    SceneSwitch(SCENE_MENU);
end;

begin
  PWord(REG_DISPCNT)^ := $0403;   { mode 3, BG2 }
  SramInit;

  DbgLogStr('kit_demo: boot');
  DbgLogWaitConsumedBounded(4);

  SaveLoad;
  if saveFresh then
    DbgLogStr('kit_demo: save fresh')
  else
    DbgLogStr('kit_demo: save found');
  DbgLogWaitConsumedBounded(4);

  SceneRegister(SCENE_MENU, @MenuInit, @MenuUpdate);
  SceneRegister(SCENE_PLAY, @PlayInit, @PlayUpdate);
  SceneSwitch(SCENE_MENU);

  while True do
  begin
    WaitVBlank;
    InputUpdate;
    SceneTick;
  end;
end.
