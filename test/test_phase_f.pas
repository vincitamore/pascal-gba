program test_phase_f;
{
  Phase F acceptance tests — DMA controller + cascade timers.

  Coverage:
    DMA-1.  Immediate-mode 32-bit copy.
    DMA-2.  Immediate-mode 16-bit copy.
    DMA-3.  Source decrement walks backwards.
    DMA-4.  Dest fixed parks writes (overlap).
    DMA-5.  Enable bit auto-clears when Repeat=0.
    DMA-6.  IRQ-on-end fires the right IRQ_DMAx source.
    DMA-7.  DMA3 count=0 resolves to 0x10000.
    DMA-8.  DMA0 14-bit count masks high bits.
    DMA-9.  V-blank timing waits for NotifyVBlank.
    DMA-10. Repeat mode keeps channel armed across vblanks; DestCtrl=3
            reloads the dest pointer to DadStart each repeat.
    DMA-11. Software-cancel (enable cleared before fire) drops the arm.

    TMR-1.  T0 cascade into T1 (one T0 overflow = one T1 tick).
    TMR-2.  T0→T1→T2 chain settles in one Step call.

  Build & run:
    fpc -Mobjfpc -Sh -Fusrc -FEbin -FUbin test/test_phase_f.pas
    ./bin/test_phase_f

  Exits non-zero on any failed assertion. Prints a one-line summary at end.
}

