unit ArmCore;
{
  ARM7TDMI interpreter core. Phase A of the GBA emulator capstone.

  ── Scope of this version ──

  This is the v1 scaffolding. It proves the architecture works end-to-end
  by implementing enough opcodes to run a small hand-built program:

    * Data Processing (DP) immediate forms — MOV, MVN, AND, EOR, ORR,
      BIC, ADD, SUB, RSB, ADC, SBC, RSC, CMP, CMN, TST, TEQ
    * Data Processing register forms (no shifted-register operand yet)
    * Branch (B) and Branch-with-Link (BL)
    * Condition-code evaluation (all 16 conditions including AL/NV)
    * CPSR flag update on S-bit set
    * Pipeline emulation (PC reads as PC+8 in ARM mode)

  NOT yet implemented (deferred to subsequent phases):

    * Shifted-register operand 2 (LSL/LSR/ASR/ROR/RRX)
    * Multiply (MUL/MLA, UMULL/SMULL etc.)
    * Single Data Transfer (LDR/STR) — needs Memory unit first
    * Block Data Transfer (LDM/STM)
    * Halfword/byte/signed transfers
    * MSR/MRS (CPSR/SPSR access)
    * Software Interrupt (SWI)
    * Coprocessor instructions
    * THUMB instruction set (entire 16-bit ISA)
    * Mode switching / banked register swap (the storage exists in
      TArmState; the swap logic comes when we need it)

  Reference: ARM Architecture Reference Manual (ARMv4T), §A3-A5.
  Cross-reference: GBATEK (problemkaputt.de/gbatek.htm) for GBA-specific
  edge cases — but for the pure ISA, the ARM ARM is canonical.

  ── Pipeline model ──

  ARM7TDMI has a 3-stage pipeline: fetch / decode / execute. When the
  CPU is executing instruction at address X, the PC value visible to
  that instruction (via R[15]) is X+8 — because two instructions ahead
  are already in the pipeline.

  We model this by storing the CURRENT execution address in R[15] and
  adding +8 in the few opcodes that actually read PC (mostly branches).
  This is simpler than maintaining a separate pipeline buffer and
  produces identical observable behavior for the non-cycle-accurate
  bar we're targeting.

  After executing an instruction at X, we advance PC by 4 (ARM) or 2
  (Thumb) UNLESS the instruction itself wrote R[15] (branch / load to
  R15 / data-op into R15). The Branch helper writes the target into
  R[15] directly; the caller checks "did PC change?" to decide whether
  to do the +4 step.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes;

type
  { Reader callback — emulator's memory subsystem will implement these.
    For phase A's self-tests we install a trivial RAM-array reader. }
  TMemReadWord  = function(addr: TWord): TWord of object;
  TMemReadHalf  = function(addr: TWord): THalf of object;
  TMemReadByte  = function(addr: TWord): TByte of object;
  TMemWriteWord = procedure(addr: TWord; v: TWord) of object;
  TMemWriteHalf = procedure(addr: TWord; v: THalf) of object;
  TMemWriteByte = procedure(addr: TWord; v: TByte) of object;

  { IRQ-pending oracle. Returned by the IRQ controller; CPU calls this
    at the start of each Step. If True (and CPSR.I = 0), the CPU takes
    the IRQ exception, jumping to vector $00000018. }
  TIrqPendingCheck = function: Boolean of object;

  { BIOS HLE hook. Called when a SWI is about to execute. If the hook
    returns True, the SWI is considered handled in Pascal and the CPU
    skips the normal exception entry, just advances PC past the SWI.
    If False, the standard SWI exception entry fires (jump to $08). }
  TSwiHook = function(swiNum: TByte): Boolean of object;

  TArmCore = class
  private
    FState: TArmState;

    { Set to True by any handler that intentionally writes PC (branches,
      SWI, MOVS PC, etc.). Reset at the start of each Step. The Step
      tail uses this to decide whether to do the sequential +4 advance,
      so that pathological cases like "branch lands on its own address"
      and "SWI at the SWI vector" don't get spuriously advanced. }
    FBranched: Boolean;

    FReadWord:  TMemReadWord;
    FReadHalf:  TMemReadHalf;
    FReadByte:  TMemReadByte;
    FWriteWord: TMemWriteWord;
    FWriteHalf: TMemWriteHalf;
    FWriteByte: TMemWriteByte;

    FIrqCheck:  TIrqPendingCheck;
    FWakeCheck: TIrqPendingCheck;
    FSwiHook:   TSwiHook;

  public
    { Telemetry: count of IRQ exception entries, and the last 4 entry PCs
      for diagnostics. Tests can read these to verify the IRQ pipeline
      fired without needing a runtime tracer. }
    IrqEntryCount: Int64;
    LastIrqEntryPc: array[0..3] of TWord;
    TraceBiosLdrPc:           Int64;
    TraceBiosUserHandler:     Int64;
    TraceBiosStrhIntrCheck:   Int64;
    TraceBiosHaltcntWrite:    Int64;
    TraceEhtFromStrhEq:       Int64;
    LastIrqEntryIdx: Integer;

    { SWI telemetry — counts every SWI executed regardless of whether the
      HLE hook handled it. Independent of BIOS_HLE so it works even when
      the hook isn't installed (BIOS handles all SWIs natively in that case).
      Indexed by SWI number 0..255. The F12 dump reads this to surface
      'which BIOS routines has the game actually invoked'. }
    SwiExecCount: array[0..255] of Int64;

  private
    { Perform the IRQ exception entry — called at the start of Step when
      an IRQ is pending and CPSR.I = 0. Per ARM ARM §A2.6.6:
        R14_irq ← address-of-next-instruction-to-execute + 4
        SPSR_irq ← CPSR
        CPSR mode ← IRQ ; CPSR.I ← 1 ; CPSR.T ← 0
        PC ← $00000018
      Handler returns via SUBS PC, LR, #4 (lands back at the instruction
      that was about to run). }
    procedure TakeIrq;

    { Decode the condition field (bits 31:28) and return True if the
      instruction should execute given the current CPSR flags. }
    function EvaluateCondition(cond: TByte): Boolean;

    { Compute the immediate operand 2 for data-processing instructions:
      rotated 8-bit immediate per ARM ARM §A5.1.3. Updates carry-out
      when the rotate is non-zero (relevant for the S-bit case). }
    procedure DecodeOp2Immediate(instr: TWord; out value: TWord; out carryOut: Boolean);

    { Compute the register operand 2 for data-processing instructions:
      shifted register per ARM ARM §A5.1.4 through §A5.1.9. Handles all
      five shift types (LSL/LSR/ASR/ROR/RRX) in both immediate-shift and
      register-shift sub-forms, including the four "amount = 0" special
      cases for immediate-shift and the boundary conditions (32, >32) for
      register-shift. Also returns whether the shift was register-form,
      which the caller needs to know for the PC+12 vs PC+8 quirk. }
    procedure DecodeOp2Register(instr: TWord;
                                 out value: TWord;
                                 out carryOut: Boolean;
                                 out regShiftForm: Boolean);

    { Update N/Z flags from a result. Used by all logical DP ops
      (AND/ORR/EOR/MOV/MVN/BIC/TST/TEQ) when S=1. }
    procedure UpdateNZ(result: TWord);

    { Update N/Z/C/V flags from an arithmetic result. Used by
      ADD/SUB/RSB/ADC/SBC/RSC/CMP/CMN when S=1. The carryOut and
      overflow values are computed in the op-specific helpers below. }
    procedure UpdateNZCV(result, carry, overflow: TWord);

    { Per-opcode dispatch handlers. Each handles ONE opcode shape (the
      bits-27:26 + bits-25 + bit-7 + bit-4 classification slot). The
      top-level Execute() routes to these via the instruction-class
      decode. }
    procedure ExecDataProcessing(instr: TWord);
    procedure ExecBranch(instr: TWord);

    { Single Data Transfer — LDR/STR with byte variants. Per ARM ARM
      §A4.1.23. Immediate or shifted-register offset, pre/post indexing,
      up/down direction, optional writeback. The B bit selects byte vs
      word access. Misaligned word LDR triggers the rotated-read quirk. }
    procedure ExecSingleDataTransfer(instr: TWord);

    { Halfword/Signed Data Transfer — LDRH/STRH/LDRSB/LDRSH. Per ARM ARM
      §A4.1.20. Lives in class 0 with bits 7:4 having pattern 1ss1 where
      ss = the SH field selecting the operation. Offset is split between
      bits 11:8 and 3:0 (immediate form) or just Rm in bits 3:0. }
    procedure ExecHalfwordTransfer(instr: TWord);

    { Block Data Transfer — LDM/STM. Per ARM ARM §A4.1.21, §A4.1.40.
      Transfers an arbitrary subset of R0..R15 to/from memory based at
      Rn. Four addressing modes (IB/IA/DB/DA). Registers are always
      transferred in ascending order regardless of mode. }
    procedure ExecBlockDataTransfer(instr: TWord);

    { 32-bit multiply (MUL / MLA). Per ARM ARM §A4.1.32, §A4.1.30. }
    procedure ExecMultiply(instr: TWord);

    { 64-bit long multiply (UMULL / SMULL / UMLAL / SMLAL). Per ARM ARM
      §A4.1.55, §A4.1.50, §A4.1.54, §A4.1.49. }
    procedure ExecMultiplyLong(instr: TWord);

    { PSR transfer — MRS (read CPSR/SPSR) and MSR (write CPSR/SPSR
      fields). Per ARM ARM §A4.1.38, §A4.1.39. }
    procedure ExecPsrTransfer(instr: TWord);

    { Read/write the SPSR slot for the current processor mode. User and
      System modes have no SPSR — those reads return CPSR (per ARM's
      "unpredictable" allowance) and writes are no-ops. }
    function  GetCurrentSpsr: TWord;
    procedure SetCurrentSpsr(v: TWord);

    { Mode-switch helper. Saves the current visible R8..R14 to the bank
      slots of the old mode, then loads the new mode's bank slots into
      R8..R14. R8..R12 only move when FIQ is on one side of the
      transition; R13..R14 move between every distinct privileged mode. }
    procedure SwapBanksForMode(oldMode, newMode: TWord);

    { Canonical CPSR-write site. If the mode field changes, performs the
      banked-register swap, then stores the new value. All MSR-to-CPSR
      paths must route through here. }
    procedure WriteCPSR(newValue: TWord);

    { Software interrupt — trap to SVC mode and jump to the SWI exception
      vector at $00000008. Per ARM ARM §A2.6.7. The handler at the vector
      is responsible for reading the SWI comment field from the saved
      instruction and dispatching the BIOS function — that's a Phase B
      concern (needs the real BIOS image loaded). }
    procedure ExecSWI(instr: TWord);

    { Branch-and-Exchange — the ARM ↔ THUMB transition primitive. The
      target's low bit selects mode: 1 → THUMB, 0 → ARM. Target PC is
      Rn with the bottom bit(s) cleared. Per ARM ARM §A4.1.10. }
    procedure ExecBranchExchange(instr: TWord);

    { THUMB step. Branches off Step() when CPSR.T = 1. Fetches 16-bit
      halfword, decodes via the top-bit hierarchy of ARM ARM Table A6-1,
      advances PC by 2 if not branched. }
    procedure StepThumb(pcBefore: TWord);

    { THUMB instruction handlers, one per format from ARM ARM §A6.1. The
      handlers reuse the ARM-side ALU helpers (DoADD, DoSUB, etc.) where
      possible — most THUMB ops are direct sub-encodings of ARM patterns. }
    procedure ExecThumbFmt1ShiftedReg(instr: THalf);        { LSL/LSR/ASR imm5 }
    procedure ExecThumbFmt2AddSub(instr: THalf);            { ADD/SUB reg or imm3 }
    procedure ExecThumbFmt3MovCmpAddSubImm(instr: THalf);   { MOV/CMP/ADD/SUB imm8 }
    procedure ExecThumbFmt4Alu(instr: THalf);               { 16-op ALU }
    procedure ExecThumbFmt5HiRegOrBX(instr: THalf);         { hi-reg ADD/CMP/MOV/BX }
    procedure ExecThumbFmt6PcLoad(instr: THalf);            { LDR Rd, [PC, #imm8<<2] }
    procedure ExecThumbFmt7RegOffset(instr: THalf);         { LDR/STR/LDRB/STRB Rd, [Rb, Ro] }
    procedure ExecThumbFmt8SignExt(instr: THalf);           { LDRH/STRH/LDRSB/LDRSH reg-offset }
    procedure ExecThumbFmt9ImmOffset(instr: THalf);         { LDR/STR(B) Rd, [Rb, #imm] }
    procedure ExecThumbFmt10Halfword(instr: THalf);         { LDRH/STRH Rd, [Rb, #imm5<<1] }
    procedure ExecThumbFmt11SpRel(instr: THalf);            { LDR/STR Rd, [SP, #imm8<<2] }
    procedure ExecThumbFmt12LoadAddr(instr: THalf);         { ADD Rd, [PC|SP], #imm }
    procedure ExecThumbFmt13AddOffsetSP(instr: THalf);      { ADD SP, #±imm }
    procedure ExecThumbFmt14PushPop(instr: THalf);          { PUSH/POP {regs, optional LR/PC} }
    procedure ExecThumbFmt15Multiple(instr: THalf);         { LDMIA/STMIA Rb!, {regs} }
    procedure ExecThumbFmt16CondBranch(instr: THalf);       { B<cond> }
    procedure ExecThumbFmt17SWI(instr: THalf);              { SWI }
    procedure ExecThumbFmt18Branch(instr: THalf);           { unconditional B }
    procedure ExecThumbFmt19BL(instr: THalf);               { BL — two-half sequence }

    { ALU op subroutines, one per data-processing opcode. The DP opcode
      lives in instr bits 24:21. }
    procedure DoAND(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean; carryOut: Boolean);
    procedure DoEOR(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean; carryOut: Boolean);
    procedure DoSUB(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
    procedure DoRSB(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
    procedure DoADD(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
    procedure DoADC(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
    procedure DoSBC(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
    procedure DoRSC(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
    procedure DoTST(rnVal, op2Val: TWord; carryOut: Boolean);
    procedure DoTEQ(rnVal, op2Val: TWord; carryOut: Boolean);
    procedure DoCMP(rnVal, op2Val: TWord);
    procedure DoCMN(rnVal, op2Val: TWord);
    procedure DoORR(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean; carryOut: Boolean);
    procedure DoMOV(rd: Integer; op2Val: TWord; sBit: Boolean; carryOut: Boolean);
    procedure DoBIC(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean; carryOut: Boolean);
    procedure DoMVN(rd: Integer; op2Val: TWord; sBit: Boolean; carryOut: Boolean);

  public
    constructor Create;
    destructor Destroy; override;

    { Wire up the memory subsystem. Required before Execute() can
      fetch instructions. For phase A's self-tests, GbaTypes-side
      thunks provide a trivial RAM-backed memory. }
    procedure SetMemoryHooks(rw: TMemReadWord; rh: TMemReadHalf; rb: TMemReadByte;
                              ww: TMemWriteWord; wh: TMemWriteHalf; wb: TMemWriteByte);

    { Install the IRQ oracle. The CPU calls this at the start of each
      Step; if it returns True AND CPSR.I = 0, the CPU takes the IRQ
      exception. Pass nil to disable (default at construction time). }
    procedure SetIrqHook(check: TIrqPendingCheck);

    { Install the halt-wake oracle: a raw IE-and-IF request check with
      no IME gate. Per GBATEK, Halt ends when an enabled interrupt is
      requested regardless of IME; without this hook the halt path
      falls back to the (stricter) IRQ oracle above, which leaves the
      CPU asleep forever when BIOS code Halts with IME off. }
    procedure SetHaltWakeHook(check: TIrqPendingCheck);

    { Install the BIOS HLE hook. The CPU calls this when a SWI
      executes (in either ARM or THUMB mode). If the hook returns True,
      the SWI is considered handled by Pascal; the CPU advances past it
      without taking the exception. Pass nil to disable. }
    procedure SetSwiHook(hook: TSwiHook);

    { Method-of-object compatible with Memory's THaltRequestHook —
      register this as `mem.SetHaltRequestHook(@cpu.OnHaltRequested)`
      so writes to HALTCNT halt the CPU. Wakes on next IRQ via the
      check inside Step. }
    procedure OnHaltRequested;

    { Fetch + decode + execute one instruction at PC. After execution,
      PC has advanced by 4 (ARM) or 2 (Thumb), or jumped if the
      instruction was a branch / wrote R15 directly. Returns the
      number of cycles consumed (currently always 1 — cycle accuracy
      comes in a later phase). }
    function Step: Integer;

    { Convenience: run N steps, or until Halted is set. }
    procedure Run(maxSteps: Integer);

    { Direct register access for tests + debug. }
    function GetReg(n: Integer): TWord;
    procedure SetReg(n: Integer; v: TWord);

    { State getters/setters for tests. }
    property State: TArmState read FState write FState;
  end;

implementation

{ ───── Construction ──────────────────────────────────────────────── }

constructor TArmCore.Create;
begin
  inherited Create;
  FillChar(FState, SizeOf(FState), 0);
  { Reset state: PC = 0, CPSR = Supervisor mode + IRQ/FIQ disabled.
    Real GBA boot has the BIOS at PC=0; phase A tests will override. }
  FState.CPSR := Ord(amSVC) or CPSR_I or CPSR_F;
  FIrqCheck := nil;
  FWakeCheck := nil;
  FSwiHook := nil;
  IrqEntryCount := 0;
  LastIrqEntryIdx := 0;
  FillChar(LastIrqEntryPc, SizeOf(LastIrqEntryPc), 0);
end;

destructor TArmCore.Destroy;
begin
  inherited Destroy;
end;

procedure TArmCore.SetMemoryHooks(rw: TMemReadWord; rh: TMemReadHalf; rb: TMemReadByte;
                                    ww: TMemWriteWord; wh: TMemWriteHalf; wb: TMemWriteByte);
begin
  FReadWord  := rw;
  FReadHalf  := rh;
  FReadByte  := rb;
  FWriteWord := ww;
  FWriteHalf := wh;
  FWriteByte := wb;
end;

procedure TArmCore.SetIrqHook(check: TIrqPendingCheck);
begin
  FIrqCheck := check;
end;

procedure TArmCore.SetHaltWakeHook(check: TIrqPendingCheck);
begin
  FWakeCheck := check;
end;

procedure TArmCore.SetSwiHook(hook: TSwiHook);
begin
  FSwiHook := hook;
end;

procedure TArmCore.OnHaltRequested;
begin
  FState.Halted := True;
end;

procedure TArmCore.TakeIrq;
var
  oldCPSR, returnAddr, newCPSR: TWord;
begin
  oldCPSR := FState.CPSR;
  returnAddr := FState.R[R_PC] + 4;

  newCPSR := (FState.CPSR and not (CPSR_MODE_MASK or CPSR_T))
             or Ord(amIRQ) or CPSR_I;
  WriteCPSR(newCPSR);

  FState.R[R_LR] := returnAddr;
  SetCurrentSpsr(oldCPSR);

  FState.R[R_PC] := $00000018;
  FBranched := True;

  { Telemetry. }
  LastIrqEntryPc[LastIrqEntryIdx and 3] := returnAddr - 4;
  Inc(LastIrqEntryIdx);
  Inc(IrqEntryCount);
end;

function TArmCore.GetReg(n: Integer): TWord;
begin
  Result := FState.R[n];
end;

procedure TArmCore.SetReg(n: Integer; v: TWord);
begin
  FState.R[n] := v;
end;

{ ───── Flag helpers ──────────────────────────────────────────────── }

procedure TArmCore.UpdateNZ(result: TWord);
begin
  { Clear N/Z; set N if bit 31, set Z if zero. C and V unchanged. }
  FState.CPSR := FState.CPSR and not (CPSR_N or CPSR_Z);
  if (result and $80000000) <> 0 then FState.CPSR := FState.CPSR or CPSR_N;
  if result = 0                  then FState.CPSR := FState.CPSR or CPSR_Z;
end;

procedure TArmCore.UpdateNZCV(result, carry, overflow: TWord);
begin
  FState.CPSR := FState.CPSR and not (CPSR_N or CPSR_Z or CPSR_C or CPSR_V);
  if (result   and $80000000) <> 0 then FState.CPSR := FState.CPSR or CPSR_N;
  if result    = 0                 then FState.CPSR := FState.CPSR or CPSR_Z;
  if carry     <> 0                then FState.CPSR := FState.CPSR or CPSR_C;
  if overflow  <> 0                then FState.CPSR := FState.CPSR or CPSR_V;
end;

{ ───── Condition evaluation ──────────────────────────────────────── }

function TArmCore.EvaluateCondition(cond: TByte): Boolean;
{ Per ARM ARM §A3.2, 16 conditions encoded in instr[31:28]. }
var
  n, z, c, v: Boolean;
begin
  n := (FState.CPSR and CPSR_N) <> 0;
  z := (FState.CPSR and CPSR_Z) <> 0;
  c := (FState.CPSR and CPSR_C) <> 0;
  v := (FState.CPSR and CPSR_V) <> 0;

  case cond of
    $0: Result := z;                                { EQ — equal }
    $1: Result := not z;                            { NE — not equal }
    $2: Result := c;                                { CS/HS — unsigned ≥ }
    $3: Result := not c;                            { CC/LO — unsigned < }
    $4: Result := n;                                { MI — negative }
    $5: Result := not n;                            { PL — non-negative }
    $6: Result := v;                                { VS — overflow }
    $7: Result := not v;                            { VC — no overflow }
    $8: Result := c and (not z);                    { HI — unsigned > }
    $9: Result := (not c) or z;                     { LS — unsigned ≤ }
    $A: Result := n = v;                            { GE — signed ≥ }
    $B: Result := n <> v;                           { LT — signed < }
    $C: Result := (not z) and (n = v);              { GT — signed > }
    $D: Result := z or (n <> v);                    { LE — signed ≤ }
    $E: Result := True;                             { AL — always }
    $F: Result := False;                            { NV — never (ARMv4 reserved; ARMv5+ uses BLX) }
  else
    Result := False;
  end;
end;

{ ───── Operand 2 decode (immediate form) ─────────────────────────── }

procedure TArmCore.DecodeOp2Immediate(instr: TWord; out value: TWord; out carryOut: Boolean);
{ Per ARM ARM §A5.1.3: rotated immediate.
    imm8     = instr[7:0]
    rot      = instr[11:8] * 2
    value    = imm8 ROR rot
    carryOut = if rot = 0 then current_C else value[31] }
var
  imm8, rot: TWord;
begin
  imm8 := instr and $FF;
  rot  := ((instr shr 8) and $F) * 2;

  if rot = 0 then
  begin
    value := imm8;
    carryOut := (FState.CPSR and CPSR_C) <> 0;
  end
  else
  begin
    { Rotate right }
    value := (imm8 shr rot) or (imm8 shl (32 - rot));
    carryOut := (value and $80000000) <> 0;
  end;
end;

{ ───── Operand 2 decode (shifted register) ───────────────────────── }

procedure TArmCore.DecodeOp2Register(instr: TWord;
                                      out value: TWord;
                                      out carryOut: Boolean;
                                      out regShiftForm: Boolean);
{ Per ARM ARM §A5.1.4–§A5.1.9. Encoding (within the bottom 12 bits):

    immediate-shift form (instr[4] = 0):
      bits 11:7  = shift amount (0..31)
      bits 6:5   = shift type (00 LSL, 01 LSR, 10 ASR, 11 ROR)
      bit 4      = 0
      bits 3:0   = Rm

    register-shift form (instr[4] = 1, instr[7] = 0):
      bits 11:8  = Rs (shift amount in Rs[7:0])
      bits 6:5   = shift type
      bit 7      = 0           (distinguishes from multiply / etc.)
      bit 4      = 1
      bits 3:0   = Rm

  Special cases for immediate-shift with shift amount = 0:
    LSL #0 → no shift, value = Rm, carryOut = current C
    LSR #0 → encodes LSR #32: value = 0, carryOut = Rm[31]
    ASR #0 → encodes ASR #32: value = arith-sign-extend, carryOut = Rm[31]
    ROR #0 → encodes RRX: value = (C << 31) | (Rm >> 1), carryOut = Rm[0]

  Register-shift edge cases (per ARM ARM):
    Rs[7:0] = 0          : no shift, carryOut = current C
    LSL by 32            : value = 0,  carryOut = Rm[0]
    LSL by > 32          : value = 0,  carryOut = 0
    LSR by 32            : value = 0,  carryOut = Rm[31]
    LSR by > 32          : value = 0,  carryOut = 0
    ASR by ≥ 32          : value = sign-fill, carryOut = Rm[31]
    ROR by Rs[4:0] = 0   : value = Rm, carryOut = Rm[31]   (Rs[7:0] non-zero)

  R15-as-Rm quirk: in immediate-shift form, R15 reads as PC+8 (normal
  pipeline). In register-shift form, R15 reads as PC+12 (extra cycle
  for the Rs read). The caller computes the proper Rm value via the
  regShiftForm output. }
var
  rm: Integer;
  rmVal: TWord;
  shiftType: Integer;
  shiftAmt: TWord;       { effective shift count (0..255) }
  rs: Integer;
  curC: TWord;
begin
  rm := instr and $F;
  shiftType := (instr shr 5) and $3;
  regShiftForm := ((instr shr 4) and 1) = 1;

  rmVal := FState.R[rm];
  { R15 pipeline offset depends on whether the shift is register-form. }
  if rm = R_PC then
  begin
    if regShiftForm then Inc(rmVal, 12)
                    else Inc(rmVal, 8);
  end;

  if (FState.CPSR and CPSR_C) <> 0 then curC := 1 else curC := 0;

  if regShiftForm then
  begin
    { Register-shift form: shift amount is Rs[7:0]. }
    rs := (instr shr 8) and $F;
    shiftAmt := FState.R[rs] and $FF;

    if shiftAmt = 0 then
    begin
      { No shift, no flag change. }
      value := rmVal;
      carryOut := (FState.CPSR and CPSR_C) <> 0;
      Exit;
    end;

    case shiftType of
      $0:  { LSL }
        begin
          if shiftAmt < 32 then
          begin
            value := rmVal shl shiftAmt;
            carryOut := ((rmVal shr (32 - shiftAmt)) and 1) <> 0;
          end
          else if shiftAmt = 32 then
          begin
            value := 0;
            carryOut := (rmVal and 1) <> 0;
          end
          else
          begin
            value := 0;
            carryOut := False;
          end;
        end;
      $1:  { LSR }
        begin
          if shiftAmt < 32 then
          begin
            value := rmVal shr shiftAmt;
            carryOut := ((rmVal shr (shiftAmt - 1)) and 1) <> 0;
          end
          else if shiftAmt = 32 then
          begin
            value := 0;
            carryOut := (rmVal and $80000000) <> 0;
          end
          else
          begin
            value := 0;
            carryOut := False;
          end;
        end;
      $2:  { ASR }
        begin
          if shiftAmt < 32 then
          begin
            { Arithmetic shift right: sign-bit fill. }
            if (rmVal and $80000000) <> 0 then
              value := (rmVal shr shiftAmt) or (TWord($FFFFFFFF) shl (32 - shiftAmt))
            else
              value := rmVal shr shiftAmt;
            carryOut := ((rmVal shr (shiftAmt - 1)) and 1) <> 0;
          end
          else
          begin
            { ≥ 32: result is all-sign-bit. }
            if (rmVal and $80000000) <> 0 then value := $FFFFFFFF
                                          else value := 0;
            carryOut := (rmVal and $80000000) <> 0;
          end;
        end;
      $3:  { ROR }
        begin
          { ARM ROR by a register: only Rs[4:0] determine the actual rotation.
            If Rs[4:0] = 0 but Rs[7:0] non-zero, rotation is 0 (no-op on value)
            but carryOut = Rm[31]. }
          shiftAmt := shiftAmt and $1F;
          if shiftAmt = 0 then
          begin
            value := rmVal;
            carryOut := (rmVal and $80000000) <> 0;
          end
          else
          begin
            value := (rmVal shr shiftAmt) or (rmVal shl (32 - shiftAmt));
            carryOut := ((rmVal shr (shiftAmt - 1)) and 1) <> 0;
          end;
        end;
    end;
  end
  else
  begin
    { Immediate-shift form: shift amount is instr[11:7]. }
    shiftAmt := (instr shr 7) and $1F;

    case shiftType of
      $0:  { LSL #imm }
        begin
          if shiftAmt = 0 then
          begin
            { LSL #0 = no shift, carry unchanged. }
            value := rmVal;
            carryOut := (FState.CPSR and CPSR_C) <> 0;
          end
          else
          begin
            value := rmVal shl shiftAmt;
            carryOut := ((rmVal shr (32 - shiftAmt)) and 1) <> 0;
          end;
        end;
      $1:  { LSR #imm }
        begin
          if shiftAmt = 0 then
          begin
            { LSR #0 encodes LSR #32. }
            value := 0;
            carryOut := (rmVal and $80000000) <> 0;
          end
          else
          begin
            value := rmVal shr shiftAmt;
            carryOut := ((rmVal shr (shiftAmt - 1)) and 1) <> 0;
          end;
        end;
      $2:  { ASR #imm }
        begin
          if shiftAmt = 0 then
          begin
            { ASR #0 encodes ASR #32: result is sign-bit fill. }
            if (rmVal and $80000000) <> 0 then value := $FFFFFFFF
                                          else value := 0;
            carryOut := (rmVal and $80000000) <> 0;
          end
          else
          begin
            if (rmVal and $80000000) <> 0 then
              value := (rmVal shr shiftAmt) or (TWord($FFFFFFFF) shl (32 - shiftAmt))
            else
              value := rmVal shr shiftAmt;
            carryOut := ((rmVal shr (shiftAmt - 1)) and 1) <> 0;
          end;
        end;
      $3:  { ROR #imm  /  RRX (when imm = 0) }
        begin
          if shiftAmt = 0 then
          begin
            { RRX: rotate right through carry, 1 bit. }
            value := (curC shl 31) or (rmVal shr 1);
            carryOut := (rmVal and 1) <> 0;
          end
          else
          begin
            value := (rmVal shr shiftAmt) or (rmVal shl (32 - shiftAmt));
            carryOut := ((rmVal shr (shiftAmt - 1)) and 1) <> 0;
          end;
        end;
    end;
  end;
end;

{ ───── Data Processing — per-opcode helpers ──────────────────────── }

procedure TArmCore.DoMOV(rd: Integer; op2Val: TWord; sBit: Boolean; carryOut: Boolean);
{ MOV Rd, Op2 — Rd := Op2. Logical op, so S updates N/Z and may set C. }
begin
  FState.R[rd] := op2Val;
  if sBit and (rd <> R_PC) then
  begin
    UpdateNZ(op2Val);
    if carryOut then FState.CPSR := FState.CPSR or CPSR_C
                else FState.CPSR := FState.CPSR and not CPSR_C;
  end;
end;

procedure TArmCore.DoMVN(rd: Integer; op2Val: TWord; sBit: Boolean; carryOut: Boolean);
{ MVN Rd, Op2 — Rd := NOT Op2. }
var v: TWord;
begin
  v := not op2Val;
  FState.R[rd] := v;
  if sBit and (rd <> R_PC) then
  begin
    UpdateNZ(v);
    if carryOut then FState.CPSR := FState.CPSR or CPSR_C
                else FState.CPSR := FState.CPSR and not CPSR_C;
  end;
end;

procedure TArmCore.DoAND(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean; carryOut: Boolean);
var v: TWord;
begin
  v := rnVal and op2Val;
  FState.R[rd] := v;
  if sBit and (rd <> R_PC) then
  begin
    UpdateNZ(v);
    if carryOut then FState.CPSR := FState.CPSR or CPSR_C
                else FState.CPSR := FState.CPSR and not CPSR_C;
  end;
end;

procedure TArmCore.DoEOR(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean; carryOut: Boolean);
var v: TWord;
begin
  v := rnVal xor op2Val;
  FState.R[rd] := v;
  if sBit and (rd <> R_PC) then
  begin
    UpdateNZ(v);
    if carryOut then FState.CPSR := FState.CPSR or CPSR_C
                else FState.CPSR := FState.CPSR and not CPSR_C;
  end;
end;

procedure TArmCore.DoORR(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean; carryOut: Boolean);
var v: TWord;
begin
  v := rnVal or op2Val;
  FState.R[rd] := v;
  if sBit and (rd <> R_PC) then
  begin
    UpdateNZ(v);
    if carryOut then FState.CPSR := FState.CPSR or CPSR_C
                else FState.CPSR := FState.CPSR and not CPSR_C;
  end;
end;

procedure TArmCore.DoBIC(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean; carryOut: Boolean);
{ BIC Rd, Rn, Op2 — Rd := Rn AND NOT Op2. }
var v: TWord;
begin
  v := rnVal and (not op2Val);
  FState.R[rd] := v;
  if sBit and (rd <> R_PC) then
  begin
    UpdateNZ(v);
    if carryOut then FState.CPSR := FState.CPSR or CPSR_C
                else FState.CPSR := FState.CPSR and not CPSR_C;
  end;
end;

procedure TArmCore.DoADD(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
{ Rd := Rn + Op2. Carry is unsigned-overflow; V is signed-overflow. }
var
  v: UInt64;
  result, carry, overflow: TWord;
begin
  v := UInt64(rnVal) + UInt64(op2Val);
  result := TWord(v and $FFFFFFFF);
  if v > $FFFFFFFF then carry := 1 else carry := 0;
  { Signed overflow: signs of operands match AND sign of result differs. }
  if ((rnVal xor op2Val) and $80000000) = 0 then
  begin
    if ((rnVal xor result) and $80000000) <> 0 then overflow := 1 else overflow := 0;
  end
  else overflow := 0;
  FState.R[rd] := result;
  if sBit and (rd <> R_PC) then UpdateNZCV(result, carry, overflow);
end;

procedure TArmCore.DoSUB(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
{ Rd := Rn - Op2. ARM SUB sets C = NOT borrow (so C=1 when Rn >= Op2). }
var
  result, carry, overflow: TWord;
begin
  result := rnVal - op2Val;
  if rnVal >= op2Val then carry := 1 else carry := 0;
  { Signed overflow on subtraction: operand signs differ AND result sign differs from Rn. }
  if ((rnVal xor op2Val) and $80000000) <> 0 then
  begin
    if ((rnVal xor result) and $80000000) <> 0 then overflow := 1 else overflow := 0;
  end
  else overflow := 0;
  FState.R[rd] := result;
  if sBit and (rd <> R_PC) then UpdateNZCV(result, carry, overflow);
end;

procedure TArmCore.DoRSB(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
{ Reverse subtract: Rd := Op2 - Rn. Same flag logic as SUB with args swapped. }
begin
  DoSUB(rd, op2Val, rnVal, sBit);
end;

procedure TArmCore.DoADC(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
{ Add with carry. Includes the current C flag in the addition. }
var
  cIn: TWord;
  v: UInt64;
  result, carry, overflow: TWord;
begin
  if (FState.CPSR and CPSR_C) <> 0 then cIn := 1 else cIn := 0;
  v := UInt64(rnVal) + UInt64(op2Val) + UInt64(cIn);
  result := TWord(v and $FFFFFFFF);
  if v > $FFFFFFFF then carry := 1 else carry := 0;
  if ((rnVal xor op2Val) and $80000000) = 0 then
  begin
    if ((rnVal xor result) and $80000000) <> 0 then overflow := 1 else overflow := 0;
  end
  else overflow := 0;
  FState.R[rd] := result;
  if sBit and (rd <> R_PC) then UpdateNZCV(result, carry, overflow);
end;

procedure TArmCore.DoSBC(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
{ Subtract with carry: Rd := Rn - Op2 - NOT(C). Carry=1 means no borrow. }
var
  cIn: TWord;
  result, carry, overflow: TWord;
begin
  if (FState.CPSR and CPSR_C) <> 0 then cIn := 0 else cIn := 1;
  result := rnVal - op2Val - cIn;
  if (UInt64(rnVal) >= UInt64(op2Val) + UInt64(cIn)) then carry := 1 else carry := 0;
  if ((rnVal xor op2Val) and $80000000) <> 0 then
  begin
    if ((rnVal xor result) and $80000000) <> 0 then overflow := 1 else overflow := 0;
  end
  else overflow := 0;
  FState.R[rd] := result;
  if sBit and (rd <> R_PC) then UpdateNZCV(result, carry, overflow);
end;

procedure TArmCore.DoRSC(rd: Integer; rnVal, op2Val: TWord; sBit: Boolean);
{ Reverse SBC: Rd := Op2 - Rn - NOT(C). }
begin
  DoSBC(rd, op2Val, rnVal, sBit);
end;

procedure TArmCore.DoTST(rnVal, op2Val: TWord; carryOut: Boolean);
{ TST = AND that only sets flags, doesn't write Rd. }
begin
  UpdateNZ(rnVal and op2Val);
  if carryOut then FState.CPSR := FState.CPSR or CPSR_C
              else FState.CPSR := FState.CPSR and not CPSR_C;
end;

procedure TArmCore.DoTEQ(rnVal, op2Val: TWord; carryOut: Boolean);
{ TEQ = EOR that only sets flags. }
begin
  UpdateNZ(rnVal xor op2Val);
  if carryOut then FState.CPSR := FState.CPSR or CPSR_C
              else FState.CPSR := FState.CPSR and not CPSR_C;
end;

procedure TArmCore.DoCMP(rnVal, op2Val: TWord);
{ CMP = SUB that only sets flags. }
var
  result, carry, overflow: TWord;
begin
  result := rnVal - op2Val;
  if rnVal >= op2Val then carry := 1 else carry := 0;
  if ((rnVal xor op2Val) and $80000000) <> 0 then
  begin
    if ((rnVal xor result) and $80000000) <> 0 then overflow := 1 else overflow := 0;
  end
  else overflow := 0;
  UpdateNZCV(result, carry, overflow);
end;

procedure TArmCore.DoCMN(rnVal, op2Val: TWord);
{ CMN = ADD that only sets flags. }
var
  v: UInt64;
  result, carry, overflow: TWord;
begin
  v := UInt64(rnVal) + UInt64(op2Val);
  result := TWord(v and $FFFFFFFF);
  if v > $FFFFFFFF then carry := 1 else carry := 0;
  if ((rnVal xor op2Val) and $80000000) = 0 then
  begin
    if ((rnVal xor result) and $80000000) <> 0 then overflow := 1 else overflow := 0;
  end
  else overflow := 0;
  UpdateNZCV(result, carry, overflow);
end;

{ ───── Data Processing dispatch ──────────────────────────────────── }

procedure TArmCore.ExecDataProcessing(instr: TWord);
{ ARM DP instruction encoding (bits 27:26 = 00):
    cond(31:28) 00 I(25) opcode(24:21) S(20) Rn(19:16) Rd(15:12) Op2(11:0)
  I=1 → Op2 is rotated immediate (this phase)
  I=0 → Op2 is shifted register (NOT yet implemented — falls through to "unimpl")

  Opcode field (4 bits):
    0=AND 1=EOR 2=SUB 3=RSB 4=ADD 5=ADC 6=SBC 7=RSC
    8=TST 9=TEQ A=CMP B=CMN C=ORR D=MOV E=BIC F=MVN }
var
  iBit, sBit: Boolean;
  opcode, rn, rd: Integer;
  rnVal, op2Val: TWord;
  carryOut, regShiftForm: Boolean;
begin
  iBit   := ((instr shr 25) and 1) = 1;
  opcode := (instr shr 21) and $F;
  sBit   := ((instr shr 20) and 1) = 1;
  rn     := (instr shr 16) and $F;
  rd     := (instr shr 12) and $F;

  if iBit then
  begin
    DecodeOp2Immediate(instr, op2Val, carryOut);
    regShiftForm := False;
  end
  else
    DecodeOp2Register(instr, op2Val, carryOut, regShiftForm);

  rnVal := FState.R[rn];
  { When Rn = PC, the value read includes the pipeline offset: +8 for
    immediate-shift / immediate op2 (one pipeline stage), +12 for
    register-shift form (the extra Rs read costs another cycle). }
  if rn = R_PC then
  begin
    if regShiftForm then Inc(rnVal, 12)
                    else Inc(rnVal, 8);
  end;

  case opcode of
    $0: DoAND(rd, rnVal, op2Val, sBit, carryOut);
    $1: DoEOR(rd, rnVal, op2Val, sBit, carryOut);
    $2: DoSUB(rd, rnVal, op2Val, sBit);
    $3: DoRSB(rd, rnVal, op2Val, sBit);
    $4: DoADD(rd, rnVal, op2Val, sBit);
    $5: DoADC(rd, rnVal, op2Val, sBit);
    $6: DoSBC(rd, rnVal, op2Val, sBit);
    $7: DoRSC(rd, rnVal, op2Val, sBit);
    $8: DoTST(rnVal, op2Val, carryOut);
    $9: DoTEQ(rnVal, op2Val, carryOut);
    $A: DoCMP(rnVal, op2Val);
    $B: DoCMN(rnVal, op2Val);
    $C: DoORR(rd, rnVal, op2Val, sBit, carryOut);
    $D: DoMOV(rd, op2Val, sBit, carryOut);
    $E: DoBIC(rd, rnVal, op2Val, sBit, carryOut);
    $F: DoMVN(rd, op2Val, sBit, carryOut);
  end;

  { Writing Rd = R15 from a DP op is the canonical "MOVS PC, LR"
    function-return pattern (and similar). The destination-writing
    opcodes (everything except TST/TEQ/CMP/CMN which take no Rd) need
    to flag this as a branch so Step doesn't add 4. Also, when S=1
    AND Rd=R15, the CPSR is restored from the current SPSR — this is
    how interrupt handlers return atomically. }
  if (rd = R_PC) and (opcode in [$0..$7, $C..$F]) then
  begin
    FBranched := True;
    if sBit then WriteCPSR(GetCurrentSpsr);
  end;
end;

{ ───── Multiply dispatch ─────────────────────────────────────────── }

procedure TArmCore.ExecMultiply(instr: TWord);
{ MUL / MLA encoding (within class 000, bits 7:4 = 1001, bits 27:22 = 000000):
    cond  000000  A  S  Rd  Rn  Rs  1001  Rm
    bits  27:22  21  20 19:16 15:12 11:8 7:4 3:0

  Semantics:
    MUL Rd, Rm, Rs        Rd := (Rm * Rs)[31:0]                    (A = 0)
    MLA Rd, Rm, Rs, Rn    Rd := (Rm * Rs + Rn)[31:0]               (A = 1)

  Flags (when S = 1, per ARM ARM):
    N = Rd[31], Z = (Rd == 0)
    C, V are UNPREDICTABLE on ARMv4 — we leave them unchanged.

  Restrictions (caller's responsibility per ARM ARM):
    Rd ≠ Rm on ARM7TDMI ; using R15 anywhere is unpredictable.
    We do not enforce these. Real games don't violate them. }
var
  rd, rn, rs, rm: Integer;
  aBit, sBit: Boolean;
  product: UInt64;
  result: TWord;
begin
  rd := (instr shr 16) and $F;
  rn := (instr shr 12) and $F;
  rs := (instr shr 8) and $F;
  rm := instr and $F;
  aBit := ((instr shr 21) and 1) = 1;
  sBit := ((instr shr 20) and 1) = 1;

  product := UInt64(FState.R[rm]) * UInt64(FState.R[rs]);
  if aBit then
    product := product + UInt64(FState.R[rn]);

  result := TWord(product and $FFFFFFFF);
  FState.R[rd] := result;

  if sBit then UpdateNZ(result);
end;

procedure TArmCore.ExecMultiplyLong(instr: TWord);
{ Long multiply encoding (within class 000, bits 7:4 = 1001, bits 27:23 = 00001):
    cond  00001  U  A  S  RdHi  RdLo  Rs  1001  Rm
    bits  27:23 22 21 20 19:16 15:12 11:8 7:4 3:0

  U bit ("Un" in some refs, "S" in others — confusing name):
    U = 0  →  unsigned (UMULL / UMLAL)
    U = 1  →  signed   (SMULL / SMLAL)
  A bit:
    A = 0  →  plain multiply (UMULL / SMULL)
    A = 1  →  multiply-accumulate (UMLAL / SMLAL)

  Semantics (the 64-bit pair RdHi:RdLo is shown in brackets [..]):
    UMULL  [RdHi:RdLo] :=  zext(Rm) * zext(Rs)
    SMULL  [RdHi:RdLo] :=  sext(Rm) * sext(Rs)
    UMLAL  [RdHi:RdLo] := ([RdHi:RdLo] + zext(Rm) * zext(Rs)) mod 2^64
    SMLAL  [RdHi:RdLo] := ([RdHi:RdLo] + sext(Rm) * sext(Rs)) mod 2^64

  Flags (when S = 1):
    N = RdHi[31], Z = ([RdHi:RdLo] == 0)
    C, V are UNPREDICTABLE on ARMv4 — we leave them unchanged.

  We compute everything in 64-bit. For the signed case, Int64
  multiplication of sign-extended Int32 operands produces the correct
  signed 64-bit product; accumulation also works in Int64 because we're
  just doing modular arithmetic mod 2^64 (cast back to UInt64 to extract
  the bits). }
var
  rdhi, rdlo, rs, rm: Integer;
  signedOp, aBit, sBit: Boolean;
  uProduct: UInt64;
  sProduct: Int64;
  existing: UInt64;
  resultLo, resultHi: TWord;
begin
  rdhi := (instr shr 16) and $F;
  rdlo := (instr shr 12) and $F;
  rs   := (instr shr 8) and $F;
  rm   := instr and $F;
  signedOp := ((instr shr 22) and 1) = 1;
  aBit     := ((instr shr 21) and 1) = 1;
  sBit     := ((instr shr 20) and 1) = 1;

  if signedOp then
  begin
    sProduct := Int64(Int32(FState.R[rm])) * Int64(Int32(FState.R[rs]));
    if aBit then
    begin
      existing := (UInt64(FState.R[rdhi]) shl 32) or UInt64(FState.R[rdlo]);
      sProduct := Int64(UInt64(sProduct) + existing);
    end;
    uProduct := UInt64(sProduct);
  end
  else
  begin
    uProduct := UInt64(FState.R[rm]) * UInt64(FState.R[rs]);
    if aBit then
    begin
      existing := (UInt64(FState.R[rdhi]) shl 32) or UInt64(FState.R[rdlo]);
      uProduct := uProduct + existing;
    end;
  end;

  resultLo := TWord(uProduct and $FFFFFFFF);
  resultHi := TWord((uProduct shr 32) and $FFFFFFFF);
  FState.R[rdlo] := resultLo;
  FState.R[rdhi] := resultHi;

  if sBit then
  begin
    FState.CPSR := FState.CPSR and not (CPSR_N or CPSR_Z);
    if (resultHi and $80000000) <> 0 then FState.CPSR := FState.CPSR or CPSR_N;
    if (resultHi = 0) and (resultLo = 0) then FState.CPSR := FState.CPSR or CPSR_Z;
  end;
end;

{ ───── Single Data Transfer (LDR/STR) ───────────────────────────── }

procedure TArmCore.ExecSingleDataTransfer(instr: TWord);
{ Encoding (bits 27:26 = 01):
    cond 01 I P U B W L  Rn   Rd   offset(12)
  I bit MEANING IS REVERSED FROM DP:
    I = 0  → 12-bit immediate offset
    I = 1  → shifted-register offset (the same shift sub-encoding as DP
             register-form operand 2, but the bottom bit (instr[4]) is
             always 0 — no register-shift sub-form exists for SDT).
  P = 1 → pre-indexed (offset applied before access ; W=1 writes back)
  P = 0 → post-indexed (address = Rn ; offset applied to Rn after access ;
                         W bit means "force user mode access" instead — we
                         treat as a no-op here)
  U = 1 → add offset ; U = 0 → subtract
  B = 1 → byte transfer ; B = 0 → word transfer
  L = 1 → load ; L = 0 → store

  Misaligned word LDR: the addr's low 2 bits select a rotation that
  the returned value is rotated right by (so a misaligned-by-1 LDR
  returns the word rotated right by 8 bits). Per ARM ARM §A4.1.23. }
var
  iBit, pBit, uBit, bBit, wBit, lBit: Boolean;
  rn, rd, rm: Integer;
  rnVal, offset, address, dataIn: TWord;
  rotate: Integer;
  shiftType: Integer;
  shiftAmt: TWord;
  rmVal: TWord;
begin
  iBit := ((instr shr 25) and 1) = 1;
  pBit := ((instr shr 24) and 1) = 1;
  uBit := ((instr shr 23) and 1) = 1;
  bBit := ((instr shr 22) and 1) = 1;
  wBit := ((instr shr 21) and 1) = 1;
  lBit := ((instr shr 20) and 1) = 1;
  rn   := (instr shr 16) and $F;
  rd   := (instr shr 12) and $F;

  rnVal := FState.R[rn];
  if rn = R_PC then Inc(rnVal, 8);   { ARM pipeline offset }

  { Compute offset. }
  if not iBit then
  begin
    { 12-bit immediate. }
    offset := instr and $FFF;
  end
  else
  begin
    { Shifted register. Reuse DecodeOp2Register but only the immediate-
      shift sub-form is valid here (bit 4 must be 0). We inline the
      simple path since SDT never uses register-shift. }
    rm := instr and $F;
    rmVal := FState.R[rm];
    shiftType := (instr shr 5) and $3;
    shiftAmt := (instr shr 7) and $1F;
    case shiftType of
      $0:  { LSL }
        if shiftAmt = 0 then offset := rmVal
                        else offset := rmVal shl shiftAmt;
      $1:  { LSR — imm=0 means LSR #32 = 0 }
        if shiftAmt = 0 then offset := 0
                        else offset := rmVal shr shiftAmt;
      $2:  { ASR }
        if shiftAmt = 0 then
        begin
          if (rmVal and $80000000) <> 0 then offset := $FFFFFFFF
                                        else offset := 0;
        end
        else if (rmVal and $80000000) <> 0 then
          offset := (rmVal shr shiftAmt) or (TWord($FFFFFFFF) shl (32 - shiftAmt))
        else
          offset := rmVal shr shiftAmt;
      $3:  { ROR — imm=0 means RRX }
        if shiftAmt = 0 then
        begin
          if (FState.CPSR and CPSR_C) <> 0 then offset := $80000000 or (rmVal shr 1)
                                          else offset := rmVal shr 1;
        end
        else
          offset := (rmVal shr shiftAmt) or (rmVal shl (32 - shiftAmt));
    else
      offset := 0;
    end;
  end;

  { Compute access address per P/U. }
  if pBit then
  begin
    if uBit then address := rnVal + offset
            else address := rnVal - offset;
  end
  else
    address := rnVal;

  { Perform the transfer. }
  if lBit then
  begin
    if bBit then
      FState.R[rd] := TWord(FReadByte(address))
    else
    begin
      dataIn := FReadWord(address);
      { Misaligned word load: rotate right by (address[1:0] * 8) bits. }
      rotate := (address and $3) * 8;
      if rotate <> 0 then
        dataIn := (dataIn shr rotate) or (dataIn shl (32 - rotate));
      FState.R[rd] := dataIn;
    end;
    if rd = R_PC then FBranched := True;
  end
  else
  begin
    if bBit then
      FWriteByte(address, TByte(FState.R[rd] and $FF))
    else
    begin
      { Stored PC value is (PC of STR) + 12 on ARM7TDMI (one extra prefetch
        cycle compared to other reads). }
      if rd = R_PC then FWriteWord(address, FState.R[rd] + 12)
                   else FWriteWord(address, FState.R[rd]);
    end;
  end;

  { Update Rn per indexing mode. Pre-indexed with W=1, OR post-indexed
    (post-indexing ALWAYS writes back; W bit means something else there). }
  if (not pBit) or wBit then
  begin
    if pBit then
      FState.R[rn] := address                     { pre-indexed: writeback the computed address }
    else
    begin
      if uBit then FState.R[rn] := rnVal + offset { post-indexed: apply offset to original Rn }
              else FState.R[rn] := rnVal - offset;
    end;
    { Writeback to base = PC counts as a branch. }
    if rn = R_PC then FBranched := True;
  end;
end;

{ ───── Halfword / Signed Data Transfer (LDRH/STRH/LDRSB/LDRSH) ─── }

procedure TArmCore.ExecHalfwordTransfer(instr: TWord);
{ Encoding (class 0, bits 7:4 = 1ss1, ss = SH select):
    cond 000 P U I W L  Rn   Rd   offHi 1 SH 1 offLo
    SH = 01 → unsigned halfword       (LDRH / STRH)
    SH = 10 → signed byte             (LDRSB — load only)
    SH = 11 → signed halfword         (LDRSH — load only)
  I = 1 → immediate offset = (offHi << 4) | offLo
  I = 0 → register offset = Rm = offLo (offHi must be zero)
  P/U/W/L same as SDT. }
var
  pBit, uBit, iBit, wBit, lBit: Boolean;
  sh, rn, rd, rm: Integer;
  rnVal, offset, address: TWord;
  loadedHalf: THalf;
  loadedByte: TByte;
  signedHalfRes, signedByteRes: Int32;
begin
  pBit := ((instr shr 24) and 1) = 1;
  uBit := ((instr shr 23) and 1) = 1;
  iBit := ((instr shr 22) and 1) = 1;
  wBit := ((instr shr 21) and 1) = 1;
  lBit := ((instr shr 20) and 1) = 1;
  rn   := (instr shr 16) and $F;
  rd   := (instr shr 12) and $F;
  sh   := (instr shr 5) and $3;

  rnVal := FState.R[rn];
  if rn = R_PC then Inc(rnVal, 8);

  if iBit then
    offset := ((instr shr 4) and $F0) or (instr and $F)
  else
  begin
    rm := instr and $F;
    offset := FState.R[rm];
  end;

  if pBit then
  begin
    if uBit then address := rnVal + offset
            else address := rnVal - offset;
  end
  else
    address := rnVal;

  if lBit then
  begin
    case sh of
      $1:  { LDRH — unsigned halfword }
        FState.R[rd] := TWord(FReadHalf(address));
      $2:  { LDRSB — signed byte → sign-extend to 32 bits }
        begin
          loadedByte := FReadByte(address);
          signedByteRes := Int32(Int8(loadedByte));
          FState.R[rd] := TWord(signedByteRes);
        end;
      $3:  { LDRSH — signed halfword → sign-extend }
        begin
          loadedHalf := FReadHalf(address);
          signedHalfRes := Int32(Int16(loadedHalf));
          FState.R[rd] := TWord(signedHalfRes);
        end;
    else
      Writeln(StdErr, Format('ArmCore: bad SH field %d in halfword transfer', [sh]));
    end;
    if rd = R_PC then FBranched := True;
  end
  else
  begin
    { Store. Only SH=01 (STRH) is defined. }
    if sh = $1 then
      FWriteHalf(address, THalf(FState.R[rd] and $FFFF))
    else
      Writeln(StdErr, Format('ArmCore: invalid store with SH=%d', [sh]));
  end;

  if (not pBit) or wBit then
  begin
    if pBit then
      FState.R[rn] := address
    else if uBit then
      FState.R[rn] := rnVal + offset
    else
      FState.R[rn] := rnVal - offset;
    if rn = R_PC then FBranched := True;
  end;
end;

{ ───── Block Data Transfer (LDM/STM) ────────────────────────────── }

procedure TArmCore.ExecBlockDataTransfer(instr: TWord);
{ Encoding (bits 27:25 = 100):
    cond 100 P U S W L  Rn   register_list(16)
  Addressing mode is the (P,U) combination:
    IA (P=0,U=1)  ↑  address = Rn, then Rn += 4 per register
    IB (P=1,U=1)  ↑  Rn += 4 first, then access (pre-increment)
    DA (P=0,U=0)  ↓  address = Rn, then Rn -= 4 per register
    DB (P=1,U=0)  ↓  Rn -= 4 first, then access (pre-decrement)

  Registers ALWAYS transferred in ascending number order regardless of
  direction — the addressing mode just controls where the base ends up
  pointing and whether the first access happens at Rn or at an offset.

  Implementation strategy: enumerate the register bits low-to-high to
  get the count, compute the LOWEST address in the access range, then
  walk registers ascending and accesses ascending from that base.

    address_low = Rn + (U ? P*4 : -(count*4 - !P*4))
    after the transfer, Rn (if W=1) becomes:
      U=1: Rn + count*4
      U=0: Rn - count*4

  PC in register list:
    LDM with PC: the loaded value is the new PC; if S=1 also CPSR := SPSR
    STM with PC: stores (PC of STM + 12) — same +12 quirk as SDT store.

  S bit: when S=1 and PC NOT in list: registers transfer to/from user-
  mode bank (used for context switches). We don't yet implement this;
  treating as S=0 is acceptable since no normal code uses it. }
var
  pBit, uBit, sBit, wBit, lBit: Boolean;
  rn: Integer;
  regList: TWord;
  rnVal, count, baseAddr, addr: TWord;
  i: Integer;
  pcInList: Boolean;
  storedVal: TWord;
begin
  pBit := ((instr shr 24) and 1) = 1;
  uBit := ((instr shr 23) and 1) = 1;
  sBit := ((instr shr 22) and 1) = 1;
  wBit := ((instr shr 21) and 1) = 1;
  lBit := ((instr shr 20) and 1) = 1;
  rn   := (instr shr 16) and $F;
  regList := instr and $FFFF;

  rnVal := FState.R[rn];

  { Count registers in list. }
  count := 0;
  for i := 0 to 15 do
    if ((regList shr i) and 1) = 1 then Inc(count);

  if count = 0 then Exit;   { empty list: per ARM ARM unpredictable; do nothing }

  pcInList := (regList and $8000) <> 0;

  { Determine the lowest address in the transfer range. The four modes
    yield these patterns (drawn with count=3 to make it concrete):
      IA: rn, rn+4, rn+8   → low = rn,     end = rn+12 (writeback)
      IB: rn+4, rn+8, rn+12 → low = rn+4,  end = rn+12
      DA: rn-8, rn-4, rn   → low = rn-8,  end = rn-12
      DB: rn-12, rn-8, rn-4 → low = rn-12, end = rn-12
    Registers always visit low → high addresses in number order. }
  if uBit then
  begin
    if pBit then baseAddr := rnVal + 4
            else baseAddr := rnVal;
  end
  else
  begin
    if pBit then baseAddr := rnVal - count * 4
            else baseAddr := rnVal - count * 4 + 4;
  end;

  addr := baseAddr;
  for i := 0 to 15 do
    if ((regList shr i) and 1) = 1 then
    begin
      if lBit then
      begin
        FState.R[i] := FReadWord(addr);
        if (i = R_PC) then
        begin
          { LDM with PC: branch. If S=1, also restore CPSR from SPSR
            (atomic return-from-exception). }
          FBranched := True;
          if sBit then WriteCPSR(GetCurrentSpsr);
        end;
      end
      else
      begin
        if i = R_PC then storedVal := FState.R[i] + 12
                    else storedVal := FState.R[i];
        FWriteWord(addr, storedVal);
      end;
      Inc(addr, 4);
    end;

  if wBit then
  begin
    if uBit then FState.R[rn] := rnVal + count * 4
            else FState.R[rn] := rnVal - count * 4;
  end;

  if not lBit then
    { No further work for STM. }
  else if pcInList then
    { PC was loaded — FBranched already set. }
    ;
end;

{ ───── PSR transfer (MRS/MSR) ───────────────────────────────────── }

function TArmCore.GetCurrentSpsr: TWord;
begin
  case FState.CPSR and CPSR_MODE_MASK of
    Ord(amFIQ): Result := FState.SPSR_fiq;
    Ord(amIRQ): Result := FState.SPSR_irq;
    Ord(amSVC): Result := FState.SPSR_svc;
    Ord(amABT): Result := FState.SPSR_abt;
    Ord(amUND): Result := FState.SPSR_und;
  else
    { User/System modes have no SPSR. Per ARM ARM this is UNPREDICTABLE;
      most cores return CPSR. }
    Result := FState.CPSR;
  end;
end;

procedure TArmCore.SetCurrentSpsr(v: TWord);
begin
  case FState.CPSR and CPSR_MODE_MASK of
    Ord(amFIQ): FState.SPSR_fiq := v;
    Ord(amIRQ): FState.SPSR_irq := v;
    Ord(amSVC): FState.SPSR_svc := v;
    Ord(amABT): FState.SPSR_abt := v;
    Ord(amUND): FState.SPSR_und := v;
  else
    { User/System — no SPSR to update; silently ignore. }
  end;
end;

procedure TArmCore.SwapBanksForMode(oldMode, newMode: TWord);
{ Per ARM7TDMI TRM banking rules:
    User/System    R0..R15 (no banking)         no SPSR
    FIQ            banks R8..R14                + SPSR_fiq
    IRQ            banks R13..R14               + SPSR_irq
    SVC            banks R13..R14               + SPSR_svc
    ABT            banks R13..R14               + SPSR_abt
    UND            banks R13..R14               + SPSR_und

  R8..R12 only swap when FIQ is on one side of the transition (everyone
  else shares the user/sys R8..R12 values). R13..R14 swap whenever the
  mode boundary changes between two banked sets. User and System share
  the same R13/R14 slot (R_usr_sp / R_usr_lr). }
var
  oldFiq, newFiq: Boolean;
  i: Integer;
begin
  if oldMode = newMode then Exit;

  oldFiq := (oldMode = Ord(amFIQ));
  newFiq := (newMode = Ord(amFIQ));

  { R8..R12 swap only across the FIQ boundary. }
  if oldFiq <> newFiq then
  begin
    if oldFiq then
    begin
      { Leaving FIQ: save R8..R12 to FIQ bank, load from user-shared. }
      for i := 8 to 12 do FState.R_fiq[i] := FState.R[i];
      for i := 8 to 12 do FState.R[i]     := FState.R_usr[i];
    end
    else
    begin
      { Entering FIQ: save R8..R12 to user-shared bank, load from FIQ. }
      for i := 8 to 12 do FState.R_usr[i] := FState.R[i];
      for i := 8 to 12 do FState.R[i]     := FState.R_fiq[i];
    end;
  end;

  { Save R13/R14 to old mode's bank. User and System map to R_usr_*. }
  case oldMode of
    Ord(amUser), Ord(amSYS):
      begin FState.R_usr_sp := FState.R[13]; FState.R_usr_lr := FState.R[14]; end;
    Ord(amFIQ):
      begin FState.R_fiq[13] := FState.R[13]; FState.R_fiq[14] := FState.R[14]; end;
    Ord(amIRQ):
      begin FState.R_irq_sp := FState.R[13]; FState.R_irq_lr := FState.R[14]; end;
    Ord(amSVC):
      begin FState.R_svc_sp := FState.R[13]; FState.R_svc_lr := FState.R[14]; end;
    Ord(amABT):
      begin FState.R_abt_sp := FState.R[13]; FState.R_abt_lr := FState.R[14]; end;
    Ord(amUND):
      begin FState.R_und_sp := FState.R[13]; FState.R_und_lr := FState.R[14]; end;
  end;

  { Load R13/R14 from new mode's bank. }
  case newMode of
    Ord(amUser), Ord(amSYS):
      begin FState.R[13] := FState.R_usr_sp; FState.R[14] := FState.R_usr_lr; end;
    Ord(amFIQ):
      begin FState.R[13] := FState.R_fiq[13]; FState.R[14] := FState.R_fiq[14]; end;
    Ord(amIRQ):
      begin FState.R[13] := FState.R_irq_sp; FState.R[14] := FState.R_irq_lr; end;
    Ord(amSVC):
      begin FState.R[13] := FState.R_svc_sp; FState.R[14] := FState.R_svc_lr; end;
    Ord(amABT):
      begin FState.R[13] := FState.R_abt_sp; FState.R[14] := FState.R_abt_lr; end;
    Ord(amUND):
      begin FState.R[13] := FState.R_und_sp; FState.R[14] := FState.R_und_lr; end;
  end;
end;

procedure TArmCore.WriteCPSR(newValue: TWord);
var
  oldMode, newMode: TWord;
begin
  oldMode := FState.CPSR and CPSR_MODE_MASK;
  newMode := newValue and CPSR_MODE_MASK;
  if oldMode <> newMode then SwapBanksForMode(oldMode, newMode);
  FState.CPSR := newValue;
end;

procedure TArmCore.ExecPsrTransfer(instr: TWord);
{ MRS / MSR encoding sits in the "DP with opcode TST/TEQ/CMP/CMN and S=0"
  encoding hole (bits 24:23 = 10, bit 20 = 0).

  Bit 21 (within the DP opcode bit slot) selects:
    bit 21 = 0  → MRS Rd, <PSR>      Rd := PSR
    bit 21 = 1  → MSR <PSR>, src     PSR (selected fields) := src

  Bit 22 selects which PSR:
    bit 22 = 0  → CPSR
    bit 22 = 1  → SPSR of current mode

  For MSR, bit 25 (I bit) distinguishes immediate (1) vs register (0)
  source — same convention as DP.

  Field mask is bits 19:16 (the same slot DP uses for Rn — repurposed
  here). Each bit gates one byte of the PSR:
    bit 16 = control byte  (PSR[7:0]   — IRQ/FIQ disable, Thumb, mode)
    bit 17 = extension     (PSR[15:8]  — reserved on ARMv4)
    bit 18 = status        (PSR[23:16] — reserved on ARMv4)
    bit 19 = flags byte    (PSR[31:24] — N/Z/C/V/Q)

  Mode-bit writes via the control byte do NOT yet perform the banked-
  register swap here. That seam lives in the next Phase A subtask
  (mode-switching). For now we write the bits straight through;
  banked-register correctness arrives when that subtask lands. }
var
  isMsr, useSpsr, iBit: Boolean;
  rd, rm: Integer;
  fieldsMask: Integer;
  srcVal: TWord;
  carryOutUnused: Boolean;
  mask: TWord;
begin
  isMsr   := ((instr shr 21) and 1) = 1;
  useSpsr := ((instr shr 22) and 1) = 1;

  if not isMsr then
  begin
    { MRS Rd, <PSR>. }
    rd := (instr shr 12) and $F;
    if useSpsr then
      FState.R[rd] := GetCurrentSpsr
    else
      FState.R[rd] := FState.CPSR;
    Exit;
  end;

  { MSR <PSR>, src. }
  iBit := ((instr shr 25) and 1) = 1;
  fieldsMask := (instr shr 16) and $F;

  if iBit then
    DecodeOp2Immediate(instr, srcVal, carryOutUnused)
  else
  begin
    rm := instr and $F;
    srcVal := FState.R[rm];
  end;

  mask := 0;
  if (fieldsMask and $1) <> 0 then mask := mask or $000000FF;   { control }
  if (fieldsMask and $2) <> 0 then mask := mask or $0000FF00;   { extension }
  if (fieldsMask and $4) <> 0 then mask := mask or $00FF0000;   { status }
  if (fieldsMask and $8) <> 0 then mask := mask or $FF000000;   { flags }

  if useSpsr then
    SetCurrentSpsr((GetCurrentSpsr and not mask) or (srcVal and mask))
  else
    WriteCPSR((FState.CPSR and not mask) or (srcVal and mask));
end;

{ ───── Branch and Exchange (ARM ↔ THUMB) ────────────────────────── }

procedure TArmCore.ExecBranchExchange(instr: TWord);
{ BX Rn encoding: cond 0001 0010 1111 1111 1111 0001 Rn
    bits 27:4 = 000100101111111111110001
    bits 3:0  = Rn

  Behavior:
    target_lo_bit = Rn[0]
    if target_lo_bit = 1:  CPSR.T := 1 ; PC := Rn AND not 1   (THUMB)
    if target_lo_bit = 0:  CPSR.T := 0 ; PC := Rn AND not 3   (ARM)

  This is how every ARM↔THUMB transition happens. BIOS uses BX to enter
  THUMB code; a THUMB function returns to its ARM caller via BX LR. }
var
  rn: Integer;
  rnVal: TWord;
begin
  rn := instr and $F;
  rnVal := FState.R[rn];

  if (rnVal and 1) <> 0 then
  begin
    FState.CPSR := FState.CPSR or CPSR_T;
    FState.R[R_PC] := rnVal and not TWord($1);
  end
  else
  begin
    FState.CPSR := FState.CPSR and not CPSR_T;
    FState.R[R_PC] := rnVal and not TWord($3);
  end;
  FBranched := True;
end;

{ ───── Software Interrupt ────────────────────────────────────────── }

procedure TArmCore.ExecSWI(instr: TWord);
{ Per ARM ARM §A2.6.7, hardware actions on SWI:
    1. SPSR_svc ← CPSR
    2. LR_svc   ← address of next instruction
    3. CPSR     ← (mode=SVC, T=0, I=1; F unchanged; flags unchanged)
    4. PC       ← $00000008

  BIOS HLE: if a SWI hook is installed and handles the SWI number, we
  skip the normal exception entry and just advance PC past the SWI.
  The SWI number for ARM SWI is in instr[23:16] by GBA convention. }
var
  oldCPSR, returnAddr, newCPSR: TWord;
  swiNum: TByte;
begin
  swiNum := (instr shr 16) and $FF;
  Inc(SwiExecCount[swiNum]);

  if Assigned(FSwiHook) and FSwiHook(swiNum) then
  begin
    { Handled in Pascal. PC stays at current SWI instruction; the post-
      step tail will advance by 4 sequentially. Don't set FBranched. }
    Exit;
  end;

  oldCPSR := FState.CPSR;
  returnAddr := FState.R[R_PC] + 4;

  newCPSR := (FState.CPSR and not (CPSR_MODE_MASK or CPSR_T)) or Ord(amSVC) or CPSR_I;
  WriteCPSR(newCPSR);

  FState.R[R_LR] := returnAddr;
  SetCurrentSpsr(oldCPSR);

  FState.R[R_PC] := $00000008;
  FBranched := True;
end;

{ ───── Branch dispatch ────────────────────────────────────────────── }

procedure TArmCore.ExecBranch(instr: TWord);
{ B / BL encoding (bits 27:25 = 101):
    cond(31:28) 101 L(24) offset(23:0)
  offset is a signed 24-bit value shifted left 2 (so it addresses
  4-byte-aligned targets). Effective target = PC + 8 + (sign_extend(offset) << 2).

  L=1 → BL: link register = PC + 4 (address of next instruction). }
var
  offset: Int32;
  lBit: Boolean;
  target: TWord;
begin
  lBit := ((instr shr 24) and 1) = 1;

  { Sign-extend the 24-bit offset to 32 bits, then shift left 2. }
  offset := instr and $FFFFFF;
  if (offset and $800000) <> 0 then
    offset := offset or Int32($FF000000);
  offset := offset shl 2;

  if lBit then
    FState.R[R_LR] := FState.R[R_PC] + 4;

  target := TWord(Int64(FState.R[R_PC]) + 8 + Int64(offset));
  FState.R[R_PC] := target;
  FBranched := True;
end;

{ ───── THUMB instruction set ─────────────────────────────────────── }

{ THUMB is the GBA's 16-bit instruction set. Most opcodes are
  sub-encodings of ARM instructions, so we route through the existing
  ALU helpers (DoADD, DoSUB, DoMOV, etc.) where possible. The handlers
  below cover the 11 of 19 THUMB formats that don't touch memory; the
  remaining 8 (load/store/push/pop/LDM/STM) defer to Phase B when the
  Memory unit lands. Pipeline note: when a THUMB instruction reads PC,
  the visible value is (current_PC + 4) — two halfwords ahead. }

procedure TArmCore.ExecThumbFmt1ShiftedReg(instr: THalf);
{ Format 1: LSL/LSR/ASR Rd, Rs, #imm5.
    bits 12:11 = opcode (00=LSL, 01=LSR, 10=ASR ; 11 would be format 2)
    bits 10:6  = imm5 shift amount (0..31)
    bits 5:3   = Rs (source)
    bits 2:0   = Rd (destination)
  Always sets N/Z/C. C comes from the last bit shifted out, with the
  same #0 special cases as ARM immediate-shift (LSL #0 = no shift /
  carry unchanged ; LSR #0 = LSR #32 ; ASR #0 = ASR #32). }
var
  opcode, imm5, rs, rd: Integer;
  rsVal, result: TWord;
  carryOut: Boolean;
begin
  opcode := (instr shr 11) and $3;
  imm5   := (instr shr 6) and $1F;
  rs     := (instr shr 3) and $7;
  rd     := instr and $7;
  rsVal  := FState.R[rs];

  case opcode of
    $0:  { LSL }
      if imm5 = 0 then
      begin
        result := rsVal;
        carryOut := (FState.CPSR and CPSR_C) <> 0;
      end
      else
      begin
        result := rsVal shl imm5;
        carryOut := ((rsVal shr (32 - imm5)) and 1) <> 0;
      end;
    $1:  { LSR — imm5=0 encodes LSR #32 }
      if imm5 = 0 then
      begin
        result := 0;
        carryOut := (rsVal and $80000000) <> 0;
      end
      else
      begin
        result := rsVal shr imm5;
        carryOut := ((rsVal shr (imm5 - 1)) and 1) <> 0;
      end;
    $2:  { ASR — imm5=0 encodes ASR #32 }
      if imm5 = 0 then
      begin
        if (rsVal and $80000000) <> 0 then result := $FFFFFFFF
                                      else result := 0;
        carryOut := (rsVal and $80000000) <> 0;
      end
      else
      begin
        if (rsVal and $80000000) <> 0 then
          result := (rsVal shr imm5) or (TWord($FFFFFFFF) shl (32 - imm5))
        else
          result := rsVal shr imm5;
        carryOut := ((rsVal shr (imm5 - 1)) and 1) <> 0;
      end;
  else
    result := 0; carryOut := False;   { unreachable — caller checked }
  end;

  FState.R[rd] := result;
  UpdateNZ(result);
  if carryOut then FState.CPSR := FState.CPSR or CPSR_C
              else FState.CPSR := FState.CPSR and not CPSR_C;
end;

procedure TArmCore.ExecThumbFmt2AddSub(instr: THalf);
{ Format 2: ADD/SUB Rd, Rs, [Rn|#imm3].
    bits 10:9 = op (00=ADD reg, 01=SUB reg, 10=ADD imm3, 11=SUB imm3)
    bits 8:6  = Rn (register form) or imm3 (immediate form)
    bits 5:3  = Rs
    bits 2:0  = Rd
  Always sets N/Z/C/V. }
var
  op, rnOrImm, rs, rd: Integer;
  rsVal, operand: TWord;
begin
  op       := (instr shr 9) and $3;
  rnOrImm  := (instr shr 6) and $7;
  rs       := (instr shr 3) and $7;
  rd       := instr and $7;
  rsVal    := FState.R[rs];

  case op of
    $0: begin operand := FState.R[rnOrImm]; DoADD(rd, rsVal, operand, True); end;
    $1: begin operand := FState.R[rnOrImm]; DoSUB(rd, rsVal, operand, True); end;
    $2: DoADD(rd, rsVal, TWord(rnOrImm), True);
    $3: DoSUB(rd, rsVal, TWord(rnOrImm), True);
  end;
end;

procedure TArmCore.ExecThumbFmt3MovCmpAddSubImm(instr: THalf);
{ Format 3: MOV/CMP/ADD/SUB Rd, #imm8.
    bits 12:11 = op (00=MOV, 01=CMP, 10=ADD, 11=SUB)
    bits 10:8  = Rd
    bits 7:0   = imm8
  Always sets flags. ADD/SUB target = source (Rd := Rd op #imm8). }
var
  op, rd: Integer;
  imm8: TWord;
  rdVal: TWord;
begin
  op   := (instr shr 11) and $3;
  rd   := (instr shr 8) and $7;
  imm8 := instr and $FF;
  rdVal := FState.R[rd];

  case op of
    $0: DoMOV(rd, imm8, True, (FState.CPSR and CPSR_C) <> 0);
    $1: DoCMP(rdVal, imm8);
    $2: DoADD(rd, rdVal, imm8, True);
    $3: DoSUB(rd, rdVal, imm8, True);
  end;
end;

procedure TArmCore.ExecThumbFmt4Alu(instr: THalf);
{ Format 4: 16 ALU ops. Rd := Rd op Rs (or related).
    bits 9:6 = opcode
    bits 5:3 = Rs
    bits 2:0 = Rd
  All ops set N/Z (some also set C/V). Per ARM ARM Table A6-4:
    0=AND   1=EOR   2=LSL   3=LSR
    4=ASR   5=ADC   6=SBC   7=ROR
    8=TST   9=NEG   A=CMP   B=CMN
    C=ORR   D=MUL   E=BIC   F=MVN
  LSL/LSR/ASR/ROR here are REGISTER-shift forms (shift Rd by Rs[7:0]). }
var
  opcode, rs, rd: Integer;
  rdVal, rsVal, result: TWord;
  shiftAmt: TWord;
  carryOut: Boolean;
  product: UInt64;
begin
  opcode := (instr shr 6) and $F;
  rs     := (instr shr 3) and $7;
  rd     := instr and $7;
  rdVal  := FState.R[rd];
  rsVal  := FState.R[rs];

  case opcode of
    $0: DoAND(rd, rdVal, rsVal, True, (FState.CPSR and CPSR_C) <> 0);
    $1: DoEOR(rd, rdVal, rsVal, True, (FState.CPSR and CPSR_C) <> 0);
    $2..$4, $7:   { LSL/LSR/ASR/ROR — register-shift in place }
      begin
        shiftAmt := rsVal and $FF;
        if shiftAmt = 0 then
        begin
          { No flag change. }
          UpdateNZ(rdVal);
          Exit;
        end;
        carryOut := False;
        result := 0;
        case opcode of
          $2:  { LSL }
            if shiftAmt < 32 then
            begin
              result := rdVal shl shiftAmt;
              carryOut := ((rdVal shr (32 - shiftAmt)) and 1) <> 0;
            end
            else if shiftAmt = 32 then
            begin
              result := 0;
              carryOut := (rdVal and 1) <> 0;
            end
            else
            begin
              result := 0; carryOut := False;
            end;
          $3:  { LSR }
            if shiftAmt < 32 then
            begin
              result := rdVal shr shiftAmt;
              carryOut := ((rdVal shr (shiftAmt - 1)) and 1) <> 0;
            end
            else if shiftAmt = 32 then
            begin
              result := 0; carryOut := (rdVal and $80000000) <> 0;
            end
            else
            begin
              result := 0; carryOut := False;
            end;
          $4:  { ASR }
            if shiftAmt < 32 then
            begin
              if (rdVal and $80000000) <> 0 then
                result := (rdVal shr shiftAmt) or (TWord($FFFFFFFF) shl (32 - shiftAmt))
              else
                result := rdVal shr shiftAmt;
              carryOut := ((rdVal shr (shiftAmt - 1)) and 1) <> 0;
            end
            else
            begin
              if (rdVal and $80000000) <> 0 then result := $FFFFFFFF
                                            else result := 0;
              carryOut := (rdVal and $80000000) <> 0;
            end;
          $7:  { ROR }
            begin
              shiftAmt := shiftAmt and $1F;
              if shiftAmt = 0 then
              begin
                result := rdVal;
                carryOut := (rdVal and $80000000) <> 0;
              end
              else
              begin
                result := (rdVal shr shiftAmt) or (rdVal shl (32 - shiftAmt));
                carryOut := ((rdVal shr (shiftAmt - 1)) and 1) <> 0;
              end;
            end;
        end;
        FState.R[rd] := result;
        UpdateNZ(result);
        if carryOut then FState.CPSR := FState.CPSR or CPSR_C
                    else FState.CPSR := FState.CPSR and not CPSR_C;
      end;
    $5: DoADC(rd, rdVal, rsVal, True);
    $6: DoSBC(rd, rdVal, rsVal, True);
    $8: DoTST(rdVal, rsVal, (FState.CPSR and CPSR_C) <> 0);
    $9: DoRSB(rd, rsVal, 0, True);   { NEG Rd, Rs = 0 - Rs = RSB Rd, Rs, #0 }
    $A: DoCMP(rdVal, rsVal);
    $B: DoCMN(rdVal, rsVal);
    $C: DoORR(rd, rdVal, rsVal, True, (FState.CPSR and CPSR_C) <> 0);
    $D:  { MUL Rd, Rs : Rd := Rd * Rs }
      begin
        product := UInt64(rdVal) * UInt64(rsVal);
        result := TWord(product and $FFFFFFFF);
        FState.R[rd] := result;
        UpdateNZ(result);
      end;
    $E: DoBIC(rd, rdVal, rsVal, True, (FState.CPSR and CPSR_C) <> 0);
    $F: DoMVN(rd, rsVal, True, (FState.CPSR and CPSR_C) <> 0);
  end;
end;

procedure TArmCore.ExecThumbFmt5HiRegOrBX(instr: THalf);
{ Format 5: hi-register ADD/CMP/MOV and BX.
    bits 9:8 = op (00=ADD, 01=CMP, 10=MOV, 11=BX)
    bit 7    = H1 (Rd high bit — combines with bits 2:0 to give R0..R15)
    bit 6    = H2 (Rs high bit — combines with bits 5:3)
    bits 5:3 = Rs (low 3 bits; full = H2:Rs)
    bits 2:0 = Rd (low 3 bits; full = H1:Rd)
  ADD/MOV do NOT set flags ; CMP always does. BX uses H2:Rs as target
  (Rd encoding ignored). }
var
  op: Integer;
  rd, rs: Integer;
  rdVal, rsVal: TWord;
begin
  op := (instr shr 8) and $3;
  rd := ((instr shr 4) and $8) or (instr and $7);          { H1 << 3 | Rd_lo }
  rs := ((instr shr 3) and $8) or ((instr shr 3) and $7);  { H2 << 3 | Rs_lo }

  case op of
    $0:  { ADD Rd, Rs }
      begin
        rdVal := FState.R[rd];
        if rd = R_PC then Inc(rdVal, 4);   { THUMB pipeline reads PC+4 }
        rsVal := FState.R[rs];
        if rs = R_PC then Inc(rsVal, 4);
        FState.R[rd] := rdVal + rsVal;
        if rd = R_PC then
        begin
          FState.R[rd] := FState.R[rd] and not TWord(1);   { THUMB-aligned }
          FBranched := True;
        end;
      end;
    $1:  { CMP Rd, Rs — sets flags }
      begin
        rdVal := FState.R[rd];
        if rd = R_PC then Inc(rdVal, 4);
        rsVal := FState.R[rs];
        if rs = R_PC then Inc(rsVal, 4);
        DoCMP(rdVal, rsVal);
      end;
    $2:  { MOV Rd, Rs }
      begin
        rsVal := FState.R[rs];
        if rs = R_PC then Inc(rsVal, 4);
        FState.R[rd] := rsVal;
        if rd = R_PC then
        begin
          FState.R[rd] := FState.R[rd] and not TWord(1);
          FBranched := True;
        end;
      end;
    $3:  { BX Rs — Rd field ignored }
      begin
        rsVal := FState.R[rs];
        if rs = R_PC then Inc(rsVal, 4);
        if (rsVal and 1) <> 0 then
        begin
          FState.CPSR := FState.CPSR or CPSR_T;
          FState.R[R_PC] := rsVal and not TWord($1);
        end
        else
        begin
          FState.CPSR := FState.CPSR and not CPSR_T;
          FState.R[R_PC] := rsVal and not TWord($3);
        end;
        FBranched := True;
      end;
  end;
end;

procedure TArmCore.ExecThumbFmt12LoadAddr(instr: THalf);
{ Format 12: ADD Rd, [PC|SP], #imm8<<2 — compute and load an address.
    bit 11    = source (0 = PC, 1 = SP)
    bits 10:8 = Rd
    bits 7:0  = imm8 (multiplied by 4 for the actual offset)
  PC source: visible PC value is (current_PC + 4) AND ~3.
  No flag update. }
var
  fromSp: Boolean;
  rd: Integer;
  offset: TWord;
  base: TWord;
begin
  fromSp := ((instr shr 11) and 1) = 1;
  rd     := (instr shr 8) and $7;
  offset := (TWord(instr) and $FF) shl 2;

  if fromSp then
    base := FState.R[R_SP]
  else
    base := (FState.R[R_PC] + 4) and not TWord($3);

  FState.R[rd] := base + offset;
end;

procedure TArmCore.ExecThumbFmt13AddOffsetSP(instr: THalf);
{ Format 13: ADD SP, #±imm7<<2 — adjust the stack pointer in place.
    bit 7    = sign (0 = add, 1 = subtract)
    bits 6:0 = imm7 (multiplied by 4)
  No flag update. }
var
  isSub: Boolean;
  offset: TWord;
begin
  isSub  := ((instr shr 7) and 1) = 1;
  offset := (TWord(instr) and $7F) shl 2;
  if isSub then
    FState.R[R_SP] := FState.R[R_SP] - offset
  else
    FState.R[R_SP] := FState.R[R_SP] + offset;
end;

procedure TArmCore.ExecThumbFmt6PcLoad(instr: THalf);
{ Format 6: LDR Rd, [PC, #imm8<<2] — word load using PC-relative addressing.
  bits 15:11 = 01001
  bits 10:8  = Rd
  bits 7:0   = imm8 (multiplied by 4)
  address = (PC + 4) AND ~3 + (imm8 << 2)
  This is the canonical THUMB way to load a literal constant from a
  literal pool placed near the code. }
var
  rd: Integer;
  offset, address: TWord;
begin
  rd := (instr shr 8) and $7;
  offset := (TWord(instr) and $FF) shl 2;
  address := ((FState.R[R_PC] + 4) and not TWord($3)) + offset;
  FState.R[rd] := FReadWord(address);
end;

procedure TArmCore.ExecThumbFmt7RegOffset(instr: THalf);
{ Format 7: load/store with register offset (word + byte variants).
    bits 15:12 = 0101
    bit 11     = L (load=1, store=0)
    bit 10     = B (byte=1, word=0)
    bit 9      = 0 (distinguishes from format 8)
    bits 8:6   = Ro (offset register)
    bits 5:3   = Rb (base)
    bits 2:0   = Rd
  address = Rb + Ro. No writeback. }
var
  lBit, bBit: Boolean;
  ro, rb, rd: Integer;
  address: TWord;
begin
  lBit := ((instr shr 11) and 1) = 1;
  bBit := ((instr shr 10) and 1) = 1;
  ro   := (instr shr 6) and $7;
  rb   := (instr shr 3) and $7;
  rd   := instr and $7;
  address := FState.R[rb] + FState.R[ro];

  if lBit then
  begin
    if bBit then FState.R[rd] := TWord(FReadByte(address))
            else FState.R[rd] := FReadWord(address);
  end
  else
  begin
    if bBit then FWriteByte(address, TByte(FState.R[rd] and $FF))
            else FWriteWord(address, FState.R[rd]);
  end;
end;

procedure TArmCore.ExecThumbFmt8SignExt(instr: THalf);
{ Format 8: load/store sign-extended byte/halfword with register offset.
    bits 15:12 = 0101
    bit 11     = H
    bit 10     = S    (S:H selects op)
    bit 9      = 1 (distinguishes from format 7)
    bits 8:6   = Ro
    bits 5:3   = Rb
    bits 2:0   = Rd
  S:H values:
    00 = STRH      Rd[15:0] → mem[half]
    01 = LDRH      mem[half] → Rd, zero-extend
    10 = LDRSB     mem[byte] → Rd, sign-extend
    11 = LDRSH     mem[half] → Rd, sign-extend }
var
  hBit, sBit: Boolean;
  op: Integer;
  ro, rb, rd: Integer;
  address: TWord;
  halfVal: THalf;
  byteVal: TByte;
begin
  hBit := ((instr shr 11) and 1) = 1;
  sBit := ((instr shr 10) and 1) = 1;
  if sBit then op := 2 else op := 0;
  if hBit then op := op or 1;
  ro := (instr shr 6) and $7;
  rb := (instr shr 3) and $7;
  rd := instr and $7;
  address := FState.R[rb] + FState.R[ro];

  case op of
    0: FWriteHalf(address, THalf(FState.R[rd] and $FFFF));         { STRH }
    1: FState.R[rd] := TWord(FReadHalf(address));                  { LDRH }
    2: begin                                                        { LDRSB }
         byteVal := FReadByte(address);
         FState.R[rd] := TWord(Int32(Int8(byteVal)));
       end;
    3: begin                                                        { LDRSH }
         halfVal := FReadHalf(address);
         FState.R[rd] := TWord(Int32(Int16(halfVal)));
       end;
  end;
end;

procedure TArmCore.ExecThumbFmt9ImmOffset(instr: THalf);
{ Format 9: load/store with immediate offset.
    bits 15:13 = 011
    bit 12     = B (byte=1, word=0)
    bit 11     = L
    bits 10:6  = imm5 (offset; multiplied by 4 for word, by 1 for byte)
    bits 5:3   = Rb
    bits 2:0   = Rd
  address = Rb + offset. No writeback. }
var
  bBit, lBit: Boolean;
  imm5, rb, rd: Integer;
  offset, address: TWord;
begin
  bBit := ((instr shr 12) and 1) = 1;
  lBit := ((instr shr 11) and 1) = 1;
  imm5 := (instr shr 6) and $1F;
  rb   := (instr shr 3) and $7;
  rd   := instr and $7;
  if bBit then offset := TWord(imm5) else offset := TWord(imm5) shl 2;
  address := FState.R[rb] + offset;

  if lBit then
  begin
    if bBit then FState.R[rd] := TWord(FReadByte(address))
            else FState.R[rd] := FReadWord(address);
  end
  else
  begin
    if bBit then FWriteByte(address, TByte(FState.R[rd] and $FF))
            else FWriteWord(address, FState.R[rd]);
  end;
end;

procedure TArmCore.ExecThumbFmt10Halfword(instr: THalf);
{ Format 10: LDRH/STRH with immediate offset (halfword only, no byte).
    bits 15:12 = 1000
    bit 11     = L
    bits 10:6  = imm5 (multiplied by 2)
    bits 5:3   = Rb
    bits 2:0   = Rd }
var
  lBit: Boolean;
  imm5, rb, rd: Integer;
  address: TWord;
begin
  lBit := ((instr shr 11) and 1) = 1;
  imm5 := (instr shr 6) and $1F;
  rb   := (instr shr 3) and $7;
  rd   := instr and $7;
  address := FState.R[rb] + TWord(imm5) shl 1;

  if lBit then FState.R[rd] := TWord(FReadHalf(address))
          else FWriteHalf(address, THalf(FState.R[rd] and $FFFF));
end;

procedure TArmCore.ExecThumbFmt11SpRel(instr: THalf);
{ Format 11: LDR/STR Rd, [SP, #imm8<<2] — word load/store with SP base.
    bits 15:12 = 1001
    bit 11     = L
    bits 10:8  = Rd
    bits 7:0   = imm8 (multiplied by 4) }
var
  lBit: Boolean;
  rd: Integer;
  address: TWord;
begin
  lBit := ((instr shr 11) and 1) = 1;
  rd   := (instr shr 8) and $7;
  address := FState.R[R_SP] + ((TWord(instr) and $FF) shl 2);

  if lBit then FState.R[rd] := FReadWord(address)
          else FWriteWord(address, FState.R[rd]);
end;

procedure TArmCore.ExecThumbFmt14PushPop(instr: THalf);
{ Format 14: PUSH/POP — multi-register stack ops.
    bits 15:9 = 1011 010 (PUSH) or 1011 110 (POP)
    bit 11    = L (0 = PUSH = store, 1 = POP = load)
    bit 8     = R (PUSH: include LR ; POP: include PC)
    bits 7:0  = register list (R0..R7)

  PUSH semantics: STMDB SP! [ reglist, optional LR ]
    SP -= count*4
    write registers in ascending order from low address up
    (LR if R=1 is at the highest address)

  POP semantics: LDMIA SP! [ reglist, optional PC ]
    read registers in ascending order from current SP up
    SP += count*4
    if PC popped: PC := value AND ~1 ; CPSR.T := value[0] (since POP [pc]
    is the canonical THUMB function return). }
var
  lBit, rBit: Boolean;
  regList: TWord;
  count, i: Integer;
  sp, addr, val: TWord;
begin
  lBit := ((instr shr 11) and 1) = 1;
  rBit := ((instr shr 8) and 1) = 1;
  regList := instr and $FF;

  count := 0;
  for i := 0 to 7 do if ((regList shr i) and 1) = 1 then Inc(count);
  if rBit then Inc(count);

  if count = 0 then Exit;

  sp := FState.R[R_SP];

  if not lBit then
  begin
    { PUSH = STMDB SP! }
    sp := sp - count * 4;
    addr := sp;
    for i := 0 to 7 do
      if ((regList shr i) and 1) = 1 then
      begin
        FWriteWord(addr, FState.R[i]);
        Inc(addr, 4);
      end;
    if rBit then FWriteWord(addr, FState.R[R_LR]);
    FState.R[R_SP] := sp;
  end
  else
  begin
    { POP = LDMIA SP! }
    addr := sp;
    for i := 0 to 7 do
      if ((regList shr i) and 1) = 1 then
      begin
        FState.R[i] := FReadWord(addr);
        Inc(addr, 4);
      end;
    if rBit then
    begin
      val := FReadWord(addr);
      Inc(addr, 4);
      { POP-PC: target's low bit selects mode (THUMB convention). }
      if (val and 1) <> 0 then
      begin
        FState.CPSR := FState.CPSR or CPSR_T;
        FState.R[R_PC] := val and not TWord($1);
      end
      else
      begin
        FState.CPSR := FState.CPSR and not CPSR_T;
        FState.R[R_PC] := val and not TWord($3);
      end;
      FBranched := True;
    end;
    FState.R[R_SP] := addr;
  end;
end;

procedure TArmCore.ExecThumbFmt15Multiple(instr: THalf);
{ Format 15: LDMIA/STMIA Rb!, [ reglist ] — multi-register load/store.
    bits 15:12 = 1100
    bit 11     = L
    bits 10:8  = Rb (base — auto-incremented)
    bits 7:0   = register list (R0..R7)
  Always Increment-After with writeback. }
var
  lBit: Boolean;
  rb: Integer;
  regList: TWord;
  addr: TWord;
  i: Integer;
begin
  lBit := ((instr shr 11) and 1) = 1;
  rb   := (instr shr 8) and $7;
  regList := instr and $FF;
  addr := FState.R[rb];

  for i := 0 to 7 do
    if ((regList shr i) and 1) = 1 then
    begin
      if lBit then FState.R[i] := FReadWord(addr)
              else FWriteWord(addr, FState.R[i]);
      Inc(addr, 4);
    end;

  FState.R[rb] := addr;
end;

procedure TArmCore.ExecThumbFmt16CondBranch(instr: THalf);
{ Format 16: B<cond> label (short conditional branch).
    bits 11:8 = cond (same 16-value encoding as ARM, but cond=1110
                       is undefined and cond=1111 is SWI/format 17)
    bits 7:0  = signed 8-bit offset (in halfwords)
  target = (PC + 4) + sign_extend(imm8 << 1). }
var
  cond: Integer;
  offset: Int32;
  target: TWord;
begin
  cond := (instr shr 8) and $F;
  if not EvaluateCondition(TByte(cond)) then Exit;

  offset := instr and $FF;
  if (offset and $80) <> 0 then offset := offset or Int32($FFFFFF00);
  offset := offset shl 1;

  target := TWord(Int64(FState.R[R_PC]) + 4 + Int64(offset));
  FState.R[R_PC] := target;
  FBranched := True;
end;

procedure TArmCore.ExecThumbFmt17SWI(instr: THalf);
{ Format 17: SWI #imm8. Same trap semantics as ARM SWI — but the
  return address saved to LR_svc is PC+2.
    bits 15:8 = 11011111
    bits 7:0  = comment / SWI number
  After return via MOVS PC, LR, CPSR.T is restored from SPSR_svc so the
  caller resumes in THUMB mode automatically.

  BIOS HLE: same hook as ARM SWI. The SWI number for THUMB SWI is in
  bits 7:0 of the halfword. }
var
  oldCPSR, returnAddr, newCPSR: TWord;
  swiNum: TByte;
begin
  swiNum := instr and $FF;
  Inc(SwiExecCount[swiNum]);

  if Assigned(FSwiHook) and FSwiHook(swiNum) then
  begin
    { Handled in Pascal — PC advances by 2 via the post-step tail. }
    Exit;
  end;

  oldCPSR := FState.CPSR;
  returnAddr := FState.R[R_PC] + 2;

  newCPSR := (FState.CPSR and not (CPSR_MODE_MASK or CPSR_T)) or Ord(amSVC) or CPSR_I;
  WriteCPSR(newCPSR);

  FState.R[R_LR] := returnAddr;
  SetCurrentSpsr(oldCPSR);

  FState.R[R_PC] := $00000008;
  FBranched := True;
end;

procedure TArmCore.ExecThumbFmt18Branch(instr: THalf);
{ Format 18: unconditional B label (long-range).
    bits 15:11 = 11100
    bits 10:0  = signed 11-bit offset (in halfwords)
  target = (PC + 4) + sign_extend(imm11 << 1). }
var
  offset: Int32;
  target: TWord;
begin
  offset := instr and $7FF;
  if (offset and $400) <> 0 then offset := offset or Int32($FFFFF800);
  offset := offset shl 1;

  target := TWord(Int64(FState.R[R_PC]) + 4 + Int64(offset));
  FState.R[R_PC] := target;
  FBranched := True;
end;

procedure TArmCore.ExecThumbFmt19BL(instr: THalf);
{ Format 19: BL — long-range branch with link. Encoded as TWO consecutive
  THUMB halfwords: the "high" half sets up LR, the "low" half completes
  the branch and updates LR to the return address.

  High half (bit 11 = 0):  bits 15:11 = 11110, bits 10:0 = offset_high
    LR := PC + sign_extend(offset_high << 12)
    where PC is the pipelined value = current_PC + 4

  Low half  (bit 11 = 1):  bits 15:11 = 11111, bits 10:0 = offset_low
    temp := PC + 2  (address of instruction after the low half)
    PC   := LR + (offset_low << 1)
    LR   := temp | 1   (mark as THUMB return address)

  Each half advances PC by 2 like any other THUMB instruction. We dispatch
  them as separate steps — externally visible state evolves naturally. }
var
  hBit: Boolean;
  offset: Int32;
  uOffset: TWord;
  temp: TWord;
begin
  hBit := ((instr shr 11) and 1) = 1;

  if not hBit then
  begin
    { High half: LR := PC + (sign_extend(offset_high) << 12). }
    offset := instr and $7FF;
    if (offset and $400) <> 0 then offset := offset or Int32($FFFFF800);
    offset := offset shl 12;
    FState.R[R_LR] := TWord(Int64(FState.R[R_PC]) + 4 + Int64(offset));
    { No branch — fall through to PC += 2 in tail. }
  end
  else
  begin
    { Low half: temp = address of next instruction (PC+2 in our model);
      PC := LR + (offset_low << 1); LR := temp | 1. }
    uOffset := (TWord(instr) and $7FF) shl 1;
    temp := FState.R[R_PC] + 2;
    FState.R[R_PC] := FState.R[R_LR] + uOffset;
    FState.R[R_LR] := temp or 1;
    FBranched := True;
  end;
end;

procedure TArmCore.StepThumb(pcBefore: TWord);
{ THUMB top-level decode per ARM ARM Table A6-1. The decision tree
  branches on the top 5-8 bits of the halfword. }
var
  instr: THalf;
  top3, top4, top5, top6, top8: Integer;
begin
  instr := FReadHalf(pcBefore);
  top3 := (instr shr 13) and $7;
  top4 := (instr shr 12) and $F;
  top5 := (instr shr 11) and $1F;
  top6 := (instr shr 10) and $3F;
  top8 := (instr shr 8)  and $FF;

  case top3 of
    $0:  { 000 — Format 1 (LSL/LSR/ASR imm5) or Format 2 (ADD/SUB) }
      if top5 = $03 then ExecThumbFmt2AddSub(instr)
                    else ExecThumbFmt1ShiftedReg(instr);
    $1: ExecThumbFmt3MovCmpAddSubImm(instr);
    $2:
      case top6 of
        $10: ExecThumbFmt4Alu(instr);
        $11: ExecThumbFmt5HiRegOrBX(instr);
        $12, $13: ExecThumbFmt6PcLoad(instr);
        $14, $15, $16, $17:
          { Top4 = 0101. Bit 9 of the instruction distinguishes:
              bit 9 = 0 → Format 7 (LDR/STR/LDRB/STRB reg-offset)
              bit 9 = 1 → Format 8 (LDRH/STRH/LDRSB/LDRSH reg-offset, sign-ext) }
          if ((instr shr 9) and 1) = 0 then ExecThumbFmt7RegOffset(instr)
                                       else ExecThumbFmt8SignExt(instr);
      end;
    $3:  { 011 — Format 9 load/store immediate offset (word/byte) }
      ExecThumbFmt9ImmOffset(instr);
    $4:  { 100 — Format 10 (LDRH/STRH imm) or Format 11 (SP-rel) }
      case top4 of
        $8: ExecThumbFmt10Halfword(instr);
        $9: ExecThumbFmt11SpRel(instr);
      end;
    $5:  { 101 — Format 12 (load addr) or Format 13 (ADD SP) or Format 14 (push/pop) }
      case top4 of
        $A: ExecThumbFmt12LoadAddr(instr);
        $B:
          { top8 = $B0 → ADD SP (Format 13)
            top8 = $B4/$B5 → PUSH; top8 = $BC/$BD → POP (both Format 14) }
          if top8 = $B0 then ExecThumbFmt13AddOffsetSP(instr)
          else if (top8 = $B4) or (top8 = $B5) or (top8 = $BC) or (top8 = $BD) then
            ExecThumbFmt14PushPop(instr)
          else
            Writeln(StdErr, Format('ThumbCore: unrecognized 1011-class opcode at PC=%08x (instr=%04x)',
                                    [pcBefore, instr]));
      end;
    $6:  { 110 — Format 15 (LDMIA/STMIA) or Format 16/17 (cond branch / SWI) }
      case top4 of
        $C: ExecThumbFmt15Multiple(instr);
        $D:
          if ((instr shr 8) and $F) = $F then ExecThumbFmt17SWI(instr)
                                         else ExecThumbFmt16CondBranch(instr);
      end;
    $7:  { 111 — Format 18 unconditional B (top5=11100) or Format 19 BL (top5=11110/11111) }
      case top5 of
        $1C: ExecThumbFmt18Branch(instr);
        $1E, $1F: ExecThumbFmt19BL(instr);
      else
        Writeln(StdErr, Format('ThumbCore: undefined opcode at PC=%08x (instr=%04x)',
                                [pcBefore, instr]));
      end;
  end;
end;

{ ───── Top-level Step ────────────────────────────────────────────── }

function TArmCore.Step: Integer;
var
  instr, pcBefore: TWord;
  cond: TByte;
  klass: Integer;
begin
  Result := 1;   { 1-cycle approximation for phase A }

  { Diagnostic trace — count executions at specific BIOS PCs. }
  case FState.R[R_PC] of
    $00000134: Inc(TraceBiosLdrPc);
    $00000300: Inc(TraceBiosUserHandler);
    $0000031C: Inc(TraceBiosStrhIntrCheck);
    $00000344: Inc(TraceBiosHaltcntWrite);
  end;

  { Halt state: CPU is asleep until an enabled IRQ is REQUESTED. Per
    GBATEK, Halt ends whenever IE & IF <> 0, regardless of IME and of
    CPSR.I — those two only gate whether the woken CPU vectors to the
    IRQ handler or simply resumes at the next instruction. The raw
    request check is the FWakeCheck hook; open-source BIOS boot code
    depends on the IME=0 wake path (it animates by Halting with IE set
    and IME off). Without the hook installed we fall back to the
    stricter IRQ oracle (IE & IF & IME), the pre-hook behavior. }
  if FState.Halted then
  begin
    if Assigned(FWakeCheck) then
    begin
      if FWakeCheck() then
        FState.Halted := False;
    end
    else if Assigned(FIrqCheck)
         and ((FState.CPSR and CPSR_I) = 0)
         and FIrqCheck() then
      FState.Halted := False;

    if FState.Halted then
      Exit;

    { Woken: vector now if the CPU may service the IRQ (IME + CPSR.I
      permitting); otherwise fall through and resume execution at the
      instruction after the halt. }
    if Assigned(FIrqCheck)
       and ((FState.CPSR and CPSR_I) = 0)
       and FIrqCheck() then
    begin
      TakeIrq;
      Inc(FState.Cycles);
      Exit;
    end;
  end;

  FBranched := False;

  { IRQ check happens BEFORE instruction fetch. If an IRQ is pending and
    CPSR.I = 0, take the exception now — the would-be next instruction
    doesn't run this step (it'll run when the handler returns via SUBS
    PC, LR, #4). The handler runs in ARM mode regardless of caller mode
    because the vector at $00000018 is ARM. }
  if Assigned(FIrqCheck)
     and ((FState.CPSR and CPSR_I) = 0)
     and FIrqCheck() then
  begin
    TakeIrq;
    Inc(FState.Cycles);
    Exit;
  end;

  pcBefore := FState.R[R_PC];

  { THUMB mode: 16-bit instructions, different decode tree, PC += 2. }
  if (FState.CPSR and CPSR_T) <> 0 then
  begin
    StepThumb(pcBefore);
    if not FBranched then FState.R[R_PC] := pcBefore + 2;
    Inc(FState.Cycles);
    Exit;
  end;

  instr := FReadWord(pcBefore);

  cond := (instr shr 28) and $F;
  if not EvaluateCondition(cond) then
  begin
    { Skip this instruction — advance PC and exit. }
    FState.R[R_PC] := pcBefore + 4;
    Exit;
  end;

  { Top-level class decode by bits 27:25. ARM v4T distinguishes:
      000  Data Processing register / Multiply / PSR transfer / Halfword transfers
      001  Data Processing immediate / MSR immediate / Undefined
      010  Single Data Transfer (immediate offset)
      011  Single Data Transfer (register offset) / Undefined
      100  Block Data Transfer (LDM/STM)
      101  Branch / Branch with Link
      110  Coprocessor data transfer
      111  Coprocessor data op / SWI

    Phase A implements 000 / 001 (data processing) and 101 (branch).
    Everything else is currently a no-op stub — Writeln a warning and
    advance PC so we see how far real code gets before falling off the
    implemented surface. }
  klass := (instr shr 25) and $7;

  { BX has a very specific full-instruction pattern. Detect first because
    it shares the PSR-transfer encoding hole (bits 24:23 = 10, S = 0) and
    would otherwise be misrouted there. Bit 4 = 1 distinguishes BX from
    MSR/MRS (which have bit 4 = 0). }
  if (instr and $0FFFFFF0) = $012FFF10 then
  begin
    ExecBranchExchange(instr);
    Inc(FState.Cycles);
    Exit;
  end;

  { PSR-transfer (MRS/MSR) sits in the DP encoding hole: opcode bits 24:23 = 10
    with S=0 (bit 20 = 0). Class 0 (register source) AND class 1 (immediate
    source) both use this hole.

    Halfword/signed-byte transfers ALSO occupy this hole when P=1 U=0 (bits
    24:23 = 10) and L=0/1 with S=0. They are disambiguated by the bits 7:4
    "1ss1" signature (s ≠ 00). This trap was discovered during BIOS boot:
    STRHEQ R2, [R3, #-8] at BIOS $0000031C ($014320B8) was being misrouted
    to ExecPsrTransfer, so the IntrCheck flag never got written and
    IntrWait spun forever. Same family as other hand-encoded ARM
    instruction traps — encodings that look like data-processing holes
    until the secondary signature bits are inspected.

    The disambiguation matters only in class 0 (register form). In class 1
    (immediate form), bit 4 is part of imm8 and must not be inspected for
    halfword detection. Multiply (bits 7:4 = 1001 with bit 24 = 0) doesn't
    overlap the PSR hole because PSR requires bit 24 = 1. }
  if (klass = $0) or (klass = $1) then
  begin
    if (((instr shr 23) and $3) = $2) and (((instr shr 20) and 1) = 0) then
    begin
      { Exclude halfword/signed-byte transfers in class 0. }
      if not ((klass = $0) and ((instr and $90) = $90) and ((instr and $60) <> 0)) then
      begin
        ExecPsrTransfer(instr);
        FState.R[R_PC] := pcBefore + 4;
        Inc(FState.Cycles);
        Exit;
      end;
    end;
  end;

  case klass of
    $0:
      begin
        { Class 000 is multiplexed: DP register-form, multiply, halfword/signed
          transfers, MSR/MRS, SWP. The bit 7:4 signature discriminates:
            1001 with bit 24 = 0 → multiply (32-bit if bit 23=0, long if =1)
            1ss1 with ss ≠ 00    → halfword/signed transfer (LDRH/STRH/LDRSB/LDRSH)
          Anything else in class 0 → DP register form. }
        if ((instr and $90) = $90) and ((instr and $60) <> 0) then
          ExecHalfwordTransfer(instr)
        else if (((instr shr 4) and $F) = $9) and (((instr shr 24) and 1) = 0) then
        begin
          if ((instr shr 23) and 1) = 0 then
            ExecMultiply(instr)
          else
            ExecMultiplyLong(instr);
        end
        else
          ExecDataProcessing(instr);
      end;
    $1:     ExecDataProcessing(instr);
    $2, $3: ExecSingleDataTransfer(instr);
    $4:     ExecBlockDataTransfer(instr);
    $5:     ExecBranch(instr);
    $7:
      begin
        { Class 111: SWI has bits 27:24 = 1111. Coprocessor instructions
          (bit 24 = 0) and MRC/MCR (bit 24 = 1 with bit 4 = 1) live here
          too but aren't used by GBA software; stub them. }
        if (((instr shr 24) and 1) = 1) then
          ExecSWI(instr)
        else
          Writeln(StdErr, Format('ArmCore: coprocessor instruction unimplemented at PC=%08x (instr=%08x)',
                                  [pcBefore, instr]));
      end;
  else
    Writeln(StdErr, Format('ArmCore: unimplemented instruction class %d at PC=%08x (instr=%08x)',
                            [klass, pcBefore, instr]));
  end;

  { Advance PC by 4 only if the instruction did not branch. The
    FBranched flag is set by handlers that explicitly write PC
    (ExecBranch, ExecSWI, DP ops whose Rd is R15). }
  if not FBranched then
    FState.R[R_PC] := pcBefore + 4;

  Inc(FState.Cycles);
end;

procedure TArmCore.Run(maxSteps: Integer);
var i: Integer;
begin
  for i := 1 to maxSteps do
  begin
    if FState.Halted then Break;
    Step;
  end;
end;

end.
