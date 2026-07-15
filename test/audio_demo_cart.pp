program audio_demo_cart;
{
  Kit_Audio demo cart: the bundled tune loops from boot; each button
  fires one voice of the canned SFX vocabulary. Named _cart to keep
  clear of the host-side audio_smoke/audio tests.

    A      tap        B      pop
    UP     grab       DOWN   drop
    LEFT   boing      RIGHT  sparkle
    START  music stop/restart

  Build:  .\build-gba.ps1 test\audio_demo_cart
  Ear check (windowed):
          .\bin\gbarun.exe --rom test\audio_demo_cart.gba --frames 0
  Headless capture:
          .\bin\gbarun.exe --rom test\audio_demo_cart.gba --headless ^
              --frames 600 --dump-audio bin\audio_demo.wav

  The tune data is generated: tools\song.py test\songs\demo.song
  (see docs\kit.md for the score format).
}

{$mode objfpc}{$H+}

uses
  Gba_Dbg, Kit_Input, Kit_Audio;

{$I songs/demo.inc}

const
  REG_DISPCNT = $04000000;
  REG_VCOUNT  = $04000006;
  VRAM_BASE   = $06000000;
  SCREEN_W    = 240;
  SCREEN_H    = 160;

  COL_BG     = 8 or (5 shl 5) or (14 shl 10);
  COL_BEAT1  = 31 or (28 shl 5) or (8 shl 10);
  COL_BEAT2  = 14 or (12 shl 5) or (6 shl 10);

var
  frame: LongWord;
  beatOn: Boolean;

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

begin
  PWord(REG_DISPCNT)^ := $0403;

  DbgLogStr('audio_demo: boot');
  DbgLogWaitConsumedBounded(4);

  FillRect(0, 0, SCREEN_W, SCREEN_H, COL_BG);

  AudioInit;
  MusicPlay(@SongDemoLead[0], SongDemoLeadCount,
            @SongDemoNoise[0], SongDemoNoiseCount, SongDemoLoop);

  DbgLogStr('audio_demo: music on');
  DbgLogWaitConsumedBounded(4);

  frame := 0;
  beatOn := False;

  while True do
  begin
    WaitVBlank;
    InputUpdate;
    MusicTick;

    if (KeysPressed and KEY_A)     <> 0 then SfxTap;
    if (KeysPressed and KEY_B)     <> 0 then SfxPop;
    if (KeysPressed and KEY_UP)    <> 0 then SfxGrab;
    if (KeysPressed and KEY_DOWN)  <> 0 then SfxDrop;
    if (KeysPressed and KEY_LEFT)  <> 0 then SfxBoing;
    if (KeysPressed and KEY_RIGHT) <> 0 then SfxSparkle;

    if (KeysPressed and KEY_START) <> 0 then
    begin
      if MusicPlaying then
        MusicStop
      else
        MusicPlay(@SongDemoLead[0], SongDemoLeadCount,
                  @SongDemoNoise[0], SongDemoNoiseCount, SongDemoLoop);
    end;

    { Visible pulse so a silent screen is still provably alive. }
    if (frame mod 30) = 0 then
    begin
      beatOn := not beatOn;
      if beatOn then FillRect(110, 70, 20, 20, COL_BEAT1)
                else FillRect(110, 70, 20, 20, COL_BEAT2);
    end;

    Inc(frame);
  end;
end.
