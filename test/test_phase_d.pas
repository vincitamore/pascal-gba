program test_phase_d;
{
  Phase D acceptance tests — input + IRQ + Timer 0 + CPU/PPU/IRQ
  integration.

  Tests are layered:
    1-3   Standalone unit tests of TGbaIrq (request, ack, mask gating).
    4-5   Timer 0 — overflow fires IRQ; prescaler scales the rate.
    6     Input mapping (no display needed — uses a fake key oracle).
    7     CPU takes the IRQ exception correctly (LR_irq, mode switch).
    8     Full integration: an ARM program runs in EWRAM, configures
          IE/IME, waits for VBlank, handler increments a counter, main
          loop reads the counter.
}

{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, Memory, ArmCore, Irq, Timers, Ppu;

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

{ ───── IRQ controller tests ─────────────────────────────────────── }

procedure TestIrqRequest;
{ Request VBlank ; verify IF bit 0 is set in memory. }
var
  mem: TGbaMemory;
  irq: TGbaIrq;
begin
  Writeln('--- TestIrqRequest ---');
  mem := TGbaMemory.Create;
  irq := TGbaIrq.Create(mem);
  try
    irq.Request(IRQ_VBLANK);
    CheckEq('IF bit 0 (V-blank) set after Request',
            $0001, TWord(mem.ReadHalf(REG_IF_ADDR)));
  finally
    irq.Free; mem.Free;
  end;
end;

procedure TestIrqMaskAndAck;
{ IE = 0x0001 (V-blank enabled), IME = 1, request V-blank → Pending = True.
  Write 1 to IF bit 0 (ack) → Pending = False (and IF is cleared in our
  shadow). }
var
  mem: TGbaMemory;
  irq: TGbaIrq;
begin
  Writeln('--- TestIrqMaskAndAck ---');
  mem := TGbaMemory.Create;
  irq := TGbaIrq.Create(mem);
  try
    mem.WriteHalf(REG_IE_ADDR,  $0001);
    mem.WriteHalf(REG_IME_ADDR, $0001);
    irq.Request(IRQ_VBLANK);
    CheckBool('Pending = True after Request+enable', True, irq.Pending);

    { CPU acks by writing 1 to IF bit 0. Real-hardware write-1-clear
      semantics: writing a 1 to a bit position CLEARS it; writing a 0
      is a no-op. Moved into Memory.WriteHalf at the IF address during
      Phase F's BIOS-boot wiring (was previously the SyncIfFromMemoryWrites
      shadow-AND-memory reconciliation hack; that was broken for real
      BIOS code which writes 1, not 0). }
    mem.WriteHalf(REG_IF_ADDR, $0001);    { write 1 to bit 0 → clears bit 0 }
    CheckBool('Pending = False after CPU acks IF bit 0 (write-1-clear)', False, irq.Pending);
  finally
    irq.Free; mem.Free;
  end;
end;

procedure TestIrqImeGate;
{ IME = 0 should mask out all interrupts even if IE matches IF. }
var
  mem: TGbaMemory;
  irq: TGbaIrq;
begin
  Writeln('--- TestIrqImeGate ---');
  mem := TGbaMemory.Create;
  irq := TGbaIrq.Create(mem);
  try
    mem.WriteHalf(REG_IE_ADDR,  $FFFF);
    mem.WriteHalf(REG_IME_ADDR, $0000);    { master disable }
    irq.Request(IRQ_VBLANK);
    irq.Request(IRQ_TIMER0);
    CheckBool('Pending = False when IME=0', False, irq.Pending);

    mem.WriteHalf(REG_IME_ADDR, $0001);
    CheckBool('Pending = True after IME=1', True, irq.Pending);
  finally
    irq.Free; mem.Free;
  end;
end;

procedure TestIrqIeGate;
{ Request Timer1 but only Timer0 is enabled in IE — should not be pending. }
var
  mem: TGbaMemory;
  irq: TGbaIrq;
begin
  Writeln('--- TestIrqIeGate ---');
  mem := TGbaMemory.Create;
  irq := TGbaIrq.Create(mem);
  try
    mem.WriteHalf(REG_IE_ADDR,  $0008);    { only T0 (bit 3) }
    mem.WriteHalf(REG_IME_ADDR, $0001);
    irq.Request(IRQ_TIMER1);
    CheckBool('Timer1 not pending (only T0 in IE)', False, irq.Pending);

    irq.Request(IRQ_TIMER0);
    CheckBool('Timer0 pending after request', True, irq.Pending);
  finally
    irq.Free; mem.Free;
  end;
