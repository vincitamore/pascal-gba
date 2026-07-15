program swi_sound;
{
  Cart-side proof harness for the bundled BIOS's sound-family SWI
  handlers ($1B SoundDriverMode, $1C SoundDriverMain, $1E
  SoundChannelClear, $25 MultiBoot, $2A SoundGetJumpList, $20-$24
  undocumented entries). Each check reports PASS/FAIL over DbgLog with
  static strings (numeric-formatting RTL is broken on this target).

  Build:  .\build-gba.ps1 test\swi_sound
  Run:    .\bin\gbarun.exe --rom test\swi_sound.gba --headless --frames 300
  Expect: every line ends "PASS".

  Cart code compiles to ARM mode, so the SWI number rides bits 23:16
  of the instruction (the BIOS dispatcher reads the byte at [lr-2]).
}

{$mode objfpc}{$H+}

uses
  Gba_Dbg;

const
  REG_SOUNDBIAS  = $04000088;
  REG_DMA1CNT_H  = $040000C6;
  REG_DMA2CNT_H  = $040000D2;
  CANARY       = LongWord($DEADBEEF);

var
  { unit-level: locals do not survive DbgLog calls on this target }
  jumpBuf: array[0..37] of LongWord;   { 36 entries + 2 canaries }
  i: Integer;
  sbBefore, sbAfter: Word;
  dma1, dma2: Word;
  ret: LongWord;
  allOk: Boolean;

procedure SwiSoundDriverMode(mode: LongWord); assembler; nostackframe;
asm
  swi #0x1B0000
end;

procedure SwiSoundDriverMain; assembler; nostackframe;
asm
  swi #0x1C0000
end;

procedure SwiSoundChannelClear; assembler; nostackframe;
asm
  swi #0x1E0000
end;

function SwiMultiBoot(param: Pointer; mode: LongWord): LongWord; assembler; nostackframe;
asm
  swi #0x250000
end;

procedure SwiSoundGetJumpList(dest: Pointer); assembler; nostackframe;
asm
  swi #0x2A0000
end;

procedure SwiSoundUndoc0; assembler; nostackframe;
asm
  swi #0x200000
end;

procedure SwiSoundUndoc4; assembler; nostackframe;
asm
  swi #0x240000
end;

begin
  { --- $2A SoundGetJumpList: 36 word-indexed entries, canaries intact }
  for i := 0 to 37 do jumpBuf[i] := CANARY;
  SwiSoundGetJumpList(@jumpBuf[0]);
  allOk := True;
  for i := 0 to 35 do
    if (jumpBuf[i] = CANARY) or (jumpBuf[i] = 0) then allOk := False;
  for i := 1 to 35 do
    if jumpBuf[i] <> jumpBuf[0] then allOk := False;
  if (jumpBuf[36] <> CANARY) or (jumpBuf[37] <> CANARY) then allOk := False;
  if allOk then DbgLogStr('swi2A jumplist 36 words + canaries: PASS')
           else DbgLogStr('swi2A jumplist 36 words + canaries: FAIL');
  DbgLogWaitConsumed;

  { --- $1B SoundDriverMode: D/A bits map to SOUNDBIAS bits 14-15 }
  sbBefore := PWord(REG_SOUNDBIAS)^;
  SwiSoundDriverMode($00900000);   { D/A bits = 9 -> resolution 1 }
  sbAfter := PWord(REG_SOUNDBIAS)^;
  if ((sbAfter shr 14) and 3) = 1 then
    DbgLogStr('swi1B DA bits 9 -> SOUNDBIAS res 1: PASS')
  else
    DbgLogStr('swi1B DA bits 9 -> SOUNDBIAS res 1: FAIL');
  DbgLogWaitConsumed;

  SwiSoundDriverMode($00800000);   { D/A bits = 8 -> resolution 0 }
  sbAfter := PWord(REG_SOUNDBIAS)^;
  if ((sbAfter shr 14) and 3) = 0 then
    DbgLogStr('swi1B DA bits 8 -> SOUNDBIAS res 0: PASS')
  else
    DbgLogStr('swi1B DA bits 8 -> SOUNDBIAS res 0: FAIL');
  DbgLogWaitConsumed;

  { level bits (0-9) must be preserved by the D/A write }
  if (sbAfter and $3FF) = (sbBefore and $3FF) then
    DbgLogStr('swi1B preserves bias level bits: PASS')
  else
    DbgLogStr('swi1B preserves bias level bits: FAIL');
  DbgLogWaitConsumed;

  { --- $1E SoundChannelClear: stops sound DMA }
  PWord(REG_DMA1CNT_H)^ := $B600;
  PWord(REG_DMA2CNT_H)^ := $B600;
  SwiSoundChannelClear;
  dma1 := PWord(REG_DMA1CNT_H)^;
  dma2 := PWord(REG_DMA2CNT_H)^;
  if (dma1 = 0) and (dma2 = 0) then
    DbgLogStr('swi1E clears sound DMA channels: PASS')
  else
    DbgLogStr('swi1E clears sound DMA channels: FAIL');
  DbgLogWaitConsumed;

  { --- $25 MultiBoot: no link peers -> documented failure return }
  ret := SwiMultiBoot(nil, 0);
  if ret = 1 then DbgLogStr('swi25 multiboot returns failure: PASS')
             else DbgLogStr('swi25 multiboot returns failure: FAIL');
  DbgLogWaitConsumed;

  { --- $1C / $20 / $24: deterministic return (reaching the next line
    IS the check - a wild jump would never come back) }
  SwiSoundDriverMain;
  SwiSoundUndoc0;
  SwiSoundUndoc4;
  DbgLogStr('swi1C/20/24 return cleanly: PASS');
  DbgLogWaitConsumed;

  DbgLogStr('swi_sound: done');
  DbgLogWaitConsumed;

  while True do ;
end.
