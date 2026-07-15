unit GbaTypes;
{
  Common types for the Pascal GBA emulator. Everything that's "what's
  a register" or "what's a mode" — used by armcore, memory, ppu, etc.

  Type names mirror the ARM architecture reference manual where possible
  (UInt32 for 32-bit regs, UInt16 for halfwords, UInt8 for bytes).
}

{$mode objfpc}{$H+}

interface

type
  { Native integer widths used across the emulator. FPC's built-in
    UInt32 etc. are fine; aliasing for ARM-spec readability. }
  TByte    = UInt8;
  THalf    = UInt16;
  TWord    = UInt32;
  TDWord   = UInt64;
  PByte32  = ^TByte;
  PHalf    = ^THalf;
  PWord    = ^TWord;

  { ARM processor modes, encoded into CPSR[4:0]. The numeric values
    ARE the bit patterns the hardware uses; do not renumber. }
  TArmMode = (
    amUser = $10,   { User      - normal execution }
    amFIQ  = $11,   { FIQ       - fast interrupt }
    amIRQ  = $12,   { IRQ       - normal interrupt }
    amSVC  = $13,   { Supervisor - software interrupt / reset }
    amABT  = $17,   { Abort     - data/prefetch abort }
    amUND  = $1B,   { Undefined - undefined instruction }
    amSYS  = $1F    { System    - privileged user-like mode }
  );

const
  { CPSR flag bit positions (1-shifted into the register). }
  CPSR_N = $80000000;   { Negative — bit 31 }
  CPSR_Z = $40000000;   { Zero     — bit 30 }
  CPSR_C = $20000000;   { Carry    — bit 29 }
  CPSR_V = $10000000;   { Overflow — bit 28 }
  CPSR_I = $00000080;   { IRQ disable — bit 7  }
  CPSR_F = $00000040;   { FIQ disable — bit 6  }
  CPSR_T = $00000020;   { Thumb mode  — bit 5  }
  CPSR_MODE_MASK = $1F; { bits 4:0 hold the mode }

  { Convenience register-index constants. ARM names — R13/R14/R15 have
    architectural roles (stack pointer / link register / program counter)
    even in non-Thumb code, by software convention. }
  R_SP = 13;
  R_LR = 14;
  R_PC = 15;

type
  { Full ARM7TDMI processor state, including all banked registers and
    the saved program-status registers for each privileged mode.

    Banking model (per the ARM7TDMI TRM):
      User/System — share the same 16 registers (no SPSR exists)
      FIQ         — banks R8..R14 (R8_fiq..R14_fiq) + SPSR_fiq
      IRQ         — banks R13..R14 (R13_irq, R14_irq) + SPSR_irq
      Supervisor  — banks R13..R14                    + SPSR_svc
      Abort       — banks R13..R14                    + SPSR_abt
      Undefined   — banks R13..R14                    + SPSR_und

    On a mode switch (writeback of CPSR_mode bits), we save the visible
    R[i] into the bank slot for the old mode, then load R[i] from the
    bank slot for the new mode. SPSR follows the same swap.

    `R[15]` (PC) is special: ARM pipeline emulation means reads of R15
    return PC+8 in ARM mode and PC+4 in Thumb mode. We store the
    "current instruction address" in `R[15]` and adjust at decode time. }

  TArmState = record
    R:        array[0..15] of TWord;     { current visible registers }
    CPSR:     TWord;                     { current program status }

    { Banked registers per ARM7TDMI banking. Index 0 of these arrays
      is unused — array slots are labelled with their register number
      for readability (no off-by-one math at access sites). }
    R_usr:    array[8..12] of TWord;     { User/Sys R8..R12 (used when leaving FIQ) }
    R_usr_sp: TWord;                     { User/Sys R13 }
    R_usr_lr: TWord;                     { User/Sys R14 }

    R_fiq:    array[8..14] of TWord;     { FIQ R8..R14 }
    SPSR_fiq: TWord;

    R_irq_sp: TWord;                     { IRQ R13 }
    R_irq_lr: TWord;                     { IRQ R14 }
    SPSR_irq: TWord;

    R_svc_sp: TWord;                     { Supervisor R13 }
    R_svc_lr: TWord;                     { Supervisor R14 }
    SPSR_svc: TWord;

    R_abt_sp: TWord;                     { Abort R13 }
    R_abt_lr: TWord;                     { Abort R14 }
    SPSR_abt: TWord;

    R_und_sp: TWord;                     { Undefined R13 }
    R_und_lr: TWord;                     { Undefined R14 }
    SPSR_und: TWord;

    { Pipeline-state cache: prefetched instructions live ahead of PC.
      For interpretation we can compute these on the fly, but caching
      is faster and matches what real ARM7 cores do. }
    Halted:   Boolean;                   { CP15-style halt (BIOS Halt SWI) }
    Cycles:   TDWord;                    { running cycle counter (for scheduler) }
  end;

  PArmState = ^TArmState;

{ Safe-stdout helpers — Writeln raises IOResult 103 ("File not open") in
  GUI applications that have no attached console. Every subsystem that
  used to call Writeln directly should call SafeLog/SafeLogErr instead
  so the code runs identically in console hosts (gbarun.exe) and GUI
  hosts (gbashell.exe). Lazarus GUI apps with no attached console hit
  IOResult 103 on bare Writeln; these helpers no-op when Output is not
  open. }
procedure SafeLog(const s: string);
procedure SafeLogErr(const s: string);

implementation

procedure SafeLog(const s: string);
begin
  if (TextRec(Output).Mode <> fmOutput) and
     (TextRec(Output).Mode <> fmInOut) then Exit;
  {$I-}
  Writeln(s);
  {$I+}
  if IOResult <> 0 then ;
end;

procedure SafeLogErr(const s: string);
begin
  if (TextRec(ErrOutput).Mode <> fmOutput) and
     (TextRec(ErrOutput).Mode <> fmInOut) then Exit;
  {$I-}
  Writeln(ErrOutput, s);
  {$I+}
  if IOResult <> 0 then ;
end;

end.