{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, Memory, Irq, Timers, Dma;

var
  pass, fail: Integer;

procedure Check(cond: Boolean; const msg: string);
begin
  if cond then
  begin
    Inc(pass);
    Writeln('  ok   ', msg);
  end
  else
  begin
    Inc(fail);
    Writeln('  FAIL ', msg);
  end;
end;

{ Build a small "ROM-image" inside EWRAM at $02000000 for use as DMA
  source data. Returns the base address. }
function SeedSource32(mem: TGbaMemory; words: array of TWord): TWord;
var
  i: Integer;
  base: TWord;
begin
  base := $02000000;
  for i := 0 to High(words) do
    mem.WriteWord(base + TWord(i) * 4, words[i]);
  Result := base;
end;

function SeedSource16(mem: TGbaMemory; halves: array of THalf): TWord;
var
  i: Integer;
  base: TWord;
begin
  base := $02000000;
  for i := 0 to High(halves) do
    mem.WriteHalf(base + TWord(i) * 2, halves[i]);
  Result := base;
end;

procedure ProgramDmaChannel(mem: TGbaMemory; idx: Integer;
  sad, dad: TWord; cntL: THalf; cntH: THalf);
const
  CHAN_STRIDE = $0C;
var
  base: TWord;
begin
  base := $040000B0 + TWord(idx) * CHAN_STRIDE;
  mem.WriteWord(base + $0, sad);
  mem.WriteWord(base + $4, dad);
  mem.WriteHalf(base + $8, cntL);
  mem.WriteHalf(base + $A, cntH);
end;

{ Pack CNT_H bits. }
function MkCntH(srcCtrl, dstCtrl, timing: Integer;
                word32, repeat_, irqOnEnd, enable: Boolean): THalf;
var
  v: THalf;
begin
  v := 0;
  v := v or THalf((dstCtrl and $3) shl 5);
  v := v or THalf((srcCtrl and $3) shl 7);
  if repeat_  then v := v or $0200;
  if word32   then v := v or $0400;
  v := v or THalf((timing and $3) shl 12);
  if irqOnEnd then v := v or $4000;
  if enable   then v := v or $8000;
  Result := v;
end;

{ ───── DMA tests ─────────────────────────────────────────────────── }

procedure TestImmediate32;
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
  src, dst, i: TWord;
begin
  Writeln('DMA-1: immediate-mode 32-bit copy');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    src := SeedSource32(mem, [$11111111, $22222222, $33333333, $44444444]);
    dst := $03000000;
    ProgramDmaChannel(mem, 3, src, dst, 4,
                      MkCntH(DMA_ADDR_INC, DMA_ADDR_INC, DMA_TIMING_IMMEDIATE,
                             True, False, False, True));
    gdma.Step;
    for i := 0 to 3 do
      Check(mem.ReadWord(dst + i * 4) = ($11111111 + i * $11111111),
            Format('  dst[%d] = $%08x', [i, mem.ReadWord(dst + i * 4)]));
    Check(gdma.TransferCount[3] = 1, '  transfer counter bumped');
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

procedure TestImmediate16;
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
  src, dst, i: TWord;
begin
  Writeln('DMA-2: immediate-mode 16-bit copy');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    src := SeedSource16(mem, [$AAAA, $BBBB, $CCCC, $DDDD, $EEEE, $FFFF]);
    dst := $03000000;
    ProgramDmaChannel(mem, 3, src, dst, 6,
                      MkCntH(DMA_ADDR_INC, DMA_ADDR_INC, DMA_TIMING_IMMEDIATE,
                             False, False, False, True));
    gdma.Step;
    for i := 0 to 5 do
      Check(mem.ReadHalf(dst + i * 2) = THalf($AAAA + i * $1111),
            Format('  dst[%d] = $%04x', [i, mem.ReadHalf(dst + i * 2)]));
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

procedure TestSourceDecrement;
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
  src, dst: TWord;
begin
  Writeln('DMA-3: source decrement walks backwards');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    src := SeedSource32(mem, [$AAAA0000, $BBBB0001, $CCCC0002, $DDDD0003]);
    { Start at the LAST word; decrement back to the first. }
    dst := $03000000;
    ProgramDmaChannel(mem, 3, src + 12, dst, 4,
                      MkCntH(DMA_ADDR_DEC, DMA_ADDR_INC, DMA_TIMING_IMMEDIATE,
                             True, False, False, True));
    gdma.Step;
    Check(mem.ReadWord(dst +  0) = $DDDD0003, '  dst[0] = source[3]');
    Check(mem.ReadWord(dst +  4) = $CCCC0002, '  dst[1] = source[2]');
    Check(mem.ReadWord(dst +  8) = $BBBB0001, '  dst[2] = source[1]');
    Check(mem.ReadWord(dst + 12) = $AAAA0000, '  dst[3] = source[0]');
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

procedure TestDestFixed;
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
  src, dst: TWord;
begin
  Writeln('DMA-4: dest fixed (writes overlap at same address)');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    src := SeedSource32(mem, [$11111111, $22222222, $33333333, $44444444]);
    dst := $03000000;
    ProgramDmaChannel(mem, 3, src, dst, 4,
                      MkCntH(DMA_ADDR_INC, DMA_ADDR_FIXED, DMA_TIMING_IMMEDIATE,
                             True, False, False, True));
    gdma.Step;
    { Last write wins because dest doesn't advance. }
    Check(mem.ReadWord(dst) = $44444444, '  dst = final source word');
    Check(mem.ReadWord(dst + 4) = 0, '  dst+4 untouched');
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

procedure TestEnableAutoClears;
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
  cntHAfter: THalf;
begin
  Writeln('DMA-5: enable auto-clears when repeat=0');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    mem.WriteWord($02000000, $DEADBEEF);
    ProgramDmaChannel(mem, 3, $02000000, $03000000, 1,
                      MkCntH(DMA_ADDR_INC, DMA_ADDR_INC, DMA_TIMING_IMMEDIATE,
                             True, False, False, True));
    gdma.Step;
    cntHAfter := mem.ReadHalf($040000DE);
    Check((cntHAfter and $8000) = 0, '  CNT_H bit 15 cleared');
    Check(not gdma.ChannelEnabled(3), '  ChannelEnabled(3) = false');
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

procedure TestIrqOnEnd;
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
  ifVal: THalf;
begin
  Writeln('DMA-6: IRQ-on-end fires IRQ_DMA3');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    { Enable IME + IE bit 11 (DMA3). }
    mem.WriteHalf($04000208, 1);
    mem.WriteHalf($04000200, 1 shl 11);
    mem.WriteWord($02000000, $DEADBEEF);
    ProgramDmaChannel(mem, 3, $02000000, $03000000, 1,
                      MkCntH(DMA_ADDR_INC, DMA_ADDR_INC, DMA_TIMING_IMMEDIATE,
                             True, False, True, True));
    gdma.Step;
    ifVal := mem.ReadHalf($04000202);
    Check((ifVal and (1 shl 11)) <> 0, '  IF bit 11 set');
    Check(irq.Pending, '  Irq.Pending = true');
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

procedure TestDma3CountZero;
{ DMA3 with count=0 should resolve to 0x10000. We verify by checking
  LastTransferLen rather than copying 64K words for real (too slow):
  use source-fixed so the source pointer doesn't blow past EWRAM, copy
  one marker word from $02000000 repeatedly into IWRAM with dest=fixed
  so we don't blow past 32KB. Then check both the transfer count (1) and
  LastTransferLen ($10000). }
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
begin
  Writeln('DMA-7: DMA3 count=0 resolves to 0x10000');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    mem.WriteWord($02000000, $A5A5A5A5);
    ProgramDmaChannel(mem, 3, $02000000, $03000000, 0,
                      MkCntH(DMA_ADDR_FIXED, DMA_ADDR_FIXED, DMA_TIMING_IMMEDIATE,
                             True, False, False, True));
    gdma.Step;
    Check(gdma.LastTransferLen[3] = $10000,
          Format('  LastTransferLen = $%x (want $10000)', [gdma.LastTransferLen[3]]));
    Check(mem.ReadWord($03000000) = $A5A5A5A5, '  dest holds marker');
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

procedure TestDma0Count14Bit;
{ DMA0/1/2 count uses only the low 14 bits of CNT_L. Bits 14-15 are
  ignored. We program CNT_L = $C008 (high bits set, low 14 bits = 8)
  and expect exactly 8 transfers. }
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
  i: Integer;
begin
  Writeln('DMA-8: DMA0 CNT_L high bits ignored (14-bit count)');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    for i := 0 to 7 do
      mem.WriteWord($02000000 + TWord(i) * 4, $DEAD0000 + TWord(i));
    ProgramDmaChannel(mem, 0, $02000000, $03000000, $C008,
                      MkCntH(DMA_ADDR_INC, DMA_ADDR_INC, DMA_TIMING_IMMEDIATE,
                             True, False, False, True));
    gdma.Step;
    Check(gdma.LastTransferLen[0] = 8,
          Format('  LastTransferLen = %d (want 8)', [gdma.LastTransferLen[0]]));
    for i := 0 to 7 do
      Check(mem.ReadWord($03000000 + TWord(i) * 4) = TWord($DEAD0000 + i),
            Format('  dst[%d] = $%08x', [i, mem.ReadWord($03000000 + TWord(i) * 4)]));
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

procedure TestVBlankTiming;
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
begin
  Writeln('DMA-9: V-blank timing waits for NotifyVBlank');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    mem.WriteWord($02000000, $CAFEBABE);
    ProgramDmaChannel(mem, 3, $02000000, $03000000, 1,
                      MkCntH(DMA_ADDR_INC, DMA_ADDR_INC, DMA_TIMING_VBLANK,
                             True, False, False, True));
    gdma.Step;
    Check(mem.ReadWord($03000000) = 0,
          '  dest unchanged before NotifyVBlank');
    Check(gdma.ChannelArmed(3), '  channel armed waiting for vblank');
    gdma.NotifyVBlank;
    Check(mem.ReadWord($03000000) = $CAFEBABE,
          '  dest holds value after NotifyVBlank');
    Check(not gdma.ChannelEnabled(3), '  enable cleared after fire');
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

procedure TestRepeatVBlank;
{ Repeat mode: arm a 2-word vblank-timed transfer with repeat=1. After
  NotifyVBlank #1, channel STAYS armed for #2. DestCtrl=3 (inc+reload)
  means Dad reloads to DadStart each repeat, while Sad continues
  advancing — so the second transfer reads source[2..3] and writes
  them to dst[0..1]. We verify both: (a) channel stayed armed, and
  (b) dst[0] after second transfer equals the source's third word
  (proves dst reloaded AND src kept advancing). }
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
begin
  Writeln('DMA-10: repeat mode rearms across vblanks; DestCtrl=3 reloads dst, src advances');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    { Seed four source words so both transfers can read fresh data. }
    mem.WriteWord($02000000, $01010101);
    mem.WriteWord($02000004, $02020202);
    mem.WriteWord($02000008, $03030303);
    mem.WriteWord($0200000C, $04040404);
    ProgramDmaChannel(mem, 3, $02000000, $03000000, 2,
                      MkCntH(DMA_ADDR_INC, DMA_ADDR_INC_RELOAD,
                             DMA_TIMING_VBLANK, True, True, False, True));
    gdma.Step;
    Check(gdma.ChannelArmed(3), '  armed for first vblank');

    gdma.NotifyVBlank;
    Check(gdma.TransferCount[3] = 1, '  first transfer ran');
    Check(mem.ReadWord($03000000) = $01010101, '  dst[0] = source[0]');
    Check(mem.ReadWord($03000004) = $02020202, '  dst[1] = source[1]');
    Check(gdma.ChannelArmed(3), '  STILL armed after first transfer');

    { Overwrite dest marker to detect the second fire. }
    mem.WriteWord($03000000, $DEADDEAD);
    mem.WriteWord($03000004, $DEADDEAD);

    gdma.NotifyVBlank;
    Check(gdma.TransferCount[3] = 2, '  second transfer ran');
    Check(mem.ReadWord($03000000) = $03030303,
          '  dst reloaded to DadStart and second-pass writes there (source[2])');
    Check(mem.ReadWord($03000004) = $04040404,
          '  dst+4 = source[3] (src kept advancing across repeats)');
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

procedure TestSoftwareCancel;
var
  mem: TGbaMemory; irq: TGbaIrq; gdma: TGbaDma;
  cntH: THalf;
begin
  Writeln('DMA-11: software-cancel before fire drops the arm');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  gdma := TGbaDma.Create(mem, irq);
  try
    mem.WriteWord($02000000, $DEADBEEF);
    ProgramDmaChannel(mem, 3, $02000000, $03000000, 1,
                      MkCntH(DMA_ADDR_INC, DMA_ADDR_INC, DMA_TIMING_VBLANK,
                             True, False, False, True));
    gdma.Step;
    Check(gdma.ChannelArmed(3), '  armed first');

    { CPU clears enable bit before vblank fires. }
    cntH := mem.ReadHalf($040000DE);
    mem.WriteHalf($040000DE, cntH and not THalf($8000));
    gdma.Step;
    Check(not gdma.ChannelArmed(3), '  disarmed after enable clear');

    gdma.NotifyVBlank;
    Check(mem.ReadWord($03000000) = 0, '  no transfer happened');
    Check(gdma.TransferCount[3] = 0, '  TransferCount stayed at 0');
  finally
    gdma.Free; irq.Free; mem.Free;
  end;
end;

{ ───── Cascade timer tests ────────────────────────────────────────── }

procedure ProgramTimer(mem: TGbaMemory; idx: Integer;
                      reload: THalf; cntH: THalf);
var
  base: TWord;
begin
  base := $04000100 + TWord(idx) * 4;
  mem.WriteHalf(base + 0, reload);
  mem.WriteHalf(base + 2, cntH);
end;

procedure TestCascadeT0IntoT1;
{ T0 reload=$FFFC (4 cycles to overflow), no cascade.
  T1 cascade=1, reload=0.
  After T0 overflows N times in one Step, T1 counter should be N. }
var
  mem: TGbaMemory; irq: TGbaIrq; tmrs: TGbaTimers;
  t1Counter: THalf;
begin
  Writeln('TMR-1: T0 cascade into T1');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  tmrs := TGbaTimers.Create(mem, irq);
  try
    { T0: prescaler=1 (bits 0-0=0), enable=1.
      reload = $FFFC → overflows after 4 ticks. }
    ProgramTimer(mem, 0, $FFFC, $0080);
    { T1: cascade=1 (bit 2), enable=1, no prescaler effect. }
    ProgramTimer(mem, 1, $0000, $0084);

    { Step with 16 cpu cycles → T0 overflows 4 times (4 cycles each). }
    tmrs.Step(16);
    t1Counter := mem.ReadHalf($04000104);
    Check(t1Counter = 4,
          Format('  T1 counter = %d (want 4)', [t1Counter]));
  finally
    tmrs.Free; irq.Free; mem.Free;
  end;
end;

procedure TestCascadeChainT0T1T2;
{ T0 fast (reload=$FFFE, 2 cycles per overflow). T1 cascade reload=$FFFC
  (overflows every 4 T0 overflows). T2 cascade reload=0 (each T1
  overflow advances T2 by 1).
  Step with 64 cycles → T0 overflows 32 times → T1 advances 32 from
  $FFFC, overflowing once per 4 T1 ticks → T1 overflows 8 times → T2 = 8. }
var
  mem: TGbaMemory; irq: TGbaIrq; tmrs: TGbaTimers;
  t2Counter: THalf;
begin
  Writeln('TMR-2: T0→T1→T2 cascade chain settles in one Step');
  mem := TGbaMemory.Create; irq := TGbaIrq.Create(mem);
  tmrs := TGbaTimers.Create(mem, irq);
  try
    ProgramTimer(mem, 0, $FFFE, $0080);
    ProgramTimer(mem, 1, $FFFC, $0084);
    ProgramTimer(mem, 2, $0000, $0084);

    tmrs.Step(64);

    t2Counter := mem.ReadHalf($04000108);
    Check(t2Counter = 8,
          Format('  T2 counter = %d (want 8)', [t2Counter]));
  finally
    tmrs.Free; irq.Free; mem.Free;
  end;
end;

begin
  pass := 0; fail := 0;
  Writeln('=== Phase F acceptance tests ===');

  TestImmediate32;
  TestImmediate16;
  TestSourceDecrement;
  TestDestFixed;
  TestEnableAutoClears;
  TestIrqOnEnd;
  TestDma3CountZero;
  TestDma0Count14Bit;
  TestVBlankTiming;
  TestRepeatVBlank;
  TestSoftwareCancel;

  TestCascadeT0IntoT1;
  TestCascadeChainT0T1T2;

  Writeln;
  Writeln(Format('=== Phase F summary: %d passed, %d failed ===', [pass, fail]));
  if fail > 0 then Halt(1);
end.
