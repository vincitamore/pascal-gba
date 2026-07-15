program test_armcore;
{
  Phase A acceptance tests for the ARM7TDMI interpreter core. Hand-builds
  small instruction streams in a flat RAM buffer, runs them through the
  interpreter, asserts known register/flag state at the end.

  ── How to read these tests ──

  Each ARM instruction is encoded by hand as a 32-bit hex constant. The
  comment above the constant shows the assembly form. The encoding is
  per the ARM ARM (ARMv4T):

    MOV R0, #5     → E3A00005
        E       cond=AL (1110)
         3      00 I=1 opcode=1101 (MOV)
          A     S=0 Rn=1010 (ignored for MOV)
           0    Rd=0000
            005 imm12: rot=0, imm8=5

    ADD R0, R0, #3 → E2800003
        E       cond=AL
         2      00 I=1 opcode=0100 (ADD)
          8     S=0 Rn=1000 ... wait, that's wrong on first look
                Actually: bit 25=I, bits 24:21=opcode, bit 20=S, bits 19:16=Rn
                = 0(bit27) 0(bit26) 1(I) 0(opc3) 1(opc2) 0(opc1) 0(opc0) 0(S)
                  0(Rn3) 0(Rn2) 0(Rn1) 0(Rn0) Rd[15:12]...
                The "28" in E28 is just bits 27:20 = 00101000 = ADD imm S=0 Rn=0.

  Hand-encoding is fiddly but worthwhile for tests this small — keeps
  zero dependency on an external assembler. The bigger ROM-loading
  tests come later via real cartridge dumps.
}

