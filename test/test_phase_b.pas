program test_phase_b;
{
  Phase B acceptance tests — exercise the Memory unit, Cart unit, and
  CPU↔Memory integration via LDR/STR/LDM/STM (ARM and THUMB).

  Unlike test_armcore.pas (which uses a flat-array TMemBus stub), these
  tests wire the real TGbaMemory into TArmCore so the whole stack runs.
}

{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, ArmCore, Memory, Cart;

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

procedure CheckBool(const name: string; expected, actual: Boolean);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name, '  (', actual, ')');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  ', name, '  expected ', expected, ', got ', actual);
    Inc(FailCount);
  end;
end;

{ ───── Memory unit standalone tests ─────────────────────────────── }

procedure TestMemoryEwramReadWrite;
{ EWRAM is 256 KB at $02000000. Write a word, read it back. Mirroring
  test: writing at $02040000 should land at offset 0 (since EWRAM wraps
  every $40000). }
var
  mem: TGbaMemory;
begin
  Writeln('--- TestMemoryEwramReadWrite ---');
  mem := TGbaMemory.Create;
  try
    mem.WriteWord($02000100, $DEADBEEF);
    CheckEq('Read back word', $DEADBEEF, mem.ReadWord($02000100));

    mem.WriteWord($02040000, $CAFEF00D);     { mirror — maps to offset 0 }
    CheckEq('EWRAM mirroring: $02040000 → offset 0', $CAFEF00D, mem.ReadWord($02000000));
  finally
    mem.Free;
  end;
end;

procedure TestMemoryIwramMirror;
{ IWRAM is 32 KB at $03000000, mirrors every $8000. }
var
  mem: TGbaMemory;
begin
  Writeln('--- TestMemoryIwramMirror ---');
  mem := TGbaMemory.Create;
  try
    mem.WriteWord($03000000, $11223344);
    CheckEq('IWRAM mirror $03008000 reads same', $11223344, mem.ReadWord($03008000));
    CheckEq('IWRAM mirror $03FF8000 reads same', $11223344, mem.ReadWord($03FF8000));
  finally
    mem.Free;
  end;
end;

procedure TestMemoryPaletteByteWriteDuplicates;
{ Palette byte writes duplicate the byte to fill a halfword. So writing
  byte $5A at $05000000 should result in halfword $5A5A at $05000000. }
var
  mem: TGbaMemory;
begin
  Writeln('--- TestMemoryPaletteByteWriteDuplicates ---');
  mem := TGbaMemory.Create;
  try
    mem.WriteByte($05000000, $5A);
    CheckEq('Palette halfword = byte duplicated', $5A5A, mem.ReadHalf($05000000));
  finally
    mem.Free;
  end;
end;

procedure TestMemoryOamByteWriteIgnored;
{ OAM byte writes are dropped entirely. }
var
  mem: TGbaMemory;
begin
  Writeln('--- TestMemoryOamByteWriteIgnored ---');
  mem := TGbaMemory.Create;
  try
    mem.WriteHalf($07000000, $1234);     { seed via halfword (allowed) }
    mem.WriteByte($07000000, $FF);        { byte write — should be ignored }
    CheckEq('OAM byte write ignored', $1234, mem.ReadHalf($07000000));
  finally
    mem.Free;
  end;
end;

procedure TestMemoryVramMirror;
{ VRAM is 96 KB. The mirror pattern: every $20000 stride, offsets
  $18000..$1FFFF mirror $10000..$17FFF (upper 32K mirrors middle 32K).
  Test: write at offset $10000, read back at offset $18000 — same data. }
var
  mem: TGbaMemory;
begin
  Writeln('--- TestMemoryVramMirror ---');
  mem := TGbaMemory.Create;
  try
    mem.WriteWord($06010000, $A1B2C3D4);
    CheckEq('VRAM upper-32K mirror', $A1B2C3D4, mem.ReadWord($06018000));
  finally
    mem.Free;
  end;
end;

procedure TestMemoryBiosReadOnly;
{ BIOS region is read-only. Writes are silently dropped. }
var
  mem: TGbaMemory;
begin
  Writeln('--- TestMemoryBiosReadOnly ---');
  mem := TGbaMemory.Create;
  try
    mem.WriteWord($00000000, $DEADBEEF);
    CheckEq('BIOS write dropped (still 0)', 0, mem.ReadWord($00000000));
  finally
    mem.Free;
  end;
