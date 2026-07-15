unit Dma;
{
  GBA DMA controller — 4 channels (DMA0..DMA3), three core timing modes
  (immediate / V-blank / H-blank) plus channel-specific "special" timing
  (sound FIFO for DMA1/2, video capture for DMA3, prohibited for DMA0).

  ── Register layout ──

  Each channel has four registers occupying a 12-byte block:
    base+$0   SAD     32-bit  source address      (write-only on real HW)
    base+$4   DAD     32-bit  destination address (write-only on real HW)
    base+$8   CNT_L   16-bit  transfer count
    base+$A   CNT_H   16-bit  control flags       (read/write)

  Channel bases:
    DMA0: $040000B0
    DMA1: $040000BC
    DMA2: $040000C8
    DMA3: $040000D4

  CNT_H bit layout (per gbatek):
    5-6   Dest address control  (0=inc, 1=dec, 2=fixed, 3=inc+reload-on-repeat)
    7-8   Source address control (0=inc, 1=dec, 2=fixed, 3=prohibited)
    9     Repeat flag
    10    Word size              (0=16-bit, 1=32-bit)
    11    DMA3 game-pak DRQ      (unused in commercial ROMs)
    12-13 Timing                 (0=immediate, 1=vblank, 2=hblank, 3=special)
    14    IRQ on end
    15    Enable

  ── Count resolution ──

    DMA0/1/2: count uses 14 low bits of CNT_L; 0 → 0x4000.
    DMA3:     full 16 bits;                    0 → 0x10000.

  ── Polling-based edge detection ──

  Memory doesn't have per-register write hooks (Phase B simplification —
  same compromise that drives the shadow-and-reconcile pattern in Irq and
  Timers). TGbaDma polls all four channels' CNT_H each call to Step. Each
  channel remembers the last-observed bit-15 state. A 0→1 transition
  triggers:
    1. Decode control bits (src/dst ctrl, repeat, word size, timing, IRQ).
    2. Latch SAD/DAD/CNT_L from the I/O array into the channel's internal
       active state (so subsequent CPU writes to those registers don't
       perturb the in-flight transfer).
    3. If timing=immediate, execute the transfer now.
    4. Otherwise mark the channel "armed" — TGbaDma waits for the matching
       NotifyVBlank / NotifyHBlank call.

  Step is called from the main loop after each scanline (post Timers.Step).
  A commercial title's boot path triggers DMA3 immediate-mode once early
  to copy the IRQ handler from ROM → IWRAM at $03000718; scanline-end
  polling catches that within ~280 CPU cycles of the enable write, which
  is invisible to the CPU (immediate-mode DMA halts the CPU on real
  hardware, so games never observe mid-transfer state).

  ── CPU-halt approximation ──

  Real hardware halts the CPU for the duration of immediate-mode DMA. We
  don't model the halt — the transfer appears instantaneous from the CPU's
  perspective (just delayed by up to one scanline). For commercial well-
  behaved games this is invisible. If a future ROM races against in-flight
  DMA, switch the main loop to poll per cpu.Step instead of per scanline.

  ── Address increment ──

  Per word transferred, source and dest addresses advance by:
    Word32=true  →  +4 / -4 / 0
    Word32=false →  +2 / -2 / 0
  controlled by the SrcCtrl / DestCtrl bit fields. SrcCtrl=3 is "prohibited"
  per gbatek — we treat it as fixed (safest interpretation; the alternative
  is increment which could run amok if a game accidentally encodes 3).

  ── Repeat semantics ──

  On Repeat=1, after transfer the channel stays armed. When the next timing
  trigger fires (vblank/hblank/special), the transfer repeats with:
    - Count reloaded from CountStart (the latched-at-enable count).
    - DadStart reloaded into Dad iff DestCtrl=3 (inc+reload). Otherwise Dad
      continues from where the last transfer left off.
    - Sad continues — real hardware never reloads source.
    - Enable bit stays set.
  On Repeat=0, the enable bit auto-clears at end of transfer and the channel
  disarms.

  ── IRQ on end ──

  If CNT_H bit 14 is set, completion of a transfer (each transfer for
  repeat-mode, the single transfer for one-shot) fires IRQ_DMA0..DMA3 via
  the standard Irq.Request path. The IRQ handler is responsible for ack
  (write-1-clear to IF) like any other source.

  ── Phase F status (2026-05-18) ──

    [x] All 4 channels structurally present.
    [x] Immediate / V-blank / H-blank timing modes.
    [x] Repeat handling with inc+reload dest control.
    [x] IRQ on end firing the right IRQ_DMA0..3 source.
    [x] 14-bit vs 16-bit count resolution per channel.
    [ ] Special timing (sound FIFO for DMA1/2, video capture for DMA3) —
        stubbed; Phase G (APU) fills sound FIFO.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes, Memory, Irq;

