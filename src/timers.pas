unit Timers;
{
  GBA timers — four 16-bit countup timers (T0..T3). Phase D ships T0
  fully; T1..T3 are scaffolded but cascading is deferred to Phase F.

  ── Per-timer registers ──

    TMxCNT_L  $04000100 + x*4   16-bit
                                  on read:  current counter value
                                  on write: latched reload value
                                            (NOT the counter — see note)
    TMxCNT_H  $04000102 + x*4   16-bit  control
        bits 1:0  prescaler:  00 = 1, 01 = 64, 02 = 256, 03 = 1024
        bit 2     cascade (T1-3 only — chain with previous timer overflow)
        bit 6     IRQ on overflow enable
        bit 7     timer enable

  ── Reload semantics ──

  Writing to TMxCNT_L doesn't change the live counter — it sets the
  reload value. The counter resets to the reload value when:
    (a) the timer is enabled (bit 7 of CNT_H transitions 0→1), OR
    (b) the timer overflows from $FFFF + 1.

  Because the memory subsystem stores L/H in flat I/O memory, we read
  the latched values back from memory each tick. We can't reliably
  observe "the write happened" vs "the bytes have these values now" —
  so we treat the H register's bit 7 transitioning to 1 (since last
  tick) as the "enable" event that latches the reload value into the
  live counter.

  ── Stepping ──

  Each call to `Step(cpuCycles)` advances every enabled timer by the
  given number of CPU cycles. Per timer: maintain an accumulator;
  when accumulator ≥ prescaler, decrement accumulator by prescaler,
  increment counter. If counter exceeds $FFFF, reload and fire IRQ.

  Phase D approximation: our CPU does 1 cycle per instruction, so
  the main loop should pass instruction-count as cpuCycles. This is
  not cycle-accurate but is close enough for V-blank/H-blank timing
  on commercial titles under test.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes, Memory, Irq;

type
  TTimerSlot = record
    Counter:   TWord;       { live 16-bit value (held as 32-bit for headroom) }
    Reload:    TWord;       { latched on enable / on overflow }
    Prescaler: Integer;     { 1, 64, 256, or 1024 }
    Accum:     TWord;       { cycles since last increment }
    Enabled:   Boolean;
    Cascade:   Boolean;     { T1-3 only — defer }
    IrqEnable: Boolean;
    PrevH:     THalf;       { last-seen TMxCNT_H — for enable-edge detection }
  end;

  TTimerOverflowHook = procedure(timerIdx: Integer) of object;

  TGbaTimers = class
  private
    FMem:    TGbaMemory;
    FIrq:    TGbaIrq;
    FSlots:  array[0..3] of TTimerSlot;
    FOnOverflow: TTimerOverflowHook;
    procedure ReadAndLatch(idx: Integer);
    procedure WriteBackCounter(idx: Integer);
  public
    constructor Create(mem: TGbaMemory; irq: TGbaIrq);

    { Advance all enabled timers by `cpuCycles` CPU clock cycles. }
    procedure Step(cpuCycles: Integer);

    { Register a callback that fires every time a timer overflows.
      The APU uses this to drive Direct-Sound FIFO pops at the
      timer-overflow rate (per gbatek + the bit-accurate APU model). }
    procedure SetOverflowHook(hook: TTimerOverflowHook);

    { Accessors for the LATCHED reload + prescaler state. Needed by
      the APU because TGbaTimers writes the live counter back to
      CNT_L every Step (a Phase D approximation that lets the CPU
      read the current counter), which destroys the programmed
      reload value in memory. The "true" reload lives in FSlots[i]
      and is exposed here. }
    function GetReload(idx: Integer): Integer;
    function GetPrescaler(idx: Integer): Integer;
    function IsEnabled(idx: Integer): Boolean;
  end;

implementation

constructor TGbaTimers.Create(mem: TGbaMemory; irq: TGbaIrq);
var
  i: Integer;
begin
  inherited Create;
  FMem := mem;
  FIrq := irq;
  for i := 0 to 3 do
  begin
    FSlots[i].Counter   := 0;
    FSlots[i].Reload    := 0;
    FSlots[i].Prescaler := 1;
    FSlots[i].Accum     := 0;
    FSlots[i].Enabled   := False;
    FSlots[i].Cascade   := False;
    FSlots[i].IrqEnable := False;
    FSlots[i].PrevH     := 0;
  end;
end;