{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, ArmCore;

type
  TMemBus = class
  private
    FRam: array of TByte;
  public
    constructor Create(sizeBytes: Integer);
    function ReadWord(addr: TWord): TWord;
    function ReadHalf(addr: TWord): THalf;
    function ReadByte(addr: TWord): TByte;
    procedure WriteWord(addr: TWord; v: TWord);
    procedure WriteHalf(addr: TWord; v: THalf);
    procedure WriteByte(addr: TWord; v: TByte);
    procedure Load(addr: TWord; const data: array of TWord);
  end;

constructor TMemBus.Create(sizeBytes: Integer);
begin
  inherited Create;
  SetLength(FRam, sizeBytes);
end;

function TMemBus.ReadWord(addr: TWord): TWord;
begin
  { Little-endian 32-bit read. ARM is little-endian on GBA. }
  Result :=  FRam[addr]
          or (FRam[addr+1] shl 8)
          or (FRam[addr+2] shl 16)
          or (FRam[addr+3] shl 24);
end;

function TMemBus.ReadHalf(addr: TWord): THalf;
begin
  Result := FRam[addr] or (FRam[addr+1] shl 8);
end;

function TMemBus.ReadByte(addr: TWord): TByte;
begin
  Result := FRam[addr];
end;

procedure TMemBus.WriteWord(addr: TWord; v: TWord);
begin
  FRam[addr]   :=  v         and $FF;
  FRam[addr+1] := (v shr 8)  and $FF;
  FRam[addr+2] := (v shr 16) and $FF;
  FRam[addr+3] := (v shr 24) and $FF;
end;

procedure TMemBus.WriteHalf(addr: TWord; v: THalf);
begin
  FRam[addr]   :=  v        and $FF;
  FRam[addr+1] := (v shr 8) and $FF;
end;

procedure TMemBus.WriteByte(addr: TWord; v: TByte);
begin
  FRam[addr] := v;
end;

procedure TMemBus.Load(addr: TWord; const data: array of TWord);
var i: Integer;
begin
  for i := 0 to High(data) do
    WriteWord(addr + TWord(i) * 4, data[i]);
end;

{ ───── Test harness ──────────────────────────────────────────────── }

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

procedure CheckFlag(const name: string; cpsr, mask: TWord; expected: Boolean);
var actual: Boolean;
begin
  actual := (cpsr and mask) <> 0;
  if actual = expected then
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

{ ───── Tests ─────────────────────────────────────────────────────── }

procedure TestMovImmediate;
{ Test 1: MOV R0, #42 — proves immediate-operand decode + register write. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestMovImmediate ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { MOV R0, #42  →  E3A0002A }
    bus.Load(0, [TWord($E3A0002A)]);
    cpu.SetReg(R_PC, 0);

    cpu.Step;

    CheckEq('R0', 42, cpu.GetReg(0));
    CheckEq('PC advanced to 4', 4, cpu.GetReg(R_PC));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestAddImmediate;
{ Test 2: MOV R0, #5; ADD R0, R0, #3 → R0 = 8.
  Proves: ALU op, source-register read, multi-instruction execution. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestAddImmediate ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A00005),    { MOV R0, #5 }
      TWord($E2800003)     { ADD R0, R0, #3 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(2);

    CheckEq('R0', 8, cpu.GetReg(0));
    CheckEq('PC advanced to 8', 8, cpu.GetReg(R_PC));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestCmpAndConditionalBranch;
{ Test 3: MOV R0, #10; CMP R0, #5; BHI +4; MOV R0, #99
  After CMP 10,5: C=1 (no borrow) Z=0, so HI (unsigned >) takes the branch.
  Branch target is at offset +4 (skipping the MOV R0, #99).
  Expected: R0 = 10 (the second MOV is skipped). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestCmpAndConditionalBranch ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { Encoding for BHI +0: cond=8(HI) 101 L=0 offset=0xFFFFFE (= -2 after <<2 = -8)
      That branches to PC+8+(-8) = PC, an infinite loop. We want to skip ONE
      instruction (4 bytes), so offset must yield +0 after the +8 prefetch:
      target = PC+8 + (offset<<2) → for target = PC+16 (next-next),
      offset<<2 = +8, so offset = 2. Wait — let me redo.

      ARM branch math: target = (PC of branch) + 8 + (sign_extend(offset)<<2)
      We want target = (PC of branch) + 8 (skip ONE instr after the branch)
      So offset<<2 = 0, offset = 0.

      Layout:
        addr 0:  MOV R0, #10        E3A0000A
        addr 4:  CMP R0, #5         E3500005
        addr 8:  BHI +0             8A000000   ← branch to PC+8 = addr 16
        addr 12: MOV R0, #99        E3A00063   ← SKIPPED
        addr 16: (end)
    }
    bus.Load(0, [
      TWord($E3A0000A),    { MOV R0, #10 }
      TWord($E3500005),    { CMP R0, #5  }
      TWord($8A000000),    { BHI +0       }
      TWord($E3A00063)     { MOV R0, #99 (should be skipped) }
    ]);
    cpu.SetReg(R_PC, 0);

    { Run exactly 3 instructions: MOV, CMP, BHI. The branch lands at
      addr 16; we don't step the (zero-filled) word there, since that
      would just be an inert decoded-as-EQ-fails skip. }
    cpu.Run(3);

    CheckEq('R0', 10, cpu.GetReg(0));
    CheckFlag('CPSR.C = 1 (no borrow from 10-5)', cpu.State.CPSR, CPSR_C, True);
    CheckFlag('CPSR.Z = 0 (10 <> 5)',             cpu.State.CPSR, CPSR_Z, False);
    CheckEq('PC reached 16 (branch taken)', 16, cpu.GetReg(R_PC));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestBranchAndLink;
{ Test 4: BL +0 followed by MOV R0, #1 at the call target.
  Proves: BL writes LR with return address, then transfers control. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestBranchAndLink ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { Layout:
        addr 0:  BL +0            EB000000  ← branches to PC+8 = addr 8
        addr 4:  MOV R0, #0xDEAD  (should be skipped)
        addr 8:  MOV R0, #1       E3A00001  ← branch target
    }
    bus.Load(0, [
      TWord($EB000000),    { BL +0 }
      TWord($E3A00FAD),    { MOV R0, #0xAD0 — placeholder, skipped }
      TWord($E3A00001)     { MOV R0, #1 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(2);   { BL + the target MOV }

    CheckEq('R0', 1, cpu.GetReg(0));
    CheckEq('LR = return address (PC of BL + 4) = 4', 4, cpu.GetReg(R_LR));
    CheckEq('PC reached 12 (past target MOV)', 12, cpu.GetReg(R_PC));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestShiftLSLImmediate;
{ Test 5: MOV R1, #1; MOV R0, R1, LSL #4 → R0 = 16.
  Proves: immediate-shift LSL operand-2 decode. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestShiftLSLImmediate ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { Encoding for MOV R0, R1, LSL #4 (register-form DP, op=MOV):
        cond=E 00 I=0 opcode=1101(MOV) S=0 Rn=0000 Rd=0000
        shift=00100 (=4) type=00 (LSL) reg=0 Rm=0001
        =  1110  000  0  1101  0  0000  0000  00100  00 0  0001
        =  E 1 A 0 0 2 0 1
                                                                          }
    bus.Load(0, [
      TWord($E3A01001),    { MOV R1, #1 }
      TWord($E1A00201)     { MOV R0, R1, LSL #4 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(2);

    CheckEq('R1', 1, cpu.GetReg(1));
    CheckEq('R0 = R1 << 4 = 16', 16, cpu.GetReg(0));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestShiftLSRImmediate;
{ Test 6: MOV R1, #0x80; MOVS R0, R1, LSR #3 → R0 = 0x10, C = 0 (bit-2 of 0x80 = 0). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestShiftLSRImmediate ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { MOVS R0, R1, LSR #3:  cond=E S=1, shift=3 type=01(LSR), Rm=R1
      = 1110 000 0 1101 1 0000 0000 00011 01 0 0001 = E1B001A1 }
    bus.Load(0, [
      TWord($E3A01080),    { MOV R1, #0x80 }
      TWord($E1B001A1)     { MOVS R0, R1, LSR #3 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(2);

    CheckEq('R0 = 0x80 >> 3 = 0x10', $10, cpu.GetReg(0));
    CheckFlag('CPSR.C = 0 (last bit shifted out was 0)', cpu.State.CPSR, CPSR_C, False);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestShiftASRImmediate;
{ Test 7: ASR on a negative number — sign-bit fills in.
  MOV R1, #0xF0000000 via 8-bit imm rotate (imm8=0xF, rot=4*2=8 → 0xF rotated yields 0x0F000000;
  that doesn't get us 0xF0000000 directly, so we use a 4-bit rotate instead).
  Easier: use MVN to get -1, then ASR.
  MVN R1, #0 → R1 = 0xFFFFFFFF. Then MOVS R0, R1, ASR #4 → R0 = 0xFFFFFFFF, C = 1. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestShiftASRImmediate ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { MVN R1, #0:  cond=E 00 I=1 opcode=1111 S=0 Rn=0000 Rd=0001 imm12=0
      = 1110 001 1 1110 0 0000 0001 0000 0000 0000 = E3E01000
      MOVS R0, R1, ASR #4:  shift=4 type=10(ASR) Rm=R1
      = 1110 000 0 1101 1 0000 0000 00100 10 0 0001 = E1B00241 }
    bus.Load(0, [
      TWord($E3E01000),    { MVN R1, #0  → R1 = 0xFFFFFFFF }
      TWord($E1B00241)     { MOVS R0, R1, ASR #4 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(2);

    CheckEq('R1 = 0xFFFFFFFF', $FFFFFFFF, cpu.GetReg(1));
    CheckEq('R0 = ASR(0xFFFFFFFF, 4) = 0xFFFFFFFF', $FFFFFFFF, cpu.GetReg(0));
    CheckFlag('CPSR.N = 1', cpu.State.CPSR, CPSR_N, True);
    CheckFlag('CPSR.C = 1 (last bit shifted out from 0xFFF...)', cpu.State.CPSR, CPSR_C, True);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestShiftRORImmediate;
{ Test 8: ROR by 8 on 0x000000FF → 0xFF000000.
  MOV R1, #0xFF; MOV R0, R1, ROR #8. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestShiftRORImmediate ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { MOV R0, R1, ROR #8:  shift=8 type=11(ROR) Rm=R1
      = 1110 000 0 1101 0 0000 0000 01000 11 0 0001 = E1A00461 }
    bus.Load(0, [
      TWord($E3A010FF),    { MOV R1, #0xFF }
      TWord($E1A00461)     { MOV R0, R1, ROR #8 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(2);

    CheckEq('R0 = ROR(0xFF, 8) = 0xFF000000', $FF000000, cpu.GetReg(0));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestRRX;
{ Test 9: RRX (ROR #0 encodes RRX — rotate right one bit through carry).
  Setup: R1 = 3, CPSR.C = 1 → MOVS R0, R1, RRX → R0 = 0x80000001, C = 1 (Rm[0] = 1).
  We need to seed C=1 — use CMP R1, R1 (which sets C=1 because R1 >= R1). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestRRX ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { CMP R1, R1: cond=E 00 I=1 opcode=1010(CMP) S=1 Rn=0001 Rd=0000 imm=R1?
      Actually CMP register form is cleaner — but let's just seed C via a
      known instruction. CMP R1, #0: 1110 001 1 0101 1 0001 0000 000 ... 0
      = E3510000. With R1=3, 3-0=3, C=1 (3>=0), Z=0.
      RRX is MOVS R0, R1, ROR #0 (imm-shift form, amt=0, type=11)
      = 1110 000 0 1101 1 0000 0000 00000 11 0 0001 = E1B00061 }
    bus.Load(0, [
      TWord($E3A01003),    { MOV R1, #3 }
      TWord($E3510000),    { CMP R1, #0 — sets C=1 since 3 >= 0 }
      TWord($E1B00061)     { MOVS R0, R1, RRX }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(3);

    CheckEq('R0 = RRX(3, C=1) = 0x80000001', $80000001, cpu.GetReg(0));
    CheckFlag('CPSR.C = 1 (Rm[0] was 1)', cpu.State.CPSR, CPSR_C, True);
    CheckFlag('CPSR.N = 1 (result bit 31)', cpu.State.CPSR, CPSR_N, True);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestShiftByRegister;
{ Test 10: register-shift form — MOV R0, R1, LSL R2.
  MOV R1, #1; MOV R2, #5; MOV R0, R1, LSL R2 → R0 = 32. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestShiftByRegister ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { MOV R0, R1, LSL R2: register-shift form (bit4=1, bit7=0)
        cond=E 00 I=0 opcode=1101 S=0 Rn=0000 Rd=0000 Rs=0010 0 type=00 1 Rm=0001
        = 1110 000 0 1101 0 0000 0000 0010 0 00 1 0001 = E1A00211 }
    bus.Load(0, [
      TWord($E3A01001),    { MOV R1, #1 }
      TWord($E3A02005),    { MOV R2, #5 }
      TWord($E1A00211)     { MOV R0, R1, LSL R2 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(3);

    CheckEq('R0 = 1 << 5 = 32', 32, cpu.GetReg(0));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestMul;
{ Test 11: MUL R0, R1, R2 — 32-bit multiply, no accumulate, no flags.
  R1=7, R2=6 → R0 = 42. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestMul ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { Encoding MUL R0, R1, R2:
        cond=E 000000 A=0 S=0  Rd=0000  (Rn=0000 ignored)  Rs=0010  1001  Rm=0001
        = 1110  000000 0 0  0000  0000  0010  1001  0001
        = E 0 0 0 0 2 9 1
        = E0000291 }
    bus.Load(0, [
      TWord($E3A01007),    { MOV R1, #7 }
      TWord($E3A02006),    { MOV R2, #6 }
      TWord($E0000291)     { MUL R0, R1, R2 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(3);

    CheckEq('R0 = 7 * 6 = 42', 42, cpu.GetReg(0));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestMlaWithSFlag;
{ Test 12: MLAS R0, R1, R2, R3 — multiply-accumulate with flag update.
  R1=5, R2=4, R3=10 → R0 = 5*4 + 10 = 30. N=0, Z=0. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestMlaWithSFlag ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { MLAS R0, R1, R2, R3:
        cond=E 000000 A=1 S=1  Rd=0000  Rn=0011  Rs=0010  1001  Rm=0001
        = 1110  000000 1 1  0000  0011  0010  1001  0001
        = E 0 3 0 3 2 9 1
        = E0303291 }
    bus.Load(0, [
      TWord($E3A01005),    { MOV R1, #5 }
      TWord($E3A02004),    { MOV R2, #4 }
      TWord($E3A0300A),    { MOV R3, #10 }
      TWord($E0303291)     { MLAS R0, R1, R2, R3 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(4);

    CheckEq('R0 = 5*4 + 10 = 30', 30, cpu.GetReg(0));
    CheckFlag('CPSR.N = 0', cpu.State.CPSR, CPSR_N, False);
    CheckFlag('CPSR.Z = 0', cpu.State.CPSR, CPSR_Z, False);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestUMullLong;
{ Test 13: UMULL RdLo=R0, RdHi=R1, Rm=R2, Rs=R3.
  R2 = R3 = 0xFFFFFFFF (via MVN #0). Unsigned product = 0xFFFFFFFE00000001.
  Expected: R0 (RdLo) = 0x00000001, R1 (RdHi) = 0xFFFFFFFE. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestUMullLong ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { UMULL RdLo=R0, RdHi=R1, Rm=R2, Rs=R3 (note RdHi is in bits 19:16):
        cond=E 00001 U=0 A=0 S=0  RdHi=0001  RdLo=0000  Rs=0011  1001  Rm=0010
        = 1110  00001 0 0 0  0001  0000  0011  1001  0010
        = E 0 8 1 0 3 9 2
        = E0810392

      MVN R2, #0:  E3E02000
      MVN R3, #0:  E3E03000 }
    bus.Load(0, [
      TWord($E3E02000),    { MVN R2, #0  → R2 = 0xFFFFFFFF }
      TWord($E3E03000),    { MVN R3, #0  → R3 = 0xFFFFFFFF }
      TWord($E0810392)     { UMULL R0, R1, R2, R3 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(3);

    CheckEq('RdLo (R0) = 0x00000001', $00000001, cpu.GetReg(0));
    CheckEq('RdHi (R1) = 0xFFFFFFFE', $FFFFFFFE, cpu.GetReg(1));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestSMullLong;
{ Test 14: SMULL with same 0xFFFFFFFF * 0xFFFFFFFF inputs — signed they are -1 each.
  Signed product = (-1) * (-1) = +1. Expected: R0 (RdLo) = 1, R1 (RdHi) = 0.
  Also tests S-bit: N=0, Z=0 (result is non-zero). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestSMullLong ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { SMULLS R0, R1, R2, R3:  same as UMULL but with U=1 (signed) and S=1.
        cond=E 00001 U=1 A=0 S=1  RdHi=0001  RdLo=0000  Rs=0011  1001  Rm=0010
        = 1110  00001 1 0 1  0001  0000  0011  1001  0010
        = E 0 D 1 0 3 9 2
        = E0D10392 }
    bus.Load(0, [
      TWord($E3E02000),    { MVN R2, #0  → R2 = 0xFFFFFFFF (= -1 signed) }
      TWord($E3E03000),    { MVN R3, #0  → R3 = 0xFFFFFFFF (= -1 signed) }
      TWord($E0D10392)     { SMULLS R0, R1, R2, R3 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(3);

    CheckEq('RdLo (R0) = 1 (signed: -1 * -1 = +1)', 1, cpu.GetReg(0));
    CheckEq('RdHi (R1) = 0', 0, cpu.GetReg(1));
    CheckFlag('CPSR.N = 0 (positive result)', cpu.State.CPSR, CPSR_N, False);
    CheckFlag('CPSR.Z = 0 (non-zero result)', cpu.State.CPSR, CPSR_Z, False);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestUMlalAccumulate;
{ Test 15: UMLAL — verify accumulation actually adds [RdHi:RdLo].
  Pre-seed R0=10, R1=20.  R2=2, R3=3.  Product (unsigned) = 6.
  After UMLAL: [R1:R0] = ([20:10]) + 6 = [20:16]. So R0=16, R1=20. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestUMlalAccumulate ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { UMLAL R0, R1, R2, R3:  U=0, A=1, S=0.
        = 1110  00001 0 1 0  0001  0000  0011  1001  0010
        = E 0 A 1 0 3 9 2
        = E0A10392 }
    bus.Load(0, [
      TWord($E3A0000A),    { MOV R0, #10 — seed RdLo }
      TWord($E3A01014),    { MOV R1, #20 — seed RdHi }
      TWord($E3A02002),    { MOV R2, #2  — Rm }
      TWord($E3A03003),    { MOV R3, #3  — Rs }
      TWord($E0A10392)     { UMLAL R0, R1, R2, R3 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(5);

    CheckEq('RdLo (R0) = 10 + 6 = 16', 16, cpu.GetReg(0));
    CheckEq('RdHi (R1) = 20 (unchanged, no carry)', 20, cpu.GetReg(1));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestMrsReadCPSR;
{ Test 16: MRS R0, CPSR — verify Rd receives current CPSR value.
  Initial CPSR (after Create) = amSVC | I | F = $13 | $80 | $40 = $D3.
  Encoding MRS R0, CPSR: cond=E 00010 R=0 001111 Rd=0000 000000000000
    = 1110 0001 0000 1111 0000 0000 0000 0000 = E10F0000. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestMrsReadCPSR ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E10F0000)    { MRS R0, CPSR }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Step;

    CheckEq('R0 = CPSR = 0x000000D3', $000000D3, cpu.GetReg(0));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestMsrFlagsImmediate;
{ Test 17: MSR CPSR_f, #0xF0000000 — set N=Z=C=V via the flags byte,
  leave control bits unchanged.
  Encoding: cond=E 00110 R=0 10 mask=1000 1111 rotate=0010 imm8=00001111
    = 1110 0011 0010 1000 1111 0010 0000 1111 = E328F20F
  imm rotation: rot=2 → ROR by 4. 0x0F ROR 4 = 0xF0000000. ✓
  After: CPSR flags = 0xF0000000 (all four set), control = unchanged ($D3). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestMsrFlagsImmediate ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E328F20F)    { MSR CPSR_f, #0xF0000000 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Step;

    CheckFlag('CPSR.N = 1', cpu.State.CPSR, CPSR_N, True);
    CheckFlag('CPSR.Z = 1', cpu.State.CPSR, CPSR_Z, True);
    CheckFlag('CPSR.C = 1', cpu.State.CPSR, CPSR_C, True);
    CheckFlag('CPSR.V = 1', cpu.State.CPSR, CPSR_V, True);
    CheckFlag('CPSR.I unchanged (still 1)', cpu.State.CPSR, CPSR_I, True);
    CheckFlag('CPSR.F unchanged (still 1)', cpu.State.CPSR, CPSR_F, True);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestMsrControlRegister;
{ Test 18: BIOS's first move — MSR CPSR_c, R0 with R0 holding a value that
  clears the I bit. This is the canonical "enable IRQs" sequence.
  R0 = 0x53 (= amSVC | F, with I cleared). Then MSR CPSR_c, R0 should
  drop the I bit on CPSR while leaving the flag byte untouched.
  Encoding MSR CPSR_c, R0: cond=E 00010 R=0 10 mask=0001 1111 0000 0000 Rm=0000
    = 1110 0001 0010 0001 1111 0000 0000 0000 = E121F000. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestMsrControlRegister ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A00053),   { MOV R0, #0x53 (= SVC mode | F bit, I cleared) }
      TWord($E121F000)    { MSR CPSR_c, R0 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(2);

    CheckFlag('CPSR.I = 0 (IRQs now enabled)', cpu.State.CPSR, CPSR_I, False);
    CheckFlag('CPSR.F = 1 (FIQ still disabled)', cpu.State.CPSR, CPSR_F, True);
    CheckEq('CPSR mode bits = amSVC (0x13)', $13, cpu.State.CPSR and CPSR_MODE_MASK);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestMrsAfterFlagWrite;
{ Test 19: round-trip — set flags via MSR, then MRS reads back the new value.
  Sequence: MSR CPSR_f, #0xC0000000 (N=Z=1); MRS R0, CPSR.
  Expected R0 = 0xC00000D3 (flags set + original control byte). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestMrsAfterFlagWrite ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { 0xC0000000 = 0x0C rotated right by 4 (rot=2). imm12 = 0x20C. }
    bus.Load(0, [
      TWord($E328F20C),   { MSR CPSR_f, #0xC0000000 — sets N,Z }
      TWord($E10F0000)    { MRS R0, CPSR }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(2);

    CheckEq('R0 = 0xC00000D3 (N,Z set; control unchanged)', $C00000D3, cpu.GetReg(0));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestModeSwitchBanksR13;
{ Test 20: switch SVC → SYS → back to SVC. Verify R13 banks correctly.

  Start in SVC mode (post-Create).
  Step 1: MOV R13, #0x100 — writes visible R13 (SVC bank).
  Step 2: MSR CPSR_c, #0x1F — switch to SYS. R13 must reload from R_usr_sp (= 0).
  Step 3: MOV R13, #0x200 — writes visible R13 (now SYS = R_usr_sp).
  Step 4: MSR CPSR_c, #0x13 — switch back to SVC. R13 must reload from R_svc_sp.
  Final: visible R13 = 0x100 (the original SVC stack pointer). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestModeSwitchBanksR13 ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { MOV R13, #0x100 — opcode MOV imm to Rd=13.
        cond=E 001 11(I=1,MOV opcode=1101) 0 0000 1101 imm12=0x100
        Wait — 0x100 needs rotation. imm8=0x40, rot=0xF (rot*2=30, 0x40 ROR 30 = 0x100). Hmm,
        easier: 0x100 = 0x01 rotated right by 24. rot field = 24/2 = 12 = 0xC.
        imm12 = (0xC << 8) | 0x01 = 0xC01.
        = 1110 001 1101 0 0000 1101 1100 0000 0001 = E3A0DC01.
      MOV R13, #0x200: imm = 0x02 ROR 24, imm12 = 0xC02 → E3A0DC02. }
    bus.Load(0, [
      TWord($E3A0DC01),   { MOV R13, #0x100  (SVC bank) }
      TWord($E321F01F),   { MSR CPSR_c, #0x1F — switch to SYS }
      TWord($E3A0DC02),   { MOV R13, #0x200  (SYS = R_usr_sp) }
      TWord($E321F013)    { MSR CPSR_c, #0x13 — switch back to SVC }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(4);

    CheckEq('R13 = 0x100 (SVC bank restored)', $100, cpu.GetReg(13));
    CheckEq('CPSR mode = SVC ($13)', $13, cpu.State.CPSR and CPSR_MODE_MASK);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestModeSwitchFiqBanksR8;
{ Test 21: switch SVC → FIQ → back to SVC. Verify R8 (FIQ-banked) swaps.

  Step 1: MOV R8, #0x42 — writes R8 (currently user-shared since we're in SVC).
  Step 2: MSR CPSR_c, #0x11 — switch to FIQ. R8 must reload from R_fiq[8] (= 0).
  Step 3: MOV R8, #0xFF — writes R8 (now FIQ bank).
  Step 4: MSR CPSR_c, #0x13 — switch back to SVC. R8 must reload from R_usr[8].
  Final: visible R8 = 0x42 (the original user-shared value). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestModeSwitchFiqBanksR8 ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    { MOV R8, #0x42: Rd=8, imm12 = 0x042 (no rotate). E3A08042.
      MOV R8, #0xFF: imm12 = 0x0FF. E3A080FF.
      MSR CPSR_c, #0x11 (FIQ mode): imm12 = 0x011. E321F011. }
    bus.Load(0, [
      TWord($E3A08042),   { MOV R8, #0x42 (user-shared) }
      TWord($E321F011),   { MSR CPSR_c, #0x11 → FIQ }
      TWord($E3A080FF),   { MOV R8, #0xFF (FIQ bank) }
      TWord($E321F013)    { MSR CPSR_c, #0x13 → SVC }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(4);

    CheckEq('R8 = 0x42 (user-shared restored)', $42, cpu.GetReg(8));
    CheckEq('CPSR mode = SVC ($13)', $13, cpu.State.CPSR and CPSR_MODE_MASK);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestSpsrSwapsWithMode;
{ Test 22: each banked mode has its own SPSR slot. Setting SPSR in SVC
  then switching to IRQ, setting it again, then reading both back should
  show distinct values.

  Step 1: MSR SPSR_fsxc, #0xAA000000 → SPSR_svc gets 0xAA flag byte.
    Encoding MSR SPSR (R=1), all four field bits set (mask=1111):
      cond=E 00110 R=1 10 mask=1111 1111 imm12
      = 1110 0011 0110 1111 1111 imm12 = E36FF<imm12>
      0xAA000000 = 0xAA ROR 8 (rot=4, rot*2=8). imm12 = (4<<8)|0xAA = 0x4AA.
      Wait, 0xAA ROR 8 = 0x000000AA shifted right 8 with wrap → top 8 bits become 0xAA = 0xAA000000. ✓
      Full = E36FF4AA.

  Step 2: MSR CPSR_c, #0x12 → switch to IRQ.

  Step 3: MSR SPSR_fsxc, #0xBB000000 → SPSR_irq gets 0xBB flag byte.
      0xBB000000 = 0xBB ROR 8. imm12 = 0x4BB. Full = E36FF4BB.

  Step 4: MRS R0, SPSR (reads SPSR_irq → 0xBB000000).

  Step 5: MSR CPSR_c, #0x13 → back to SVC.

  Step 6: MRS R1, SPSR (reads SPSR_svc → 0xAA000000). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestSpsrSwapsWithMode ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E36FF4AA),   { MSR SPSR_all, #0xAA000000 (in SVC) }
      TWord($E321F012),   { MSR CPSR_c, #0x12 → IRQ }
      TWord($E36FF4BB),   { MSR SPSR_all, #0xBB000000 (in IRQ) }
      TWord($E14F0000),   { MRS R0, SPSR  (reads SPSR_irq) }
      TWord($E321F013),   { MSR CPSR_c, #0x13 → SVC }
      TWord($E14F1000)    { MRS R1, SPSR  (reads SPSR_svc) }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(6);

    CheckEq('R0 = SPSR_irq = 0xBB000000', $BB000000, cpu.GetReg(0));
    CheckEq('R1 = SPSR_svc = 0xAA000000', $AA000000, cpu.GetReg(1));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestSWI;
{ Test 23: SWI #0x12 — verify the full trap mechanic.
  Setup: switch to SYS mode and set flags. This lets us watch:
    - the mode transition SYS → SVC actually fire
    - SPSR_svc capture the SYS-mode CPSR with flag bits set
    - R14_svc receive return address (= PC of SWI + 4)
    - PC land at the SWI vector ($00000008)

  Layout:
    addr 0:  MSR CPSR_c, #0x1F    (E321F01F)   → switch to SYS
    addr 4:  MSR CPSR_f, #0xF0000000 (E328F20F) → set N=Z=C=V
    addr 8:  SWI #0x12              (EF000012)
    addr C:  MOV R0, #0xBAD        (skipped — PC jumps to $08, which
                                    happens to be the SWI itself again
                                    in our toy memory, so we stop after
                                    cpu.Run(3) instead of continuing past).

  After running 3 instructions, we expect PC = $00000008 and the various
  SVC-mode state to have been set correctly. We then verify by switching
  manually back to SVC and reading R14 (which is now R_svc_lr).

  Note: post-SWI we're already in SVC, so R14 IS the SVC LR — directly
  readable. SPSR is current-mode's SPSR after the swap, which is SPSR_svc. }
var
  bus: TMemBus;
  cpu: TArmCore;
  cpsrAfter: TWord;
begin
  Writeln('--- TestSWI ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E321F01F),    { MSR CPSR_c, #0x1F → SYS }
      TWord($E328F20F),    { MSR CPSR_f, #0xF0000000 → flags set }
      TWord($EF000012)     { SWI #0x12 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(3);

    cpsrAfter := cpu.State.CPSR;
    CheckEq('CPSR mode bits = SVC ($13)', $13, cpsrAfter and CPSR_MODE_MASK);
    CheckFlag('CPSR.I = 1 (IRQ disabled by exception entry)', cpsrAfter, CPSR_I, True);
    CheckFlag('CPSR.T = 0 (still ARM)', cpsrAfter, CPSR_T, False);
    CheckFlag('CPSR.N still 1 (flags untouched by trap)', cpsrAfter, CPSR_N, True);
    CheckEq('PC = SWI vector ($00000008)', $00000008, cpu.GetReg(R_PC));
    CheckEq('R14 (= R_svc_lr) = address of SWI + 4 = $0C', $0000000C, cpu.GetReg(R_LR));
    { SPSR_svc should now hold the pre-SWI CPSR: SYS mode + flag bits.
      MSR CPSR_c, #0x1F cleared the F bit (0x1F has bit 6 = 0), then
      MSR CPSR_f, #0xF0000000 set N/Z/C/V. Result = 0xF000001F. }
    CheckEq('SPSR_svc captured pre-SWI CPSR ($F000001F)',
            $F000001F, cpu.State.SPSR_svc);
  finally
    cpu.Free; bus.Free;
  end;
end;

{ ───── THUMB tests ──────────────────────────────────────────────── }

procedure TestBxIntoThumb;
{ Test 24: BX from ARM into THUMB. Set R0 to (target | 1), then BX R0.
  CPSR.T must become 1, PC must become target (with low bit cleared).

  Layout:
    ARM addr 0:  MOV R0, #0x9           E3A00009  (target $8 with thumb bit)
    ARM addr 4:  BX R0                  E12FFF10
    THUMB addr 8: any THUMB instruction (we won't step it — just verify state). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestBxIntoThumb ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A00009),   { MOV R0, #9  — target $8 with thumb bit set }
      TWord($E12FFF10)    { BX R0 }
    ]);
    cpu.SetReg(R_PC, 0);

    cpu.Run(2);

    CheckFlag('CPSR.T = 1 (now in THUMB mode)', cpu.State.CPSR, CPSR_T, True);
    CheckEq('PC = $8 (target with thumb bit cleared)', $8, cpu.GetReg(R_PC));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestThumbFmt1Lsl;
{ Test 25: THUMB LSL imm5. Setup: enter THUMB mode at addr 8, then run
  LSL R1, R0, #4 with R0 = 3 → R1 = 0x30, flags N=0 Z=0 C=0 (no carry out).

  ARM addr 0:  MOV R0, #3              E3A00003
  ARM addr 4:  ADR R1, thumb_code      E28F1001   (= ADD R1, PC, #1; PC+8=#0xC, so R1 = 0xD = thumb_code|1)
    Actually simpler: MOV R1, #0xD     E3A0100D
  ARM addr 8:  BX R1                   E12FFF11
  THUMB addr C: LSL R1, R0, #4         00C1        (Format 1: 00000 imm5=00100 Rs=000 Rd=001)
                                                    = 0 0000 00100 000 001 = $0101
                                                    Wait: bits 15:11 = 00000, bits 10:6 = 00100 (=4), bits 5:3 = 000 (Rs=R0), bits 2:0 = 001 (Rd=R1)
                                                    = 0000 0001 0000 0001 = $0101
  THUMB addr E: (don't step). }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestThumbFmt1Lsl ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A00003),   { MOV R0, #3 }
      TWord($E3A0100D),   { MOV R1, #0xD (= thumb target $C with bit 0 set) }
      TWord($E12FFF11)    { BX R1 }
    ]);
    bus.WriteHalf($C, $0101);   { THUMB: LSL R1, R0, #4 }
    cpu.SetReg(R_PC, 0);

    cpu.Run(4);   { 3 ARM + 1 THUMB }

    CheckFlag('CPSR.T = 1 (in THUMB)', cpu.State.CPSR, CPSR_T, True);
    CheckEq('R1 = R0 << 4 = 48', 48, cpu.GetReg(1));
    CheckFlag('CPSR.Z = 0', cpu.State.CPSR, CPSR_Z, False);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestThumbFmt2AddReg;
{ Test 26: ADD R0, R1, R2 (Format 2 register form).
  R1 = 10, R2 = 20 → R0 = 30, flags reflect the addition.
  THUMB encoding ADD reg: bits 15:9 = 0001100, bits 8:6 = Rn, 5:3 = Rs, 2:0 = Rd.
    = 00011 00 Rn(010) Rs(001) Rd(000) = 0001 1000 1000 1000 = $1888. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestThumbFmt2AddReg ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A0100A),   { MOV R1, #10 }
      TWord($E3A02014),   { MOV R2, #20 }
      TWord($E3A03011),   { MOV R3, #0x11 (THUMB target $10 | 1) }
      TWord($E12FFF13)    { BX R3 }
    ]);
    bus.WriteHalf($10, $1888);   { THUMB: ADD R0, R1, R2 }
    cpu.SetReg(R_PC, 0);

    cpu.Run(5);

    CheckEq('R0 = R1 + R2 = 30', 30, cpu.GetReg(0));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestThumbFmt3MovCmpAddSubImm;
{ Test 27: MOV R0, #0x42; ADD R0, #1; CMP R0, #0x43 — verify Z flag set.
  Encodings (Format 3, bits 15:13 = 001):
    MOV R0, #0x42:   001 00 Rd(000) imm8(0x42) = 0010 0000 0100 0010 = $2042
    ADD R0, #1:      001 10 Rd(000) imm8(0x01) = 0011 0000 0000 0001 = $3001
    CMP R0, #0x43:   001 01 Rd(000) imm8(0x43) = 0010 1000 0100 0011 = $2843 }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestThumbFmt3MovCmpAddSubImm ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A0000D),   { MOV R0, #0xD (THUMB target $C | 1) }
      TWord($E12FFF10)    { BX R0 }
    ]);
    bus.WriteHalf($C,  $2042);   { MOV R0, #0x42 }
    bus.WriteHalf($E,  $3001);   { ADD R0, #1 }
    bus.WriteHalf($10, $2843);   { CMP R0, #0x43 }
    cpu.SetReg(R_PC, 0);

    cpu.Run(5);

    CheckEq('R0 = 0x43', $43, cpu.GetReg(0));
    CheckFlag('CPSR.Z = 1 (CMP equal)', cpu.State.CPSR, CPSR_Z, True);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestThumbFmt4Alu;
{ Test 28: Format 4 ops — AND, MUL, NEG.
    R0 := 0xFF, R1 := 0x0F. AND R0, R1 → R0 = 0x0F (0xFF & 0x0F).
    Then MUL R0, R1: R0 := R0 * R1 = 0x0F * 0x0F = 0xE1.
    Then NEG R2, R0 (== Format 4 #9, but our encoding tests Rd:= -Rs).

  Format 4 encoding: bits 15:10 = 010000, bits 9:6 = opcode, bits 5:3 = Rs, 2:0 = Rd.
    AND R0, R1:  010000 0000 Rs=001 Rd=000 = 0100 0000 0000 1000 = $4008
    MUL R0, R1:  010000 1101 Rs=001 Rd=000 = 0100 0011 0100 1000 = $4348
    NEG R2, R0:  010000 1001 Rs=000 Rd=010 = 0100 0010 0100 0010 = $4242 }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestThumbFmt4Alu ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A000FF),   { MOV R0, #0xFF }
      TWord($E3A0100F),   { MOV R1, #0x0F }
      TWord($E3A03011),   { MOV R3, #0x11 (THUMB target $10) }
      TWord($E12FFF13)    { BX R3 }
    ]);
    bus.WriteHalf($10, $4008);   { AND R0, R1 }
    bus.WriteHalf($12, $4348);   { MUL R0, R1 }
    bus.WriteHalf($14, $4242);   { NEG R2, R0 }
    cpu.SetReg(R_PC, 0);

    cpu.Run(7);

    CheckEq('R0 after AND+MUL = 0x0F * 0x0F = 0xE1', $E1, cpu.GetReg(0));
    CheckEq('R2 = -R0 = -0xE1 = 0xFFFFFF1F', $FFFFFF1F, cpu.GetReg(2));
    CheckFlag('CPSR.N = 1 (NEG result negative)', cpu.State.CPSR, CPSR_N, True);
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestThumbFmt5BxBack;
{ Test 29: BX from THUMB back to ARM. In THUMB, set R0 = ARM target
  (with bit 0 clear), then BX R0.
  Format 5 BX: bits 15:7 = 010001110, bit 6 = H2, bits 5:3 = Rs[2:0], bits 2:0 = 0.
    BX R0 (Rs=R0, H2=0): 010001 11 0 0 000 000 = 0100 0111 0000 0000 = $4700. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestThumbFmt5BxBack ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A00009),   { MOV R0, #9 (THUMB target $8|1) }
      TWord($E12FFF10)    { BX R0  → enter THUMB at $8 }
    ]);
    bus.WriteHalf($8, $2120);    { THUMB MOV R1, #0x20 (= $20 ARM target with bit 0 clear) }
    bus.WriteHalf($A, $4708);    { BX R1 — back to ARM at $20 }
    bus.WriteWord($20, $E3A0507B); { ARM: MOV R5, #0x7B (so we can confirm we landed) }
    cpu.SetReg(R_PC, 0);

    cpu.Run(5);

    CheckFlag('CPSR.T = 0 (back in ARM)', cpu.State.CPSR, CPSR_T, False);
    CheckEq('R5 = 0x7B (ARM landing-pad ran)', $7B, cpu.GetReg(5));
    CheckEq('PC advanced past $20 to $24', $24, cpu.GetReg(R_PC));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestThumbFmt16CondBranch;
{ Test 30: THUMB conditional branch. CMP R0, #5 ; BEQ skip ; MOV R0, #99.
  R0 starts at 5, so BEQ taken, MOV R0, #99 skipped.

  Layout — THUMB code placed at $10 to avoid overlapping the BX instruction
  (which lives at $8 in ARM space; writing THUMB halfwords at $8 would
  overwrite the BX and the transition would never fire).

    ARM:
      $0:  MOV R0, #5             E3A00005
      $4:  MOV R1, #0x11          E3A01011   (THUMB target $10 with thumb bit)
      $8:  BX R1                  E12FFF11
    THUMB:
      $10: CMP R0, #5             $2805
      $12: BEQ +0                 $D000    → target = $12 + 4 + 0 = $16
      $14: MOV R0, #99            $2063    ← skipped
      $16: MOV R0, #0xAA          $20AA    ← branch target }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestThumbFmt16CondBranch ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A00005),   { MOV R0, #5 }
      TWord($E3A01011),   { MOV R1, #0x11 (THUMB target $10 | 1) }
      TWord($E12FFF11)    { BX R1 }
    ]);
    bus.WriteHalf($10, $2805);
    bus.WriteHalf($12, $D000);
    bus.WriteHalf($14, $2063);
    bus.WriteHalf($16, $20AA);
    cpu.SetReg(R_PC, 0);

    cpu.Run(6);

    CheckEq('R0 = 0xAA (branch taken, #99 skipped)', $AA, cpu.GetReg(0));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestThumbFmt19BL;
{ Test 31: THUMB BL — the two-halfword sequence.
  Set up a subroutine at $20 (relative to THUMB code) that sets R5 = 0x55.
  Subroutine returns via BX LR (THUMB form, $4770).

  THUMB code starts at $8.

  BL is at $8 and $A:
    target = $20. PC of low half + 4 = $A + 4 = $E. So we need
      target = $E + (final_offset). final_offset = $20 - $E = $12.
    BL encoding (24-bit signed offset):
      offset_high (bits 22:12) = $12 >> 12 = 0
      offset_low  (bits 11:1)  = ($12 >> 1) = $9
    High half (bits 15:11 = 11110, bits 10:0 = offset_high):
      = 1111 0000 0000 0000 = $F000
    Low half  (bits 15:11 = 11111, bits 10:0 = offset_low):
      = 1111 1000 0000 1001 = $F809

  Subroutine at $20:
    MOV R5, #0x55  : 001 00 Rd(101) imm8(0x55) = 0010 0101 0101 0101 = $2555
    BX LR          : Format 5 BX, Rs=LR(14)=H2:Rs_lo with H2=1, Rs_lo=110
                     = 010001 11 0 1 110 000 = 0100 0111 0111 0000 = $4770

  Expected after run:
    R5 = 0x55 (subroutine ran)
    PC = $24 (returned to instruction after BL — but wait, BX LR uses LR
              which the BL set to (next-after-BL) | 1 = ($C | 1) = $D.
              BX masks bit 0 → PC = $C. Then we step past whatever's there.
              For this test we don't put anything at $C — we step exactly
              enough times to land at $C, then stop.)

  Simpler: just verify R5 = 0x55, LR points correctly, and PC is back to $C
  after the BX-LR return. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestThumbFmt19BL ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A00009),   { MOV R0, #9 (THUMB target $8|1) }
      TWord($E12FFF10)    { BX R0 }
    ]);
    bus.WriteHalf($8,  $F000);   { BL high (offset_high = 0) }
    bus.WriteHalf($A,  $F809);   { BL low  (offset_low = 9 → +0x12 from PC of low+4) }
    { addr $C: would be the post-BL "next instruction" — unused this test }
    bus.WriteHalf($20, $2555);   { MOV R5, #0x55 }
    bus.WriteHalf($22, $4770);   { BX LR }
    cpu.SetReg(R_PC, 0);

    cpu.Run(7);   { 2 ARM + BL-high + BL-low + MOV + BX-LR + (we land at $C; no step) }

    CheckEq('R5 = 0x55 (subroutine ran)', $55, cpu.GetReg(5));
    CheckEq('LR low bit = 1 (THUMB return marker)', 1, cpu.GetReg(R_LR) and 1);
    CheckEq('PC = $C (returned from subroutine, BX masked thumb bit)', $C, cpu.GetReg(R_PC));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestThumbFmt13Fmt12;
{ Test 32: Format 13 ADD SP, #±imm and Format 12 ADD Rd, SP, #imm.
  Seed SP = 0x1000. SP += 0x80. Then load R0 := SP + 0x40.
  Expected: SP = 0x1080, R0 = 0x10C0.

  Layout — THUMB at $10 to avoid colliding with the BX at $8.

    ARM:
      $0:  MOV R13, #0x1000     E3A0DA01   (0x01 ROR 20 = 0x1000)
      $4:  MOV R1, #0x11        E3A01011   (THUMB target $10 with thumb bit)
      $8:  BX R1                E12FFF11
    THUMB:
      $10: ADD SP, #0x80        $B020
      $12: ADD R0, SP, #0x40    $A810 }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestThumbFmt13Fmt12 ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A0DA01),   { MOV R13, #0x1000 }
      TWord($E3A01011),   { MOV R1, #0x11 (THUMB target $10 | 1) }
      TWord($E12FFF11)    { BX R1 }
    ]);
    bus.WriteHalf($10, $B020);
    bus.WriteHalf($12, $A810);
    cpu.SetReg(R_PC, 0);

    cpu.Run(5);

    CheckEq('SP = 0x1080 after ADD SP, #0x80', $1080, cpu.GetReg(R_SP));
    CheckEq('R0 = 0x10C0 (SP + 0x40)', $10C0, cpu.GetReg(0));
  finally
    cpu.Free; bus.Free;
  end;
end;

procedure TestThumbFmt18Branch;
{ Test 33: THUMB unconditional B. From $8: B +0x10 should land at $1C.

  B +N encoding: 11100 imm11(signed) where target = PC+4 + (imm11 << 1).
  We want target $1C, PC of B = $8, so PC+4 = $C. Offset (in halfwords) = ($1C - $C) >> 1 = $8.
  Encoding: 11100 00000001000 = 1110 0000 0000 1000 = $E008. }
var
  bus: TMemBus;
  cpu: TArmCore;
begin
  Writeln('--- TestThumbFmt18Branch ---');
  bus := TMemBus.Create($1000);
  cpu := TArmCore.Create;
  try
    cpu.SetMemoryHooks(@bus.ReadWord, @bus.ReadHalf, @bus.ReadByte,
                       @bus.WriteWord, @bus.WriteHalf, @bus.WriteByte);

    bus.Load(0, [
      TWord($E3A00009),   { MOV R0, #9 (THUMB target $8|1) }
      TWord($E12FFF10)    { BX R0 }
    ]);
    bus.WriteHalf($8,  $E008);   { B +0x10 — target $1C }
    bus.WriteHalf($A,  $2099);   { MOV R0, #0x99 — should be skipped }
    bus.WriteHalf($1C, $2077);   { MOV R0, #0x77 — branch target }
    cpu.SetReg(R_PC, 0);

    cpu.Run(4);   { 2 ARM + B + MOV-at-target }

    CheckEq('R0 = 0x77 (branch target ran, $99 skipped)', $77, cpu.GetReg(0));
  finally
    cpu.Free; bus.Free;
  end;
end;

begin
  Writeln('ARM7TDMI core — Phase A acceptance tests');
  Writeln('==========================================');
  Writeln('');
  TestMovImmediate;
  Writeln('');
  TestAddImmediate;
  Writeln('');
  TestCmpAndConditionalBranch;
  Writeln('');
  TestBranchAndLink;
  Writeln('');
  TestShiftLSLImmediate;
  Writeln('');
  TestShiftLSRImmediate;
  Writeln('');
  TestShiftASRImmediate;
  Writeln('');
  TestShiftRORImmediate;
  Writeln('');
  TestRRX;
  Writeln('');
  TestShiftByRegister;
  Writeln('');
  TestMul;
  Writeln('');
  TestMlaWithSFlag;
  Writeln('');
  TestUMullLong;
  Writeln('');
  TestSMullLong;
  Writeln('');
  TestUMlalAccumulate;
  Writeln('');
  TestMrsReadCPSR;
  Writeln('');
  TestMsrFlagsImmediate;
  Writeln('');
  TestMsrControlRegister;
  Writeln('');
  TestMrsAfterFlagWrite;
  Writeln('');
  TestModeSwitchBanksR13;
  Writeln('');
  TestModeSwitchFiqBanksR8;
  Writeln('');
  TestSpsrSwapsWithMode;
  Writeln('');
  TestSWI;
  Writeln('');
  TestBxIntoThumb;
  Writeln('');
  TestThumbFmt1Lsl;
  Writeln('');
  TestThumbFmt2AddReg;
  Writeln('');
  TestThumbFmt3MovCmpAddSubImm;
  Writeln('');
  TestThumbFmt4Alu;
  Writeln('');
  TestThumbFmt5BxBack;
  Writeln('');
  TestThumbFmt16CondBranch;
  Writeln('');
  TestThumbFmt19BL;
  Writeln('');
  TestThumbFmt13Fmt12;
  Writeln('');
  TestThumbFmt18Branch;
  Writeln('');
  Writeln('==========================================');
  Writeln(Format('Result: %d pass, %d fail', [PassCount, FailCount]));
  if FailCount > 0 then Halt(1);
end.