end;

{ ───── Timer 0 tests ────────────────────────────────────────────── }

procedure TestTimer0Overflow;
{ Configure T0 with reload=$FFFE, prescaler=1, enabled, IRQ on overflow.
  Step ~5 cycles. Timer should wrap: $FFFE → $FFFF → reload($FFFE) on
  overflow → fires IRQ.

  Actually: step 1 cycle → counter = $FFFF.
            step 1 cycle → counter overflows ($10000 → wrap to reload
            $FFFE) → fires Timer0 IRQ. }
var
  mem: TGbaMemory;
  irq: TGbaIrq;
  timers: TGbaTimers;
begin
  Writeln('--- TestTimer0Overflow ---');
  mem := TGbaMemory.Create;
  irq := TGbaIrq.Create(mem);
  timers := TGbaTimers.Create(mem, irq);
  try
    mem.WriteHalf(REG_IE_ADDR,  $0008);    { enable T0 IRQ }
    mem.WriteHalf(REG_IME_ADDR, $0001);

    { TM0CNT_L (reload) := $FFFE. }
    mem.WriteHalf($04000100, $FFFE);
    { TM0CNT_H := enable=1, IRQ=1, prescaler=00 (=1). }
    mem.WriteHalf($04000102, $00C0);
    { On the first Step call, ReadAndLatch will detect the 0→1
      enable transition and seed the counter to $FFFE. }

    timers.Step(1);
    CheckEq('After 1 cycle: counter = $FFFF', $FFFF,
            TWord(mem.ReadHalf($04000100)));
    CheckBool('No IRQ yet (no overflow)', False, irq.Pending);

    timers.Step(1);
    { On this cycle counter increments from $FFFF to $10000 → wraps to
      reload ($FFFE) and fires the IRQ. }
    CheckEq('After 2 cycles: counter wrapped to reload $FFFE',
            $FFFE, TWord(mem.ReadHalf($04000100)));
    CheckBool('IRQ pending after overflow', True, irq.Pending);
  finally
    timers.Free; irq.Free; mem.Free;
  end;
end;

procedure TestTimer0Prescaler;
{ With prescaler=64, advancing 63 cycles should not increment the counter;
  64th cycle should bump it once. }
var
  mem: TGbaMemory;
  irq: TGbaIrq;
  timers: TGbaTimers;
begin
  Writeln('--- TestTimer0Prescaler ---');
  mem := TGbaMemory.Create;
  irq := TGbaIrq.Create(mem);
  timers := TGbaTimers.Create(mem, irq);
  try
    mem.WriteHalf($04000100, $0000);
    mem.WriteHalf($04000102, $0081);     { enable=1, IRQ=0, prescaler=01 (=64) }

    timers.Step(63);
    CheckEq('After 63 cycles with prescaler 64: counter still 0',
            $0000, TWord(mem.ReadHalf($04000100)));

    timers.Step(1);
    CheckEq('After 64th cycle: counter = 1',
            $0001, TWord(mem.ReadHalf($04000100)));

    timers.Step(128);
    CheckEq('After +128 cycles: counter = 3',
            $0003, TWord(mem.ReadHalf($04000100)));
  finally
    timers.Free; irq.Free; mem.Free;
  end;
end;

{ ───── CPU IRQ entry test ───────────────────────────────────────── }

type
  TFakeIrqOracle = class
  public
    Pending: Boolean;
    function Check: Boolean;
  end;

function TFakeIrqOracle.Check: Boolean;
begin
  Result := Pending;
end;

procedure TestCpuTakesIrq;
{ Install a fake IRQ oracle that returns True. Run one CPU step. The
  CPU should perform the exception entry: mode → IRQ, CPSR.I = 1,
  LR_irq = pcBefore + 4, SPSR_irq = old CPSR, PC = $00000018. }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  oracle: TFakeIrqOracle;
  startPc, startCpsr: TWord;