end;

{ ───── Cart unit tests (synthesize a fake header) ───────────────── }

procedure TestCartHeaderParse;
var
  rom: array of Byte;
  info: TCartInfo;
  i: Integer;
const
  TestTitle = 'TESTGAME';
  TestCode  = 'ATGE';
  TestMaker = 'XX';
begin
  Writeln('--- TestCartHeaderParse ---');
  SetLength(rom, $200);
  for i := 0 to High(rom) do rom[i] := 0;

  { Place ASCII fields. }
  for i := 1 to Length(TestTitle) do rom[$A0 + i - 1] := Byte(TestTitle[i]);
  for i := 1 to Length(TestCode)  do rom[$AC + i - 1] := Byte(TestCode[i]);
  for i := 1 to Length(TestMaker) do rom[$B0 + i - 1] := Byte(TestMaker[i]);
  rom[$B2] := $96;   { sanity byte }

  { Plant SRAM_V somewhere in the ROM for save-type autodetect. }
  for i := 1 to 6 do rom[$180 + i - 1] := Byte('SRAM_V'[i]);

  info := ParseCartHeader(rom, Length(rom));

  CheckBool('Header marked valid (sanity $96 present)', True, info.Valid);
  if info.Title = TestTitle then
  begin
    Writeln('  PASS  Title = "', info.Title, '"');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  Title  expected "', TestTitle, '", got "', info.Title, '"');
    Inc(FailCount);
  end;
  if info.GameCode = TestCode then
  begin
    Writeln('  PASS  GameCode = "', info.GameCode, '"');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  GameCode  expected "', TestCode, '", got "', info.GameCode, '"');
    Inc(FailCount);
  end;
  CheckBool('Save type detected as SRAM', True, info.SaveType = stSRAM);
end;

{ ───── CPU × Memory integration ─────────────────────────────────── }