const
  DMA_BASE        = $040000B0;
  DMA_CHAN_STRIDE = $0C;            { 12 bytes between channels }

  DMA_TIMING_IMMEDIATE = 0;
  DMA_TIMING_VBLANK    = 1;
  DMA_TIMING_HBLANK    = 2;
  DMA_TIMING_SPECIAL   = 3;

  DMA_ADDR_INC        = 0;
  DMA_ADDR_DEC        = 1;
  DMA_ADDR_FIXED      = 2;
  DMA_ADDR_INC_RELOAD = 3;          { dest control only — invalid for src }

type
  TDmaChannel = record
    { Live transfer state — advances during ExecuteTransfer. }
    Sad:        TWord;
    Dad:        TWord;
    Count:      TWord;

    { Latched-at-enable state — used by repeat-mode reload (tracker
      base-vs-current pattern: modulator's center stays at the
      enable-time values; the live fields swing around them). }
    SadStart:   TWord;
    DadStart:   TWord;
    CountStart: TWord;

    { Decoded control bits — captured at enable-edge. }
    SrcCtrl:    Integer;
    DestCtrl:   Integer;
    Repeat_:    Boolean;
    Word32:     Boolean;
    Timing:     Integer;
    IrqOnEnd:   Boolean;

    Enabled:    Boolean;            { our reading of CNT_H bit 15 }
    Armed:      Boolean;            { latched, waiting for trigger }
  end;

  TGbaDma = class
  private
    FMem:  TGbaMemory;
    FIrq:  TGbaIrq;
    FChan: array[0..3] of TDmaChannel;

    function  ChanBase(idx: Integer): TWord; inline;
    procedure Latch(idx: Integer);
    procedure Disable(idx: Integer);
    procedure FireIrqIfWanted(idx: Integer);
    procedure ExecuteTransfer(idx: Integer);
    procedure CheckChannelEdge(idx: Integer);
    procedure CheckTimingTrigger(idx: Integer; trigger: Integer);
  public
    constructor Create(mem: TGbaMemory; irq: TGbaIrq);

    { Polled per scanline. Detects 0→1 enable edges on all 4 channels'
      CNT_H. Immediate-timing transfers run inside this call. }
    procedure Step;

    { Timing-trigger entry points called by the scheduler at the
      appropriate moments. Each fires any armed channel whose timing
      matches. }
    procedure NotifyVBlank;
    procedure NotifyHBlank;

    { Sound-FIFO refill: fires armed channels with timing=special
      (3) whose destination address matches FIFO A ($040000A0) or
      FIFO B ($040000A4). Phase G wiring — TGbaApu invokes these
      when its FIFO drops to <= half capacity. }
    procedure NotifyFifoA;
    procedure NotifyFifoB;

    { Memory hook entry point — fires whenever the CPU writes a byte
      that overlaps any DMA channel's CNT_H halfword. Equivalent to
      a per-write CheckChannelEdge for that one channel, but only
      triggered by actual writes (zero cost otherwise). Wire via
      mem.SetDmaControlHook(@dma.OnControlWrite). }
    procedure OnControlWrite(channelIdx: Integer);

    { Read-only inspection helpers for tests / debugging. }
    function ChannelEnabled(idx: Integer): Boolean;
    function ChannelArmed(idx: Integer):   Boolean;
    function ChannelTiming(idx: Integer):  Integer;
  public
    { Diagnostic counters — bumped on every completed transfer, useful for
      tests and commercial-title boot harnesses. Public for direct
      inspection (same pattern as TGbaMemory's FirstUnmappedAddr).
      Separate visibility block because Pascal requires fields to
      precede methods within a single block. }
    TransferCount:    array[0..3] of Int64;
    LastTransferSad:  array[0..3] of TWord;
    LastTransferDad:  array[0..3] of TWord;
    LastTransferLen:  array[0..3] of TWord;

    { Forensic: number of 0\u21921 enable-edge events ("re-arms") observed
      per channel, and the distinct SAD values latched. Used to diagnose
      whether the game's audio engine is re-arming DMA each buffer cycle
      or relying on auto-mechanisms we don't emulate. }
    EnableEdgeCount: array[0..3] of Int64;
    DistinctSadCount: array[0..3] of Integer;
    DistinctSads: array[0..3, 0..15] of TWord;
  end;

implementation

constructor TGbaDma.Create(mem: TGbaMemory; irq: TGbaIrq);
var
  i: Integer;
begin
  inherited Create;
  FMem := mem;
  FIrq := irq;
  for i := 0 to 3 do
  begin
    FillChar(FChan[i], SizeOf(FChan[i]), 0);
    TransferCount[i]    := 0;
    LastTransferSad[i]  := 0;
    LastTransferDad[i]  := 0;
    LastTransferLen[i]  := 0;
    EnableEdgeCount[i]  := 0;
    DistinctSadCount[i] := 0;
  end;
end;

function TGbaDma.ChanBase(idx: Integer): TWord; inline;
begin
  Result := DMA_BASE + TWord(idx) * DMA_CHAN_STRIDE;
end;

procedure TGbaDma.Latch(idx: Integer);
{ Capture SAD/DAD/CNT_L from the flat I/O array into the channel's active
  state. Called once per enable-edge. }
var
  base: TWord;
  cntL: THalf;
  c:    TWord;
begin
  base := ChanBase(idx);
  FChan[idx].Sad := FMem.ReadWord(base + $0);
  FChan[idx].Dad := FMem.ReadWord(base + $4);
  cntL          := FMem.ReadHalf(base + $8);

  if idx = 3 then
  begin
    { DMA3: full 16-bit count, 0 → 0x10000. }
    c := TWord(cntL);
    if c = 0 then c := $10000;
  end
  else
  begin
    { DMA0/1/2: 14-bit count, 0 → 0x4000. }
    c := TWord(cntL) and $3FFF;
    if c = 0 then c := $4000;
  end;

  FChan[idx].Count      := c;
  FChan[idx].CountStart := c;
  FChan[idx].SadStart   := FChan[idx].Sad;
  FChan[idx].DadStart   := FChan[idx].Dad;
end;

function IsSoundFifoDma(idx: Integer; dadStart: TWord; timing: Integer): Boolean;
{ Sound-FIFO DMA = DMA1 or DMA2 with timing=3 (special) AND
  destination = $040000A0 (FIFO A) or $040000A4 (FIFO B). On real
  hardware these transfers ignore CNT_L and always move exactly 4
  32-bit words; the destination is held fixed (FIFO push semantics). }
begin
  Result := ((idx = 1) or (idx = 2)) and (timing = DMA_TIMING_SPECIAL)
            and ((dadStart = $040000A0) or (dadStart = $040000A4));
end;

procedure TGbaDma.Disable(idx: Integer);
{ Clear the enable bit in CNT_H to signal the CPU that the transfer is
  done. Also clear our internal Armed/Enabled flags. }
var
  cntH: THalf;
  base: TWord;
begin
  base := ChanBase(idx);
  cntH := FMem.ReadHalf(base + $A);
  cntH := cntH and not THalf($8000);
  FMem.WriteHalf(base + $A, cntH);
  FChan[idx].Enabled := False;
  FChan[idx].Armed   := False;
end;

procedure TGbaDma.FireIrqIfWanted(idx: Integer);
begin
  if FChan[idx].IrqOnEnd then
    FIrq.Request(IRQ_DMA0 + idx);
end;

procedure TGbaDma.ExecuteTransfer(idx: Integer);
{ Perform the word-by-word copy. Source and dest advance per Ctrl bits;
  SrcCtrl=3 (prohibited per gbatek) is treated as fixed.

  Local `unitBytes` is the per-word address-stride (2 for halfword, 4 for
  word) — named to avoid collision with the class method TGbaDma.Step. }
var
  unitBytes: Integer;
  srcInc:    Integer;
  dstInc:    Integer;
  s, d:      TWord;
  i, n:      TWord;
  v32:       TWord;
  v16:       THalf;
begin
  if FChan[idx].Word32 then unitBytes := 4 else unitBytes := 2;

  case FChan[idx].SrcCtrl of
    DMA_ADDR_INC:   srcInc :=  unitBytes;
    DMA_ADDR_DEC:   srcInc := -unitBytes;
    DMA_ADDR_FIXED: srcInc :=  0;
  else
    srcInc := 0;       { SrcCtrl=3 prohibited → fixed }
  end;
  case FChan[idx].DestCtrl of
    DMA_ADDR_INC,
    DMA_ADDR_INC_RELOAD: dstInc :=  unitBytes;
    DMA_ADDR_DEC:        dstInc := -unitBytes;
    DMA_ADDR_FIXED:      dstInc :=  0;
  else
    dstInc := 0;
  end;

  s := FChan[idx].Sad;
  d := FChan[idx].Dad;
  n := FChan[idx].Count;

  if FChan[idx].Word32 then
  begin
    i := 0;
    while i < n do
    begin
      v32 := FMem.ReadWord(s);
      FMem.WriteWord(d, v32);
      s := TWord(Int64(s) + srcInc);
      d := TWord(Int64(d) + dstInc);
      Inc(i);
    end;
  end
  else
  begin
    i := 0;
    while i < n do
    begin
      v16 := FMem.ReadHalf(s);
      FMem.WriteHalf(d, v16);
      s := TWord(Int64(s) + srcInc);
      d := TWord(Int64(d) + dstInc);
      Inc(i);
    end;
  end;

  FChan[idx].Sad := s;
  FChan[idx].Dad := d;

  Inc(TransferCount[idx]);
  LastTransferSad[idx] := FChan[idx].SadStart;
  LastTransferDad[idx] := FChan[idx].DadStart;
  LastTransferLen[idx] := FChan[idx].CountStart;

  FireIrqIfWanted(idx);

  if FChan[idx].Repeat_ then
  begin
    { Repeat mode — channel stays armed for the next timing trigger.
      Count reloads from the latched start value; dest reloads only if
      DestCtrl is inc+reload (3). Source never reloads. }
    if FChan[idx].DestCtrl = DMA_ADDR_INC_RELOAD then
      FChan[idx].Dad := FChan[idx].DadStart;
    FChan[idx].Count := FChan[idx].CountStart;
    { Armed stays true. }
  end
  else
    Disable(idx);
end;

procedure TGbaDma.CheckChannelEdge(idx: Integer);
{ Read the current CNT_H. If bit 15 transitioned 0→1 since last poll,
  latch the channel and (if timing=immediate) execute now. If bit 15
  transitioned 1→0, the CPU disarmed a non-immediate channel before it
  fired — drop the arm. }
var
  base:  TWord;
  cntH:  THalf;
  wasEn: Boolean;
  nowEn: Boolean;
  k:     Integer;
  seen:  Boolean;
begin
  base := ChanBase(idx);
  cntH := FMem.ReadHalf(base + $A);

  wasEn := FChan[idx].Enabled;
  nowEn := (cntH and $8000) <> 0;

  if nowEn and (not wasEn) then
  begin
    FChan[idx].DestCtrl := (cntH shr 5) and $3;
    FChan[idx].SrcCtrl  := (cntH shr 7) and $3;
    FChan[idx].Repeat_  := (cntH and $0200) <> 0;
    FChan[idx].Word32   := (cntH and $0400) <> 0;
    FChan[idx].Timing   := (cntH shr 12) and $3;
    FChan[idx].IrqOnEnd := (cntH and $4000) <> 0;
    FChan[idx].Enabled  := True;
    FChan[idx].Armed    := True;

    Latch(idx);

    { Forensic: count enable-edges; accumulate distinct SAD values. }
    Inc(EnableEdgeCount[idx]);
    seen := False;
    for k := 0 to DistinctSadCount[idx] - 1 do
      if DistinctSads[idx, k] = FChan[idx].Sad then begin seen := True; Break; end;
    if (not seen) and (DistinctSadCount[idx] < 16) then
    begin
      DistinctSads[idx, DistinctSadCount[idx]] := FChan[idx].Sad;
      Inc(DistinctSadCount[idx]);
    end;

    { Sound-FIFO DMA overrides: real hardware ignores CNT_L (always 4
      32-bit words = 16 bytes), forces word-size to 32-bit, and pins
      the destination address. Games sometimes leave CNT_L at garbage
      values; without this override we'd transfer 16384+ samples per
      trigger and overrun the FIFO immediately. }
    if IsSoundFifoDma(idx, FChan[idx].DadStart, FChan[idx].Timing) then
    begin
      FChan[idx].Count      := 4;
      FChan[idx].CountStart := 4;
      FChan[idx].Word32     := True;
      FChan[idx].DestCtrl   := DMA_ADDR_FIXED;
    end;

    if FChan[idx].Timing = DMA_TIMING_IMMEDIATE then
      ExecuteTransfer(idx);
  end
  else if (not nowEn) and wasEn then
  begin
    { Software-cancelled — disarm. }
    FChan[idx].Enabled := False;
    FChan[idx].Armed   := False;
  end;
end;

procedure TGbaDma.CheckTimingTrigger(idx: Integer; trigger: Integer);
begin
  if FChan[idx].Armed and (FChan[idx].Timing = trigger) then
    ExecuteTransfer(idx);
end;

procedure TGbaDma.Step;
var
  i: Integer;
begin
  for i := 0 to 3 do
    CheckChannelEdge(i);
end;

procedure TGbaDma.NotifyVBlank;
var
  i: Integer;
begin
  for i := 0 to 3 do
    CheckTimingTrigger(i, DMA_TIMING_VBLANK);
end;

procedure TGbaDma.NotifyHBlank;
var
  i: Integer;
begin
  for i := 0 to 3 do
    CheckTimingTrigger(i, DMA_TIMING_HBLANK);
end;

procedure TGbaDma.NotifyFifoA;
var
  i: Integer;
begin
  { Sound FIFO transfers are timing=3 (special) on DMA1 / DMA2 with
    dest = $040000A0. Walk all armed channels matching that pattern. }
  for i := 1 to 2 do
    if FChan[i].Armed and (FChan[i].Timing = DMA_TIMING_SPECIAL)
       and (FChan[i].DadStart = $040000A0) then
      ExecuteTransfer(i);
end;

procedure TGbaDma.NotifyFifoB;
var
  i: Integer;
begin
  for i := 1 to 2 do
    if FChan[i].Armed and (FChan[i].Timing = DMA_TIMING_SPECIAL)
       and (FChan[i].DadStart = $040000A4) then
      ExecuteTransfer(i);
end;

function TGbaDma.ChannelEnabled(idx: Integer): Boolean;
begin
  Result := FChan[idx].Enabled;
end;

function TGbaDma.ChannelArmed(idx: Integer): Boolean;
begin
  Result := FChan[idx].Armed;
end;

function TGbaDma.ChannelTiming(idx: Integer): Integer;
begin
  Result := FChan[idx].Timing;
end;

procedure TGbaDma.OnControlWrite(channelIdx: Integer);
begin
  if (channelIdx < 0) or (channelIdx > 3) then Exit;
  CheckChannelEdge(channelIdx);
end;

end.