begin
  Writeln('--- TestCpuTakesIrq ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  oracle := TFakeIrqOracle.Create;
  try
    cpu.SetMemoryHooks(@mem.ReadWord, @mem.ReadHalf, @mem.ReadByte,
                       @mem.CpuWriteWord, @mem.CpuWriteHalf, @mem.CpuWriteByte);
    cpu.SetIrqHook(@oracle.Check);

    { Start in SYS mode with IRQs enabled. Put an arbitrary instruction
      at PC = $02000100 (won't run; the IRQ pre-empts). }
    cpu.SetReg(R_PC, $02000100);
    startPc := $02000100;
    { CPSR: SYS mode + IRQ enabled (I bit = 0). }
    startCpsr := $0000001F;
    { Force-set CPSR by going through the SVC→SYS WriteCPSR path. The
      public surface is property State; for the test we override via
      direct field assignment isn't available, so we MSR via instruction.
      Simpler path: set initial CPSR via a one-shot ARM MSR run. }
    mem.WriteWord(startPc, $E321F01F);   { MSR CPSR_c, #$1F → SYS, IRQ on }
    oracle.Pending := False;
    cpu.Step;       { runs the MSR }
    cpu.SetReg(R_PC, $02000200);
    startPc := $02000200;
    startCpsr := cpu.State.CPSR;

    oracle.Pending := True;
    cpu.Step;        { should take the IRQ instead of fetching at $200 }

    CheckEq('PC = IRQ vector $00000018', $00000018, cpu.GetReg(R_PC));
    CheckEq('CPSR mode = IRQ ($12)', $12, cpu.State.CPSR and $1F);
    CheckBool('CPSR.I = 1 (IRQs masked during handler)',
              True, (cpu.State.CPSR and CPSR_I) <> 0);
    CheckEq('LR_irq = pcBefore + 4', startPc + 4, cpu.GetReg(R_LR));
    CheckEq('SPSR_irq captured pre-IRQ CPSR', startCpsr, cpu.State.SPSR_irq);
  finally
    oracle.Free; cpu.Free; mem.Free;
  end;
end;

{ ───── Full integration: ARM program + V-blank IRQ ──────────────── }

procedure TestVblankIntegration;
{ Run a tiny ARM program that:
    - Sets up IRQ stack
    - Switches to SYS mode (IRQs enabled)
    - Enables V-blank in IE, IME
    - Spin-loops incrementing a "ticks" counter in IWRAM
  The handler at $00000018 just increments a "vblanks-seen" counter
  in IWRAM and returns via SUBS PC, LR, #4.

  We manually fire the V-blank IRQ (no PPU integration in this test —
  separate test for the per-scanline loop). Verify:
    - Handler ran (vblanks counter incremented)
    - Main loop resumed (ticks counter incremented after IRQ)

  Memory layout:
    $00000018  IRQ vector: branch to handler at $03000200
    $03000100  ticks counter
    $03000104  vblanks counter
    $02000000  main program
    $03000200  IRQ handler
}
var
  mem: TGbaMemory;
  cpu: TArmCore;
  irq: TGbaIrq;
  i: Integer;
const
  { Main program at $02000000:
      MOV R0, #0x03000000       ; counter base (need to ROR — use ORR trick)
      ORR R0, R0, #0x100        ; → R0 = 0x03000100 (ticks ptr)
    Tricky: 0x03000000 ROR-imm encoding. 0x03 ROR-by-8 = bits 25,24 set
      = 0x03000000. imm12 = (4<<8) | 0x03 = 0x403.
    0x03000100: that's 0x03000000 | 0x100. 0x100 = 0x01 << 8.
      0x01 ROR by 24 places bit 0 at bit 8 = 0x100. rot=12, imm12 = (12<<8)|1 = 0xC01.

    Easier path: load R0 via two LDRs from a literal pool past the code.

    Simpler still: use STR to known addresses via small-immediate base.
      Set R1 = 0 ; ADD R1, #0x100 ... no the rotated 8-bit lets us hit any
      multiple-of-(rotate-pattern). Let me just hand-bake constants.

    For this test we use IWRAM at $03000000 and a single index register
    R1 := 0x03000000 (via MOV R1, #0x03000000 = E3A01403).

    Program:
      addr 0x02000000:  MOV R1, #0x03000000      E3A01403
      addr 0x02000004:  MOV R2, #0               E3A02000
      addr 0x02000008:  STR R2, [R1, #0x100]     E5812100  (ticks := 0)
      addr 0x0200000C:  STR R2, [R1, #0x104]     E5812104  (vblanks := 0)

      ; Set IE = 1, IME = 1.
      addr 0x02000010:  MOV R3, #1               E3A03001
      addr 0x02000014:  MOV R4, #0x04000000      E3A04403   (mem-mapped IO base)
      addr 0x02000018:  STRH R3, [R4, #0x200]    E1C432B0   (IE  = 1)
      addr 0x0200001C:  STRH R3, [R4, #0x208]    E1C432B8   (IME = 1)
        Hmm STRH encoding: cond 000 P=1 U=1 I=1 W=0 L=0 Rn=4 Rd=3 offHi=2 1 SH=01 1 offLo=0
        For offset 0x200: offHi = 0x20 → split into offHi=0x20, offLo=0x0.
          = 1110 000 1 1 1 0 0 Rn=0100 Rd=0011 offHi=0010 1 01 1 offLo=0000
          = 1110 0001 1100 0100 0011 0010 1011 0000 = E1C432B0. ✓
        For offset 0x208: offHi=0x20, offLo=0x8.
          = 1110 0001 1100 0100 0011 0010 1011 1000 = E1C432B8. ✓

      ; Switch to SYS mode with IRQ enabled (CPSR I bit = 0)
      addr 0x02000020:  MOV R5, #0x1F            E3A0501F
      addr 0x02000024:  MSR CPSR_c, R5           E121F005

      ; Main loop: increment ticks, repeat
      addr 0x02000028:  LDR R6, [R1, #0x100]     E5916100
      addr 0x0200002C:  ADD R6, R6, #1           E2866001
      addr 0x02000030:  STR R6, [R1, #0x100]     E5816100
      addr 0x02000034:  B 0x02000028 (-16)       EAFFFFFB
        Branch offset = (target - PC of B - 8) / 4 = ($28 - $34 - 8) / 4 = -20/4 = -5.
        24-bit signed -5 = $FFFFFB.
        Encoding: cond=E 101 L=0 offset = 1110 1010 1111 1111 1111 1111 1111 1011 = EAFFFFFB.

    IRQ handler at $03000200:
      ; Increment vblanks counter
      MOV R7, #0x03000000           E3A07403
      LDR R8, [R7, #0x104]          E5978104
      ADD R8, R8, #1                E2888001
      STR R8, [R7, #0x104]          E5878104
      ; Ack IRQ: write 0 to IF (Phase D simplification per TestIrqMaskAndAck).
      MOV R9, #0x04000000           E3A09403
      MOV R10, #0                   E3A0A000
      STRH R10, [R9, #0x202]        E1C9A2B2
      ; Return: SUBS PC, LR, #4
      SUBS PC, LR, #4               E25EF004
      Encoding SUBS PC, LR, #4: cond=E 00 I=1 op=0010(SUB) S=1 Rn=14 Rd=15 imm12=4
        = 1110 0010 0101 1110 1111 0000 0000 0100 = E25EF004. ✓

    IRQ vector at $00000018 → branch to handler.
      Branch from $18 to $03000200: offset = ($03000200 - $18 - 8) / 4
        = $030001E0 / 4 = $C00078. Top bit of 24-bit not set → positive.
        Encoding: cond=E 101 L=0 offset=$C00078 = EAC00078. Verify bottom-up:
        $C00078 << 2 = $03001E0, + $20 (PC of branch + 8) = $03000200. ✓ }
  { Main program — IE and IME are pre-set by Pascal before CPU runs
    (avoids the halfword-transfer 8-bit-offset limitation that bit our
    first attempt). Program just switches to SYS+IRQs-enabled and
    spin-increments the ticks counter.
      $02000000: MOV R1, #0x03000000      E3A01403  ; counter base
      $02000004: MOV R2, #0               E3A02000
      $02000008: STR R2, [R1, #0x100]     E5812100  ; ticks := 0
      $0200000C: STR R2, [R1, #0x104]     E5812104  ; vblanks := 0
      $02000010: MOV R5, #0x1F            E3A0501F  ; SYS|IRQs-on
      $02000014: MSR CPSR_c, R5           E121F005
      $02000018: LDR R6, [R1, #0x100]     E5916100  ; loop start
      $0200001C: ADD R6, R6, #1           E2866001
      $02000020: STR R6, [R1, #0x100]     E5816100
      $02000024: B -16                    EAFFFFFB  ; offset=-5 → target $18 }
  Prog: array of TWord = (
    $E3A01403, $E3A02000, $E5812100, $E5812104,
    $E3A0501F, $E121F005,
    $E5916100, $E2866001, $E5816100, $EAFFFFFB
  );
  { Handler — load $04000202 (IF address) from a literal pool to dodge
    the 8-bit STRH offset limitation. Phase F update: ACK by writing 1
    to IF bit 0 (real write-1-clear semantic), not 0 (the old Phase D
    BIOS-skip shorthand).
      $03000200: MOV R7, #0x03000000      E3A07403
      $03000204: LDR R8, [R7, #0x104]     E5978104
      $03000208: ADD R8, R8, #1           E2888001
      $0300020C: STR R8, [R7, #0x104]     E5878104
      $03000210: LDR R9, [PC, #8]         E59F9008  ; reads addr $20
      $03000214: MOV R10, #1              E3A0A001  ; ack bit 0 (V-blank)
      $03000218: STRH R10, [R9, #0]       E1C9A0B0
      $0300021C: SUBS PC, LR, #4          E25EF004
      $03000220: literal $04000202 }
  Handler: array of TWord = (
    $E3A07403, $E5978104, $E2888001, $E5878104,
    $E59F9008, $E3A0A001, $E1C9A0B0, $E25EF004,
    $04000202
  );
begin
  Writeln('--- TestVblankIntegration ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  irq := TGbaIrq.Create(mem);
  try
    cpu.SetMemoryHooks(@mem.ReadWord, @mem.ReadHalf, @mem.ReadByte,
                       @mem.CpuWriteWord, @mem.CpuWriteHalf, @mem.CpuWriteByte);
    cpu.SetIrqHook(@irq.Pending);

    { IRQ vector at $18 → LDR PC, [PC, #0] with handler address in
      literal pool at $20. The 24-bit signed branch offset isn't wide
      enough to reach from $18 to $03000200 in one hop, so we use the
      canonical "load PC from adjacent word" trick. BIOS region is
      read-only from the CPU, so we use PokeBiosWord (equivalent to
      LoadBios from a file). }
    mem.PokeBiosWord($18, $E59FF000);     { LDR PC, [PC, #0] }
    mem.PokeBiosWord($20, $03000200);     { literal: handler address }

    { Pre-set IE = $0001 (V-blank enabled) and IME = $0001 directly via
      Pascal, since the CPU code can't reach those addresses in a single
      STRH (offset $200 / $208 exceeds the 8-bit halfword-transfer
      limit). This is the test-harness equivalent of how a real cart
      would set up the registers — the BIOS or the cart's startup code
      uses LDR-from-literal-pool to load the I/O base, but for this
      minimal test we just pre-set them. }
    mem.WriteHalf(REG_IE_ADDR,  $0001);
    mem.WriteHalf(REG_IME_ADDR, $0001);
    { Main program at $02000000. }
    for i := 0 to High(Prog) do
      mem.WriteWord($02000000 + TWord(i) * 4, Prog[i]);
    { Handler at $03000200. }
    for i := 0 to High(Handler) do
      mem.WriteWord($03000200 + TWord(i) * 4, Handler[i]);

    cpu.SetReg(R_PC, $02000000);

    { Run 200 instructions to make sure the main loop is fully spun up. }
    for i := 1 to 200 do cpu.Step;

    { Fire V-blank IRQ. }
    irq.Request(IRQ_VBLANK);

    { Run another 200 instructions — should take the IRQ, run the handler,
      return, continue spinning. }
    for i := 1 to 200 do cpu.Step;

    CheckBool('ticks counter incremented many times',
              True, mem.ReadWord($03000100) > 10);
    CheckEq('vblanks counter = 1 (one IRQ fired and handled)',
            1, mem.ReadWord($03000104));
    CheckBool('main loop resumed after handler (more ticks since IRQ)',
              True, mem.ReadWord($03000100) > 50);

    { Fire another V-blank ; verify the handler runs again. }
    irq.Request(IRQ_VBLANK);
    for i := 1 to 100 do cpu.Step;
    CheckEq('vblanks counter = 2 after second IRQ',
            2, mem.ReadWord($03000104));
  finally
    irq.Free; cpu.Free; mem.Free;
  end;
end;

begin
  Writeln('Phase D acceptance tests');
  Writeln('==========================================');
  Writeln('');
  TestIrqRequest;         Writeln('');
  TestIrqMaskAndAck;      Writeln('');
  TestIrqImeGate;         Writeln('');
  TestIrqIeGate;          Writeln('');
  TestTimer0Overflow;     Writeln('');
  TestTimer0Prescaler;    Writeln('');
  TestCpuTakesIrq;        Writeln('');
  TestVblankIntegration;  Writeln('');
  Writeln('==========================================');
  Writeln(Format('Result: %d pass, %d fail', [PassCount, FailCount]));
  if FailCount > 0 then Halt(1);
end.