procedure TGbaTimers.ReadAndLatch(idx: Integer);
{ Read the current TMxCNT_H and TMxCNT_L from memory. Latch any state
  changes that occurred via direct memory writes from the CPU.

  Specifically:
    - If H's enable bit transitioned 0→1, latch L (the reload value)
      into our live counter.
    - Update prescaler / IRQ-enable / enabled from H.
    - The L register is always treated as "reload value" on write
      (the CPU never directly writes the live counter — it reads it).
      We store the L as the reload field. Our counter writeback in
      WriteBackCounter overwrites L with the live counter so the CPU
      sees the current value on read — but that loses the programmed
      reload value. Pragmatic fix: keep a shadow of the last-written
      reload value here too, refreshed when the CPU clearly wrote a
      new reload (which we can't detect mid-frame; we treat the
      0→1 enable transition as the "use the current L value as
      reload" moment).

  This is imperfect — a real implementation would have memory hooks
  for the timer registers. Phase D ships this simplification and
  flags the rough edge for Phase F's cleanup. }
var
  hAddr, lAddr: TWord;
  h, lVal: THalf;
  wasEnabled, nowEnabled: Boolean;
  pre: Integer;
begin
  hAddr := $04000102 + TWord(idx) * 4;
  lAddr := $04000100 + TWord(idx) * 4;
  h := FMem.ReadHalf(hAddr);
  lVal := FMem.ReadHalf(lAddr);

  wasEnabled := FSlots[idx].Enabled;
  nowEnabled := ((h shr 7) and 1) = 1;

  if nowEnabled and (not wasEnabled) then
  begin
    { Enable edge — latch reload from current L and reset counter. }
    FSlots[idx].Reload   := TWord(lVal);
    FSlots[idx].Counter  := TWord(lVal);
    FSlots[idx].Accum    := 0;
  end;

  FSlots[idx].Enabled   := nowEnabled;
  FSlots[idx].IrqEnable := ((h shr 6) and 1) = 1;
  FSlots[idx].Cascade   := ((h shr 2) and 1) = 1;
  case h and $3 of
    0: pre := 1;
    1: pre := 64;
    2: pre := 256;
    3: pre := 1024;
  else
    pre := 1;
  end;
  FSlots[idx].Prescaler := pre;
  FSlots[idx].PrevH     := h;
end;

procedure TGbaTimers.WriteBackCounter(idx: Integer);
begin
  FMem.WriteHalf($04000100 + TWord(idx) * 4, THalf(FSlots[idx].Counter and $FFFF));
end;

procedure TGbaTimers.Step(cpuCycles: Integer);
{ Phase F: cascade implemented. T1-T3 with cascade=1 advance by one tick
  per overflow of the immediately-previous timer, ignoring cpuCycles and
  prescaler entirely. The previous-timer's overflow count is the cascading
  timer's "clock source." Process timers in order 0→1→2→3 so a chain of
  cascades all settles in one Step call. }
var
  i, irqBit: Integer;
  overflows: array[0..3] of Integer;
  ticks: Integer;
begin
  for i := 0 to 3 do overflows[i] := 0;

  for i := 0 to 3 do
  begin
    ReadAndLatch(i);
    if not FSlots[i].Enabled then Continue;

    if (i > 0) and FSlots[i].Cascade then
    begin
      { Cascade — advance by one tick per overflow of timer (i-1). The
        prescaler bits are ignored in cascade mode per gbatek. }
      ticks := overflows[i - 1];
      while ticks > 0 do
      begin
        Inc(FSlots[i].Counter);
        Dec(ticks);
        if FSlots[i].Counter > $FFFF then
        begin
          FSlots[i].Counter := FSlots[i].Reload;
          overflows[i] := overflows[i] + 1;
          if FSlots[i].IrqEnable then
          begin
            irqBit := IRQ_TIMER0 + i;
            FIrq.Request(irqBit);
          end;
          { Notify APU (or any subscriber) of the overflow — this is
            what drives Direct-Sound FIFO pops in the bit-accurate
            model. Per gbatek + mGBA/NBA: each timer overflow pops one
            byte from each FIFO whose timer-select bit in SOUNDCNT_H
            matches this timer index. }
          if Assigned(FOnOverflow) then FOnOverflow(i);
        end;
      end;
    end
    else
    begin
      { Free-running — step by cpuCycles / prescaler. }
      Inc(FSlots[i].Accum, cpuCycles);
      while FSlots[i].Accum >= TWord(FSlots[i].Prescaler) do
      begin
        FSlots[i].Accum := FSlots[i].Accum - TWord(FSlots[i].Prescaler);
        Inc(FSlots[i].Counter);
        if FSlots[i].Counter > $FFFF then
        begin
          FSlots[i].Counter := FSlots[i].Reload;
          overflows[i] := overflows[i] + 1;
          if FSlots[i].IrqEnable then
          begin
            irqBit := IRQ_TIMER0 + i;
            FIrq.Request(irqBit);
          end;
          { Notify APU (or any subscriber) of the overflow — this is
            what drives Direct-Sound FIFO pops in the bit-accurate
            model. Per gbatek + mGBA/NBA: each timer overflow pops one
            byte from each FIFO whose timer-select bit in SOUNDCNT_H
            matches this timer index. }
          if Assigned(FOnOverflow) then FOnOverflow(i);
        end;
      end;
    end;

    WriteBackCounter(i);
  end;
end;

procedure TGbaTimers.SetOverflowHook(hook: TTimerOverflowHook);
begin
  FOnOverflow := hook;
end;

function TGbaTimers.GetReload(idx: Integer): Integer;
begin
  if (idx < 0) or (idx > 3) then Exit(0);
  Result := FSlots[idx].Reload;
end;

function TGbaTimers.GetPrescaler(idx: Integer): Integer;
begin
  if (idx < 0) or (idx > 3) then Exit(1);
  Result := FSlots[idx].Prescaler;
end;

function TGbaTimers.IsEnabled(idx: Integer): Boolean;
begin
  if (idx < 0) or (idx > 3) then Exit(False);
  Result := FSlots[idx].Enabled;
end;

end.
