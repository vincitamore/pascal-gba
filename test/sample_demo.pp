program sample_demo;
{
  Kit_Audio DirectSound sample demo: plays a short synthetic chirp
  over FIFO A on boot, then again on every A press. B stops playback.
  Music-free so FIFO activity is the only audio under test.

  Build:  .\build-gba.ps1 test\sample_demo
  Ear:    .\bin\gbarun.exe --rom test\sample_demo.gba --frames 0
  Headless capture:
          .\bin\gbarun.exe --rom test\sample_demo.gba --headless ^
              --frames 240 --dump-audio bin\sample_demo.wav

  Sample data: tools\voice.py over a short synthetic tone ->
  test\samples\hi.inc
}

{$mode objfpc}{$H+}
{$J-}

uses
  Gba_Dbg, Kit_Input, Kit_Audio;

{$I samples/hi.inc}

const
  REG_DISPCNT = $04000000;
  REG_VCOUNT  = $04000006;
  VRAM_BASE   = $06000000;
  SCREEN_W    = 240;
  SCREEN_H    = 160;

  COL_BG   = 4 or (4 shl 5) or (10 shl 10);
  COL_ON   = 8 or (28 shl 5) or (10 shl 10);
  COL_OFF  = 14 or (10 shl 5) or (8 shl 10);
  COL_TEXT = $7FFF;

var
  frame: LongWord;
  wasPlaying: Boolean;

procedure WaitVBlank;
begin
  while PWord(REG_VCOUNT)^ >= 160 do ;
  while PWord(REG_VCOUNT)^ <  160 do ;
end;

procedure FillRect(x, y, w, h: Integer; c: Word);
var
  ax, ay: Integer;
begin
  for ay := y to y + h - 1 do
    for ax := x to x + w - 1 do
      PWord(VRAM_BASE + (ay * SCREEN_W + ax) * 2)^ := c;
end;

procedure DrawStatus(playing: Boolean);
begin
  if playing then
    FillRect(100, 60, 40, 40, COL_ON)
  else
    FillRect(100, 60, 40, 40, COL_OFF);
end;

begin
  PWord(REG_DISPCNT)^ := $0403;

  DbgLogStr('sample_demo: boot');
  DbgLogWaitConsumedBounded(4);

  FillRect(0, 0, SCREEN_W, SCREEN_H, COL_BG);
  DrawStatus(False);

  AudioInit;
  SamplePlay(@SampleHiData[0], SampleHiLen, SampleHiRate);
  DbgLogStr('sample_demo: play');
  DbgLogWaitConsumedBounded(4);

  frame := 0;
  wasPlaying := True;

  while True do
  begin
    WaitVBlank;
    InputUpdate;
    MusicTick;   { advances sample frame budget + SFX second stages }

    if SamplePlaying <> wasPlaying then
    begin
      DrawStatus(SamplePlaying);
      wasPlaying := SamplePlaying;
      if not SamplePlaying then
      begin
        DbgLogStr('sample_demo: done');
        DbgLogWaitConsumedBounded(4);
      end;
    end;

    if (KeysPressed and KEY_A) <> 0 then
    begin
      SamplePlay(@SampleHiData[0], SampleHiLen, SampleHiRate);
      DbgLogStr('sample_demo: replay');
      DbgLogWaitConsumedBounded(4);
    end;
    if (KeysPressed and KEY_B) <> 0 then
      SampleStop;

    Inc(frame);
  end;
end.
