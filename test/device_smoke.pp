program device_smoke;
{
  Device smoke test cart. Verifies the four hardware paths a real
  handheld (or an unfamiliar emulator core) must provide before deeper
  development targets it:

    1. Boot   - mode 3 bitmap UI renders
    2. Input  - all 10 keys echo on screen while held
    3. Audio  - PSG square-channel blip on each key press (distinct
                pitch per key) + a three-note jingle shortly after boot
    4. SRAM   - a boot counter persists across power cycles; the cart
                read-verifies its own write and reports the verdict

  On screen:
    BOOT NNNNN   boot count read from SRAM (1 on first boot)
    SAVE NEW     first boot: SRAM had no marker; wrote one, verified
    SAVE OK      marker found from a previous boot AND write verified
    SAVE FAIL    read-back after write did not match (no working SRAM)
    button map   boxes fill while the matching key is held
    heartbeat    top-right block toggles every 30 frames (loop alive)

  The literal "SRAM_V113" is embedded so save-type autodetection picks
  SRAM (emulators scan the ROM image for that marker).

  DbgLog narration is emitted for the emulator's replay rig, but this
  cart deliberately never calls DbgLogWaitConsumed: nothing clears the
  ready byte on real hardware or third-party emulators, so an unbounded
  wait would hang the device. DbgFlushBounded below waits for
  consumption but gives up after four frames, so the same ROM narrates
  fully under the emulator and runs unmodified on a device.

  Build:  .\build-gba.ps1 test\device_smoke
  Run:    .\bin\gbarun.exe --rom test\device_smoke.gba --headless --frames 300 --screenshot bin\smoke.png
          Run twice: the second run's BOOT count is the first + 1
          (persisted in test\device_smoke.sav).
}

{$mode objfpc}{$H+}

uses
  Gba_Dbg;