procedure TestCpuLdrStrInEwram;
{ Run a small ARM program from EWRAM that:
    1. MOV R1, #0x02000000  (base — point at EWRAM via rotation)
       0x02000000 = 0x02 ROR 0  ... actually 0x02000000 = 0x80 ROR 6.
       imm12 = (rot=3 since rot*2=6)<<8 | imm8=0x80 → 0x380.
    2. MOV R0, #0x42
    3. STR R0, [R1, #0x10]   → mem[$02000010] = 0x42
    4. MOV R2, #0
    5. LDR R2, [R1, #0x10]   → R2 = 0x42

  We load code into EWRAM at $02000200 (well past the data location at
  $02000010) and start PC there. }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  pcStart: TWord;
begin
  Writeln('--- TestCpuLdrStrInEwram ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@mem.ReadWord, @mem.ReadHalf, @mem.ReadByte,
                       @mem.CpuWriteWord, @mem.CpuWriteHalf, @mem.CpuWriteByte);

    pcStart := $02000200;
    { Encodings:
        MOV R1, #0x02000000: rot=3 imm8=0x80, S=0, Rd=1 → E3A01380
        Hmm 0x02000000: imm8 = 0x80, rotate-by = 6 → rot field = 3. imm12 = (3<<8)|0x80 = 0x380. So instr = E3A01380.
        Actually 0x80 ROR 6 = 0x02000000? 0x80 = 0b10000000. ROR by 6 in 32 bits: take bottom 6 bits and put at top.
          0x00000080 ROR 6 = the bottom 6 bits of 0x80 are 000000 (since 0x80 = 0b10000000, bit 7 is set, bits 5:0 are 0).
          So ROR 6 just shifts the single set bit from position 7 to position 7+32-6 ... wait that's modular.
          Actually 0x00000080 ROR 6 = right-rotate by 6 positions: bit 7 → bit 1. Result = 0x00000002.
          That's wrong, I wanted 0x02000000.

        Let me reconsider. 0x02000000 = bit 25 set. In 32-bit, that's position 25.
        To express as 8-bit rotated immediate: imm8 in low 8 bits, ROR by rot*2.
        We want result bit 25. ROR(x, n) = (x >> n) | (x << (32-n)).
        If imm8 = 0x02 (= 0b10 at position 1), ROR by some n places bit 1 at position (1+32-n) mod 32.
        Want it at 25: (1 + 32 - n) mod 32 = 25, so 33 - n = 25, n = 8. rot field = n/2 = 4.
        imm12 = (4<<8) | 0x02 = 0x402.
        So MOV R1, #0x02000000 = E3A01402. }
    mem.WriteWord(pcStart + 0,  $E3A01402);   { MOV R1, #0x02000000 }
    mem.WriteWord(pcStart + 4,  $E3A00042);   { MOV R0, #0x42 }
    mem.WriteWord(pcStart + 8,  $E5810010);   { STR R0, [R1, #0x10] — pre-indexed up offset 0x10 }
    mem.WriteWord(pcStart + 12, $E3A02000);   { MOV R2, #0 }
    mem.WriteWord(pcStart + 16, $E5912010);   { LDR R2, [R1, #0x10] }
    cpu.SetReg(R_PC, pcStart);

    cpu.Run(5);

    CheckEq('Memory at $02000010 was written by STR', $42, mem.ReadWord($02000010));
    CheckEq('R2 loaded back from same address', $42, cpu.GetReg(2));
  finally
    cpu.Free; mem.Free;
  end;
end;

procedure TestCpuLdmStmInIwram;
{ Verify ARM LDM/STM round-trip. Place data + code in IWRAM ($03000000).
  Setup: R1 = $03000400 (a scratch area).
  STMIA R1!, [R3,R5,R7]  → writes R3 at $400, R5 at $404, R7 at $408. R1 → $40C.
  Then re-MOV R1 back to $400, zero R3/R5/R7, and LDMIA them back.

  Encodings:
    MOV R1, #$03000400. 0x03000400 needs construction — easiest is via two MOVs.
      MOV R1, #$03000000: imm8=0x03 rot... 0x03000000 = 0x03 at bit 24..25. 0x03 ROR n = need top bits set. Hmm.
      Simpler: load R1 directly using a single MOV with rotation:
        0x03000400 — bits 25:24=11 and bit 10=1. Not a single rotated 8-bit constant.
        Use two-step: MOV R1, #0x03000000 ; ORR R1, R1, #0x400.
        0x03000000 = 0x03 ROR n where bit 1 of 0x03 is at position 24. ROR by 8: bit 1 → 25, bit 0 → 24. So 0x03 ROR 8 = bits 25, 24 = 0x03000000. ✓ rot=4 imm8=0x03. imm12=0x403.
        MOV R1, #0x03000000 = E3A01403.
        ORR R1, R1, #0x400 — opcode=0xC (ORR), I=1, Rn=1, Rd=1.
          0x400 needs rotation. 0x400 = bit 10 = (0x01 << 10) = 0x01 ROR 22. rot=11=0xB. imm12 = 0xB01.
          ORR R1, R1, #0x400: E3811B01.
    Wait, the rotate-right is going the other direction. Let me recheck:
      ROR(0x01, 22) = right-rotate 0x01 (= bit 0) by 22 positions. Bit 0 goes to (0 + 32 - 22) mod 32 = 10. So bit 10 set. = 0x400. ✓
      rot field = 22/2 = 11 = 0xB. imm12 = (0xB << 8) | 0x01 = 0xB01.
    OK so ORR R1, R1, #0x400 = E3811B01.

    STMIA R1!, [R3,R5,R7]: P=0 U=1 S=0 W=1 L=0. reglist = bits 7,5,3 set = 0x00A8.
      = 1110 100 0 1 0 1 0 0001 0000 0000 1010 1000 = E8A100A8.
    LDMIA R1!, [R3,R5,R7]: L=1 → bit 20=1.
      = E8B100A8.

    MOV R3, #1 ; MOV R5, #2 ; MOV R7, #3 — for the STM to write values we can recognize.
    Encodings: E3A03001, E3A05002, E3A07003.

    Then after STMIA, restore R1 with the two-MOV sequence again, and MOV R3/R5/R7 to garbage:
      MOV R3, #0xAA: E3A030AA
      MOV R5, #0xBB: E3A050BB
      MOV R7, #0xCC: E3A070CC
    Re-restore R1: MOV R1, #0x03000000 (= E3A01403) ; ORR R1, R1, #0x400 (= E3811B01).
    Then LDMIA R1!, [R3,R5,R7]: E8B100A8. }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  pcStart: TWord;
  i: Integer;
const
  Prog: array[0..11] of TWord = (
    $E3A01403,   { 00: MOV R1, #0x03000000 }
    $E3811B01,   { 04: ORR R1, R1, #0x400  → R1 = $03000400 }
    $E3A03001,   { 08: MOV R3, #1 }
    $E3A05002,   { 0C: MOV R5, #2 }
    $E3A07003,   { 10: MOV R7, #3 }
    $E8A100A8,   { 14: STMIA R1!, [R3,R5,R7] → R1 = $0300040C }
    $E3A03000,   { 18: MOV R3, #0  (clear) }
    $E3A05000,   { 1C: MOV R5, #0 }
    $E3A07000,   { 20: MOV R7, #0 }
    $E3A01403,   { 24: MOV R1, #0x03000000 }
    $E3811B01,   { 28: ORR R1, R1, #0x400  → R1 back to $03000400 }
    $E8B100A8    { 2C: LDMIA R1!, [R3,R5,R7] → recovers values }
  );
begin
  Writeln('--- TestCpuLdmStmInIwram ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@mem.ReadWord, @mem.ReadHalf, @mem.ReadByte,
                       @mem.CpuWriteWord, @mem.CpuWriteHalf, @mem.CpuWriteByte);

    pcStart := $03000000;
    for i := 0 to High(Prog) do mem.WriteWord(pcStart + TWord(i) * 4, Prog[i]);
    cpu.SetReg(R_PC, pcStart);

    cpu.Run(12);

    CheckEq('R3 round-tripped via STM/LDM', 1, cpu.GetReg(3));
    CheckEq('R5 round-tripped via STM/LDM', 2, cpu.GetReg(5));
    CheckEq('R7 round-tripped via STM/LDM', 3, cpu.GetReg(7));
    CheckEq('Memory at $03000400 holds R3 value', 1, mem.ReadWord($03000400));
    CheckEq('Memory at $03000404 holds R5 value', 2, mem.ReadWord($03000404));
    CheckEq('Memory at $03000408 holds R7 value', 3, mem.ReadWord($03000408));
    CheckEq('R1 incremented past last stored = $0300040C', $0300040C, cpu.GetReg(1));
  finally
    cpu.Free; mem.Free;
  end;
end;

procedure TestThumbPushPopRoundTrip;
{ THUMB PUSH/POP test — exercise stack discipline. Sequence:
    Set SP = $03007F00 (well into IWRAM, room to push down).
    Switch to THUMB at $03000020.
    Enter THUMB code:
      MOV R0, #0x11   ($2011)
      MOV R1, #0x22   ($2122)
      MOV R2, #0x33   ($2233)
      PUSH [R0, R1, R2]     ($B407)
      MOV R0, #0xAA   ($20AA)  ← stomp the values
      MOV R1, #0xBB   ($21BB)
      MOV R2, #0xCC   ($22CC)
      POP [R0, R1, R2]      ($BC07)
    After POP, R0=0x11, R1=0x22, R2=0x33, SP back to $03007F00. }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  i: Integer;
const
  { ARM prologue: set SP to $03007F00, set R3 to THUMB target with bit 0, BX R3. }
  ArmProg: array[0..3] of TWord = (
    $E59FD010,   { 00: LDR R13, [PC, #0x10] — load SP from literal pool at offset $18 }
    $E59F3010,   { 04: LDR R3,  [PC, #0x10] — load thumb-target from literal pool at $1C }
    $E12FFF13,   { 08: BX R3 }
    $E1A00000    { 0C: NOP (padding before literal pool) }
  );
  { Note: ARM LDR Rd, [PC, #imm] reads from PC+8+imm. PC at instruction 00 is $03000000.
    At addr 0, PC=0, +8=8, +0x10=0x18 → literal at $03000018 = $03007F00.
    At addr 4, PC=4, +8=$C, +0x10=$1C → literal at $0300001C = thumb target. }
  StackTop:    TWord = $03007F00;
  ThumbTarget: TWord = $03000021;   { THUMB at $03000020 with bit 0 }
begin
  Writeln('--- TestThumbPushPopRoundTrip ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@mem.ReadWord, @mem.ReadHalf, @mem.ReadByte,
                       @mem.CpuWriteWord, @mem.CpuWriteHalf, @mem.CpuWriteByte);

    for i := 0 to High(ArmProg) do mem.WriteWord($03000000 + TWord(i) * 4, ArmProg[i]);
    mem.WriteWord($03000018, StackTop);
    mem.WriteWord($0300001C, ThumbTarget);

    { THUMB code at $03000020. }
    mem.WriteHalf($03000020, $2011);   { MOV R0, #0x11 }
    mem.WriteHalf($03000022, $2122);   { MOV R1, #0x22 }
    mem.WriteHalf($03000024, $2233);   { MOV R2, #0x33 }
    mem.WriteHalf($03000026, $B407);   { PUSH [R0,R1,R2] }
    mem.WriteHalf($03000028, $20AA);   { MOV R0, #0xAA }
    mem.WriteHalf($0300002A, $21BB);   { MOV R1, #0xBB }
    mem.WriteHalf($0300002C, $22CC);   { MOV R2, #0xCC }
    mem.WriteHalf($0300002E, $BC07);   { POP [R0,R1,R2] }

    cpu.SetReg(R_PC, $03000000);

    cpu.Run(11);    { 3 ARM (LDR, LDR, BX) + 8 THUMB }

    CheckEq('R0 restored by POP to $11', $11, cpu.GetReg(0));
    CheckEq('R1 restored to $22',         $22, cpu.GetReg(1));
    CheckEq('R2 restored to $33',         $33, cpu.GetReg(2));
    CheckEq('SP back to $03007F00 after PUSH+POP', $03007F00, cpu.GetReg(R_SP));
  finally
    cpu.Free; mem.Free;
  end;
end;

procedure TestThumbFmt9LdrStr;
{ Verify THUMB Format 9 (immediate-offset LDR/STR) hits memory correctly.
  Setup: R1 := $03000800 (a scratch addr in IWRAM).
  Run THUMB code:
    MOV R0, #0xAB         ($20AB)
    STR R0, [R1, #0]      ($6008)   (Fmt 9: bit12=0 B=word, bit11=0 L=store,
                                       imm5=00000, Rb=001, Rd=000)
    MOV R0, #0            ($2000)
    LDR R0, [R1, #0]      ($6808)   (Fmt 9: L=load) }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  i: Integer;
const
  ArmProg: array[0..3] of TWord = (
    $E59F1010,   { 00: LDR R1, [PC, #0x10] }
    $E59F3010,   { 04: LDR R3, [PC, #0x10] (thumb target) }
    $E12FFF13,   { 08: BX R3 }
    $E1A00000    { 0C: NOP }
  );
  Base:        TWord = $03000800;
  ThumbTarget: TWord = $03000021;
begin
  Writeln('--- TestThumbFmt9LdrStr ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@mem.ReadWord, @mem.ReadHalf, @mem.ReadByte,
                       @mem.CpuWriteWord, @mem.CpuWriteHalf, @mem.CpuWriteByte);

    for i := 0 to High(ArmProg) do mem.WriteWord($03000000 + TWord(i) * 4, ArmProg[i]);
    mem.WriteWord($03000018, Base);
    mem.WriteWord($0300001C, ThumbTarget);

    mem.WriteHalf($03000020, $20AB);   { MOV R0, #0xAB }
    mem.WriteHalf($03000022, $6008);   { STR R0, [R1] }
    mem.WriteHalf($03000024, $2000);   { MOV R0, #0 }
    mem.WriteHalf($03000026, $6808);   { LDR R0, [R1] }

    cpu.SetReg(R_PC, $03000000);
    cpu.Run(7);     { 3 ARM + 4 THUMB }

    CheckEq('STR placed $AB at $03000800', $AB, mem.ReadWord($03000800));
    CheckEq('LDR recovered $AB into R0',   $AB, cpu.GetReg(0));
  finally
    cpu.Free; mem.Free;
  end;
end;

procedure TestArmLdrhStrh;
{ Verify ARM LDRH/STRH halfword transfers. Setup base in IWRAM, store
  $1234 as halfword, read back. The encoding requires the "1xx1" bits 7:4
  signature which routes through ExecHalfwordTransfer (class 0, not SDT). }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  i: Integer;
const
  { STRH R0, [R1] = cond 000 P=1 U=1 I=1 W=0 L=0 Rn=1 Rd=0 offHi=0 1 SH=01 1 offLo=0
    = 1110 0001 1100 0001 0000 0000 1011 0000 = E1C100B0.
    LDRH R0, [R1] = same with L=1 → E1D100B0.
    LDRSH R2, [R1] = SH=11, L=1 → E1D120F0.
    Use a known halfword pattern with sign bit set to verify sign-extension. }
  Prog: array[0..6] of TWord = (
    $E59F1018,   { 00: LDR R1, [PC, #0x18]  — load base from literal pool }
    $E3A0023A,   { 04: MOV R0, #0x3A * something... actually 0x3A doesn't matter — overwritten next }
    $E59F0014,   { 08: LDR R0, [PC, #0x14]  — load value 0x1234 }
    $E1C100B0,   { 0C: STRH R0, [R1] }
    $E1D120B0,   { 10: LDRH R2, [R1] }
    $E59F0010,   { 14: LDR R0, [PC, #0x10]  — load value 0x8000 (sign bit) }
    $E1C100B0    { 18: STRH R0, [R1] (overwrite halfword with $8000) }
  );
  Base:    TWord = $03001000;
  Value1:  TWord = $00001234;
  Value2:  TWord = $00008000;
begin
  Writeln('--- TestArmLdrhStrh ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@mem.ReadWord, @mem.ReadHalf, @mem.ReadByte,
                       @mem.CpuWriteWord, @mem.CpuWriteHalf, @mem.CpuWriteByte);
    for i := 0 to High(Prog) do mem.WriteWord($03000000 + TWord(i) * 4, Prog[i]);
    { LDR at offset 0 reads PC+8+0x18 = 0+8+0x18 = $20 → Base.
      LDR at offset 8 reads PC+8+0x14 = 8+8+0x14 = $24 → Value1.
      LDR at offset $14 reads PC+8+0x10 = $14+8+0x10 = $2C → Value2. }
    mem.WriteWord($03000020, Base);
    mem.WriteWord($03000024, Value1);
    mem.WriteWord($0300002C, Value2);

    cpu.SetReg(R_PC, $03000000);
    cpu.Run(7);

    CheckEq('Halfword $8000 written to $03001000', $8000, TWord(mem.ReadHalf($03001000)));
    CheckEq('LDRH R2 read back $1234 (zero-extended)', $1234, cpu.GetReg(2));

    { Now do an LDRSH on the $8000 and verify sign-extension to 0xFFFF8000. }
    mem.WriteWord($03000040, $E59F0028);   { LDR R0, [PC, #0x28] — placeholder, will compute }
    { Easier: just call LDRSH directly via direct memory write of opcode. We're
      already running the program; for this sub-check spin up a separate run. }
  finally
    cpu.Free; mem.Free;
  end;
end;

procedure TestArmLdrshSignExtend;
{ Dedicated LDRSH test: write halfword $FFFF, load via LDRSH, expect R0 = $FFFFFFFF. }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  i: Integer;
const
  Prog: array[0..3] of TWord = (
    $E59F1010,   { 00: LDR R1, [PC, #0x10] — base $03001000 }
    $E59F0010,   { 04: LDR R0, [PC, #0x10] — value $0000FFFF }
    $E1C100B0,   { 08: STRH R0, [R1] }
    $E1D100F0    { 0C: LDRSH R0, [R1] — sign-extend the half }
  );
  Base:  TWord = $03001000;
  Value: TWord = $0000FFFF;
begin
  Writeln('--- TestArmLdrshSignExtend ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@mem.ReadWord, @mem.ReadHalf, @mem.ReadByte,
                       @mem.CpuWriteWord, @mem.CpuWriteHalf, @mem.CpuWriteByte);
    for i := 0 to High(Prog) do mem.WriteWord($03000000 + TWord(i) * 4, Prog[i]);
    { LDR at 0: reads $03000018. LDR at 4: reads $0300001C. }
    mem.WriteWord($03000018, Base);
    mem.WriteWord($0300001C, Value);
    cpu.SetReg(R_PC, $03000000);
    cpu.Run(4);

    CheckEq('LDRSH sign-extended $FFFF to $FFFFFFFF', $FFFFFFFF, cpu.GetReg(0));
  finally
    cpu.Free; mem.Free;
  end;
end;

procedure TestCpuReadOnlyIoEnforcement;
{ Regression test for a latent MMIO bug: CPU stores to hardware-managed
  IO registers (KEYINPUT $04000130, VCOUNT $04000006) must be silently
  dropped — real hardware ignores them, and our memory backend used to
  accept them through, allowing cart code / DMA copies to corrupt
  keypad or scanline state. Host-side writes (WriteHalf/WriteByte) must
  continue to mutate the registers — that's how input.pas and the
  PPU update them per frame. }
var
  mem: TGbaMemory;
  initialKey, initialVcount: THalf;
begin
  Writeln('--- TestCpuReadOnlyIoEnforcement ---');
  mem := TGbaMemory.Create;
  try
    { Seed both registers via the HOST write path. These are the
      values the rest of the test will assert remain intact after
      CPU stores attempt to clobber them. }
    mem.WriteHalf($04000130, $03FF);   { all-buttons-released }
    mem.WriteHalf($04000006, $0042);   { arbitrary scanline marker }
    initialKey    := mem.ReadHalf($04000130);
    initialVcount := mem.ReadHalf($04000006);
    CheckEq('Host WriteHalf to KEYINPUT lands', $03FF, initialKey);
    CheckEq('Host WriteHalf to VCOUNT lands',   $0042, initialVcount);

    { CPU halfword stores: should drop the value. Both registers
      retain whatever the host wrote. }
    mem.CpuWriteHalf($04000130, $0000);
    CheckEq('CpuWriteHalf to KEYINPUT silently dropped',
            $03FF, mem.ReadHalf($04000130));
    mem.CpuWriteHalf($04000006, $00AA);
    CheckEq('CpuWriteHalf to VCOUNT silently dropped',
            $0042, mem.ReadHalf($04000006));

    { CPU byte stores at either byte position within the read-only
      halfword — also dropped. }
    mem.CpuWriteByte($04000130, $00);
    mem.CpuWriteByte($04000131, $00);
    CheckEq('CpuWriteByte to KEYINPUT (both bytes) dropped',
            $03FF, mem.ReadHalf($04000130));

    { CPU word store across KEYINPUT (lo) + KEYCNT (hi):
        lo half drops (read-only), hi half writes (KEYCNT is rw). }
    mem.WriteHalf($04000132, $0000);   { reset KEYCNT via host }
    mem.CpuWriteWord($04000130, $DEADBEEF);
    CheckEq('CpuWriteWord KEYINPUT half dropped',
            $03FF, mem.ReadHalf($04000130));
    CheckEq('CpuWriteWord KEYCNT half landed (the writable adjacent)',
            $DEAD, mem.ReadHalf($04000132));

    { A CPU store to a WRITABLE register (DISPCNT) must still write —
      the enforcement is targeted, not a blanket block on IO. }
    mem.WriteHalf($04000000, $0000);
    mem.CpuWriteHalf($04000000, $1C61);
    CheckEq('CpuWriteHalf to DISPCNT (writable) still writes',
            $1C61, mem.ReadHalf($04000000));
  finally
    mem.Free;
  end;
end;

begin
  Writeln('Phase B acceptance tests');
  Writeln('==========================================');
  Writeln('');
  TestMemoryEwramReadWrite;       Writeln('');
  TestMemoryIwramMirror;          Writeln('');
  TestMemoryPaletteByteWriteDuplicates; Writeln('');
  TestMemoryOamByteWriteIgnored;  Writeln('');
  TestMemoryVramMirror;           Writeln('');
  TestMemoryBiosReadOnly;         Writeln('');
  TestCartHeaderParse;            Writeln('');
  TestCpuLdrStrInEwram;           Writeln('');
  TestCpuLdmStmInIwram;           Writeln('');
  TestThumbPushPopRoundTrip;      Writeln('');
  TestThumbFmt9LdrStr;            Writeln('');
  TestArmLdrhStrh;                Writeln('');
  TestArmLdrshSignExtend;         Writeln('');
  TestCpuReadOnlyIoEnforcement;   Writeln('');
  Writeln('==========================================');
  Writeln(Format('Result: %d pass, %d fail', [PassCount, FailCount]));
  if FailCount > 0 then Halt(1);
end.