const
  { ── Registers ── }
  REG_DISPCNT    = $04000000;
  REG_VCOUNT     = $04000006;
  REG_KEYINPUT   = $04000130;
  REG_WAITCNT    = $04000204;

  REG_SOUNDCNT_L = $04000080;
  REG_SOUNDCNT_H = $04000082;
  REG_SOUNDCNT_X = $04000084;
  REG_SOUND1CNT_L = $04000060;
  REG_SOUND1CNT_H = $04000062;
  REG_SOUND1CNT_X = $04000064;

  VRAM_BASE = $06000000;
  SRAM_BASE = $0E000000;

  SCREEN_W = 240;
  SCREEN_H = 160;

  { ── Colors (BGR555) ── }
  COL_BG    = 3 or (4 shl 5) or (10 shl 10);    { dark navy }
  COL_TITLE = 31 or (29 shl 5) or (8 shl 10);   { warm yellow }
  COL_TEXT  = $7FFF;                            { white }
  COL_OK    = 6 or (28 shl 5) or (8 shl 10);    { green }
  COL_NEW   = 8 or (26 shl 5) or (28 shl 10);   { cyan }
  COL_FAIL  = 30 or (5 shl 5) or (5 shl 10);    { red }
  COL_DIM   = 9 or (9 shl 5) or (12 shl 10);    { slate gray }
  COL_LIT   = 31 or (26 shl 5) or (4 shl 10);   { bright gold }
  COL_HEART1 = 30 or (10 shl 5) or (14 shl 10); { pink }
  COL_HEART2 = 10 or (6 shl 5) or (9 shl 10);   { dark plum }

  { ── Save-type autodetection marker + SRAM record layout ──
    The marker doubles as the SRAM magic source so the linker can
    never discard it. Layout: [0..3] = 'S','R','A','M', [4..5] =
    boot count (little-endian word). }
  SaveMarker: array[0..9] of Char = ('S','R','A','M','_','V','1','1','3',#0);

type
  TGlyph = array[0..4] of Byte;   { 5 rows x 3 bits, bit 2 = left pixel }

const
  { 3x5 pixel font: '0'..'9' then 'A'..'Z'. }
  Font: array[0..35] of TGlyph = (
    (%111,%101,%101,%101,%111),   { 0 }
    (%010,%110,%010,%010,%111),   { 1 }
    (%111,%001,%111,%100,%111),   { 2 }
    (%111,%001,%111,%001,%111),   { 3 }
    (%101,%101,%111,%001,%001),   { 4 }
    (%111,%100,%111,%001,%111),   { 5 }
    (%111,%100,%111,%101,%111),   { 6 }
    (%111,%001,%001,%010,%010),   { 7 }
    (%111,%101,%111,%101,%111),   { 8 }
    (%111,%101,%111,%001,%111),   { 9 }
    (%010,%101,%111,%101,%101),   { A }
    (%110,%101,%110,%101,%110),   { B }
    (%011,%100,%100,%100,%011),   { C }
    (%110,%101,%101,%101,%110),   { D }
    (%111,%100,%110,%100,%111),   { E }
    (%111,%100,%110,%100,%100),   { F }
    (%011,%100,%101,%101,%011),   { G }
    (%101,%101,%111,%101,%101),   { H }
    (%111,%010,%010,%010,%111),   { I }
    (%011,%001,%001,%101,%010),   { J }
    (%101,%110,%100,%110,%101),   { K }
    (%100,%100,%100,%100,%111),   { L }
    (%101,%111,%111,%101,%101),   { M }
    (%110,%101,%101,%101,%101),   { N }
    (%010,%101,%101,%101,%010),   { O }
    (%110,%101,%110,%100,%100),   { P }
    (%010,%101,%101,%110,%011),   { Q }
    (%110,%101,%110,%110,%101),   { R }
    (%011,%100,%010,%001,%110),   { S }
    (%111,%010,%010,%010,%010),   { T }
    (%101,%101,%101,%101,%111),   { U }
    (%101,%101,%101,%101,%010),   { V }
    (%101,%101,%111,%111,%101),   { W }
    (%101,%101,%010,%101,%101),   { X }
    (%101,%101,%010,%010,%010),   { Y }
    (%111,%001,%010,%100,%111)    { Z }
  );

type
  TBtnDef = record
    x, y, w, h: Integer;
    mask: Word;
    cap: string[2];
    freq: LongWord;               { blip pitch in Hz }
  end;

const
  { Button layout mirrors the physical shell: d-pad left, A/B right,
    shoulders top corners, START/SELECT bottom center. Pitches are a
    pentatonic ladder so simultaneous testing still sounds pleasant. }
  Btns: array[0..9] of TBtnDef = (
    (x:  36; y:  86; w: 20; h: 16; mask: $0040; cap: 'U';  freq: 1047),
    (x:  36; y: 122; w: 20; h: 16; mask: $0080; cap: 'D';  freq:  392),
    (x:  12; y: 104; w: 20; h: 16; mask: $0020; cap: 'L';  freq:  440),
    (x:  60; y: 104; w: 20; h: 16; mask: $0010; cap: 'R';  freq:  659),
    (x: 196; y:  96; w: 22; h: 16; mask: $0001; cap: 'A';  freq:  880),
    (x: 162; y: 110; w: 22; h: 16; mask: $0002; cap: 'B';  freq:  784),
    (x: 126; y: 130; w: 26; h: 12; mask: $0008; cap: 'ST'; freq:  587),
    (x:  94; y: 130; w: 26; h: 12; mask: $0004; cap: 'SE'; freq:  523),
    (x:   8; y:  60; w: 24; h: 12; mask: $0200; cap: 'L';  freq:  349),
    (x: 208; y:  60; w: 24; h: 12; mask: $0100; cap: 'R';  freq: 1319)
  );

{ Globals only: locals allocated to caller-saved ARM registers do not
  survive DbgLogStr calls on this target (see docs/debugging.md). }
var
  keys, prevKeys, edge: Word;
  frame: LongWord;
  bootCount: Word;
  saveState: Integer;             { 0 = NEW, 1 = OK, 2 = FAIL }
  i: Integer;
  heartOn: Boolean;

{ ── Video ── }

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
  px, py: Integer;
begin
  for py := y to y + h - 1 do
    for px := x to x + w - 1 do
      PutPixel(px, py, c);
end;

{ Draw one glyph at (x, y), scaled. Only '0'..'9', 'A'..'Z' render;
  anything else is left as background (acts as a space). }
procedure DrawChar(x, y: Integer; ch: Char; scale: Integer; c: Word);
var
  idx, row, col: Integer;
  bits: Byte;
begin
  if (ch >= '0') and (ch <= '9') then
    idx := Ord(ch) - Ord('0')
  else if (ch >= 'A') and (ch <= 'Z') then
    idx := 10 + Ord(ch) - Ord('A')
  else
    Exit;

  for row := 0 to 4 do
  begin
    bits := Font[idx][row];
    for col := 0 to 2 do
      if (bits and ($4 shr col)) <> 0 then
        FillRect(x + col * scale, y + row * scale, scale, scale, c);
  end;
end;

procedure DrawText(x, y: Integer; const s: shortstring; scale: Integer; c: Word);
var
  k: Integer;
begin
  for k := 1 to Length(s) do
    DrawChar(x + (k - 1) * 4 * scale, y, s[k], scale, c);
end;

{ Right-grows-left decimal render, up to 5 digits, leading zeros
  suppressed. Avoids the broken -Tgba string-formatting RTL entirely:
  digits come from div/mod and go straight to the framebuffer. }
procedure DrawNumber(x, y: Integer; value: LongWord; scale: Integer; c: Word);
var
  digits: array[0..4] of Integer;
  n, k: Integer;
begin
  n := 0;
  repeat
    digits[n] := Integer(value mod 10);
    value := value div 10;
    Inc(n);
  until (value = 0) or (n = 5);
  for k := 0 to n - 1 do
    DrawChar(x + (n - 1 - k) * 4 * scale, y, Chr(Ord('0') + digits[k]), scale, c);
end;

{ Device-safe narration spacing: wait for the emulator's per-frame
  poll to consume the last message, but give up after four frames so
  real hardware (where nothing ever clears the ready byte) never hangs.
  An unbounded DbgLogWaitConsumed would brick the cart off-emulator. }
procedure DbgFlushBounded;
var
  t: Integer;
begin
  t := 0;
  while (PByte(DBG_SENTINEL_ADDR)^ <> 0) and (t < 4) do
  begin
    WaitVBlank;
    Inc(t);
  end;
end;

{ ── Audio (PSG channel 1) ── }

procedure InitSound;
begin
  PWord(REG_SOUNDCNT_X)^ := $0080;   { master enable }
  PWord(REG_SOUNDCNT_L)^ := $1177;   { ch1 to L+R, volume 7/7 }
  PWord(REG_SOUNDCNT_H)^ := $0002;   { PSG mix at 100% }
end;

procedure Blip(hz: LongWord);
var
  fv: Word;
begin
  if hz < 64 then hz := 64;
  fv := Word(2048 - (131072 div hz)) and $07FF;
  PWord(REG_SOUND1CNT_L)^ := $0000;            { sweep off }
  { envelope: initial volume 10, decreasing, step 2 -> ~0.3 s decay;
    duty 50%. }
  PWord(REG_SOUND1CNT_H)^ := $A280;
  PWord(REG_SOUND1CNT_X)^ := $8000 or fv;      { trigger, no length gate }
end;

{ ── SRAM ── }

function SramRead(off: LongWord): Byte;
begin
  Result := PByte(SRAM_BASE + off)^;
end;

procedure SramWrite(off: LongWord; v: Byte);
begin
  PByte(SRAM_BASE + off)^ := v;
end;

{ Read the boot counter (0 if no marker yet), increment, write back,
  read-verify. Sets bootCount + saveState. }
procedure SramBootSequence;
var
  hadMagic, verified: Boolean;
  k: Integer;
begin
  hadMagic := True;
  for k := 0 to 3 do
    if SramRead(LongWord(k)) <> Byte(SaveMarker[k]) then hadMagic := False;

  if hadMagic then
    bootCount := Word(SramRead(4)) or (Word(SramRead(5)) shl 8)
  else
    bootCount := 0;

  Inc(bootCount);

  for k := 0 to 3 do
    SramWrite(LongWord(k), Byte(SaveMarker[k]));
  SramWrite(4, Byte(bootCount and $FF));
  SramWrite(5, Byte(bootCount shr 8));

  verified := True;
  for k := 0 to 3 do
    if SramRead(LongWord(k)) <> Byte(SaveMarker[k]) then verified := False;
  if SramRead(4) <> Byte(bootCount and $FF) then verified := False;
  if SramRead(5) <> Byte(bootCount shr 8)  then verified := False;

  if not verified then
    saveState := 2
  else if hadMagic then
    saveState := 1
  else
    saveState := 0;
end;

{ ── Static UI ── }

procedure DrawStaticUi;
begin
  FillRect(0, 0, SCREEN_W, SCREEN_H, COL_BG);

  DrawText(52, 6, 'GBA DEVICE SMOKE', 2, COL_TITLE);

  DrawText(52, 24, 'BOOT', 2, COL_TEXT);
  DrawNumber(96, 24, bootCount, 2, COL_TITLE);

  case saveState of
    0: DrawText(52, 40, 'SAVE NEW',  2, COL_NEW);
    1: DrawText(52, 40, 'SAVE OK',   2, COL_OK);
    2: DrawText(52, 40, 'SAVE FAIL', 2, COL_FAIL);
  end;

  DrawText(52, 70, 'PRESS BUTTONS FOR SOUND', 1, COL_TEXT);
end;

procedure DrawButton(k: Integer; lit: Boolean);
var
  c: Word;
  tx, ty: Integer;
begin
  if lit then c := COL_LIT else c := COL_DIM;
  FillRect(Btns[k].x, Btns[k].y, Btns[k].w, Btns[k].h, c);
  tx := Btns[k].x + (Btns[k].w - (Length(Btns[k].cap) * 4 - 1)) div 2;
  ty := Btns[k].y + (Btns[k].h - 5) div 2;
  DrawText(tx, ty, Btns[k].cap, 1, COL_BG);
end;

begin
  { SRAM wait state to 8 cycles for maximum cart-hardware tolerance. }
  PWord(REG_WAITCNT)^ := PWord(REG_WAITCNT)^ or $0003;

  { Mode 3 bitmap, BG2 on. }
  PWord(REG_DISPCNT)^ := $0403;

  DbgLogStr('device_smoke: boot');
  DbgFlushBounded;

  SramBootSequence;
  case saveState of
    0: DbgLogStr('device_smoke: sram first boot, marker written');
    1: DbgLogStr('device_smoke: sram marker found, count bumped');
    2: DbgLogStr('device_smoke: sram verify FAIL');
  end;
  DbgFlushBounded;

  InitSound;
  DrawStaticUi;
  for i := 0 to 9 do
    DrawButton(i, False);

  DbgLogStr('device_smoke: main loop');
  DbgFlushBounded;

  frame := 0;
  prevKeys := 0;
  heartOn := False;

  while True do
  begin
    WaitVBlank;

    { Three-note boot jingle proves audio without any input. }
    if frame = 10 then Blip(523);
    if frame = 25 then Blip(659);
    if frame = 40 then Blip(784);

    keys := (PWord(REG_KEYINPUT)^ and $03FF) xor $03FF;   { active-low }
    edge := keys and (keys xor prevKeys);
    prevKeys := keys;

    for i := 0 to 9 do
      DrawButton(i, (keys and Btns[i].mask) <> 0);

    if edge <> 0 then
      for i := 0 to 9 do
        if (edge and Btns[i].mask) <> 0 then
        begin
          Blip(Btns[i].freq);
          Break;
        end;

    { Heartbeat: top-right block toggles every 30 frames. }
    if (frame mod 30) = 0 then
    begin
      heartOn := not heartOn;
      if heartOn then
        FillRect(228, 4, 8, 8, COL_HEART1)
      else
        FillRect(228, 4, 8, 8, COL_HEART2);
    end;

    Inc(frame);
  end;
end.
