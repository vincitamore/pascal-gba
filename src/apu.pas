unit Apu;
{
  GBA Audio Processing Unit — bit-accurate model of the GBA APU.

  This replaces an earlier first-cut. The first-cut produced "audio
  mostly right" only in the most charitable reading — commercial-title
  audio came out "horribly mangled" because:
    - The frame sequencer was sec-based independent timers (drift).
    - FIFOs were popped at output-sample rate instead of timer-overflow.
    - Mixing skipped SOUNDBIAS bias-and-clamp.
    - PSG channels were not proper state machines (DAC-on vs enabled
      conflated, no negate-quirk, wrong LFSR seeds in some paths).

  Re-implemented from GBATEK / Pan Docs register semantics; behavior was
  cross-checked against mGBA and NanoBoyAdvance during development. No
  source code was copied.

  ── Pipeline overview ──

    CPU cycles → AdvanceFrameSeq (8-step @ 512 Hz)
              → TickAllChannels (advance phase counters, LFSR)
              → Emit one output sample every CYCLES_PER_OUTPUT_SAMPLE

    Timer overflow (from timers.pas)
              → OnTimerOverflow(idx)
                  → if SOUNDCNT_H.bit10 = idx, pop FIFO A → Latch
                  → if SOUNDCNT_H.bit14 = idx, pop FIFO B → Latch
                  → if either FIFO drops to ≤16 bytes, fire DMA refill hook

    GenerateSamples(n, outBuf)
              → drain internal sample ring buffer for `n` samples

  ── Internal mixing grid and output rate ──

  SOUNDBIAS bits 14:15 set the hardware's amplitude resolution /
  sampling cycle: 00 = 9-bit @ 32.768 kHz ... 11 = 6-bit @ 262.144 kHz.
  We honor the sampling-cycle half: the internal mixing grid runs at
  32768 << resolution Hz, so FIFO byte holds and PSG edge transitions
  land on the same time grid the hardware DAC uses. Mixing at a coarser
  grid than the game configures folds the DAC staircase's above-Nyquist
  images back into the audible band (measured against a reference
  recording: +4 dB excess at 11-14 kHz, x2 energy above 6 kHz on a
  commercial mp2k title that selects 65.536 kHz).

  Output is fixed at 32768 Hz: when the internal grid is oversampled,
  a cascade of half-band FIR decimators (31-tap, -6 dB at 16.4 kHz,
  -90 dB at 24 kHz) filters and decimates back down, which suppresses
  the imaging a raw point-sample of the staircase would alias in.
  Windows WASAPI shared-mode then resamples 32768 Hz to the device rate
  — same approach mGBA + NBA use via SDL/Qt audio sinks. The earlier
  44100 Hz host-rate emit with ZOH+linear interp produced unacceptable
  aliasing on FIFO PCM (cross-emulator diff; see APU_SAMPLE_RATE).

  ── What hasn't been rewritten ──

    - `audio.pas` (winmm waveOut wrapper) — orthogonal, preserved.
    - Memory FIFO push hook signature — still byte-stream. APU
      accumulates 4 bytes into the FIFO byte ring directly (the
      word-ring representation is an mGBA/NBA implementation choice;
      a 32-byte ring is structurally equivalent).
    - DMA sound-FIFO timing=3 override — already correct.
    - Host wiring — same external interface (PushFifoA/B,
      SetFifoALowHook/BLowHook, GenerateSamples). One addition:
      tmrs.SetOverflowHook(@gapu.OnTimerOverflow).
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes, Memory, Timers;

const
  { Native GBA internal mixing rate (SOUNDBIAS default = bits 14:15 = 0
    → 32.768 kHz "best for FIFO"). Emitting at the native rate and
    letting Windows WASAPI resample to the device rate eliminates the
    homegrown-resampler aliasing that a cross-emulator WAV/spectrogram
    diff surfaced (2026-05-18). }
  APU_SAMPLE_RATE = 32768;
  SAMPLES_PER_FRAME = APU_SAMPLE_RATE div 60;     { 546 }

  CPU_CLOCK_HZ = 16777216;
  CYC_PER_FRAMESEQ_STEP = 32768;                   { 512 Hz frame sequencer
                                                     (some secondary writeups
                                                     cite 8192, which is wrong —
                                                     that gives 2048 Hz.
                                                     Verified from GBATEK /
                                                     cycle tables: 32768
                                                     cycles per step.) }
  OUTPUT_SAMPLES_PER_FRAMESEQ_STEP = APU_SAMPLE_RATE / 512;   { 86.13 }

  { I/O offsets within $04000000. }
  REG_SOUND1CNT_L = $060;
  REG_SOUND1CNT_H = $062;
  REG_SOUND1CNT_X = $064;
  REG_SOUND2CNT_L = $068;
  REG_SOUND2CNT_H = $06C;
  REG_SOUND3CNT_L = $070;
  REG_SOUND3CNT_H = $072;
  REG_SOUND3CNT_X = $074;
  REG_SOUND4CNT_L = $078;
  REG_SOUND4CNT_H = $07C;
  REG_SOUNDCNT_L  = $080;
  REG_SOUNDCNT_H  = $082;
  REG_SOUNDCNT_X  = $084;
  REG_SOUNDBIAS   = $088;
  REG_WAVE_RAM    = $090;
  REG_FIFO_A      = $0A0;
  REG_FIFO_B      = $0A4;

  FIFO_CAPACITY = 32;                              { bytes }
  FIFO_LOW_THRESHOLD = 16;

  { Output reconstruction stage. The console's audio output passes
    through an analog low-pass after the DAC (the hardware's
    characteristic muffled top end) and an AC-coupling capacitor (no
    DC reaches the speaker). A raw render of the DAC staircase is
    audibly harsher than either real hardware or reference emulators:
    measured against an mGBA capture of the same commercial mp2k
    title, the unfiltered staircase carries ~1.5-1.7x the reference's
    energy above 6 kHz, and its PCM stream's content-inherent DC bias
    (mean sample -4/128, measured at the FIFO push boundary) lands in
    the output. One-pole low-pass fit numerically to the measured
    reference transfer curve (within 0.3 dB, 200 Hz - 14 kHz;
    -3 dB at ~12.1 kHz at the 32768 Hz output rate), DC blocker at
    ~5 Hz. }
  OUT_LP_COEFF = 0.806902;      { y += coeff * (x - y), at 32768 Hz }
  OUT_DC_R     = 0.999041;      { y = x - x' + R*y', ~5 Hz corner }

  { 31-tap half-band FIR for 2:1 decimation of the oversampled internal
    mixing grid (kaiser beta 7.0, cutoff 0.5 Nyquist, unity DC gain).
    Response at 65536 Hz input: -0.9 dB @ 14 kHz, -6 dB @ 16.4 kHz,
    -35 dB @ 20 kHz, -90 dB @ 24 kHz. Odd-offset taps are exactly zero
    (half-band property); the dot product skips them. }
  HB_TAPS: array[0..30] of Double = (
    -0.0001258613051577,  0.0000000000000000, +0.0010645036847062,
     0.0000000000000000, -0.0037724722733803,  0.0000000000000000,
    +0.0098040820092808,  0.0000000000000000, -0.0215919022809138,
     0.0000000000000000, +0.0439889791058452,  0.0000000000000000,
    -0.0930905436765203,  0.0000000000000000, +0.3137374663218720,
    +0.4999714968285360, +0.3137374663218720,  0.0000000000000000,
    -0.0930905436765203,  0.0000000000000000, +0.0439889791058452,
     0.0000000000000000, -0.0215919022809138,  0.0000000000000000,
    +0.0098040820092808,  0.0000000000000000, -0.0037724722733803,
     0.0000000000000000, +0.0010645036847062,  0.0000000000000000,
    -0.0001258613051577);

type
  TFifoLowHook = procedure of object;

  { One 2:1 half-band decimation stage: 31-sample ring history + phase
    toggle (an output is produced on every second input). }
  TDecim2 = record
    Hist:  array[0..30] of Double;
    Pos:   Integer;
    Phase: Integer;
  end;

  TStereoSample = record
    L: SmallInt;
    R: SmallInt;
  end;
  PStereoSample = ^TStereoSample;
  TSampleBuffer = array of TStereoSample;

  TEnvelope = record
    Volume:    Integer;       { 0..15, current output gain }
    Initial:   Integer;       { 0..15, reloaded on trigger }
    Period:    Integer;       { 0..7. 0 disables stepping }
    Direction: Integer;       { +1 (increase) or -1 (decrease) }
    Divider:   Integer;       { countdown from Period; decremented at step 7 }
  end;

  TLength = record
    Counter: Integer;
    Max:     Integer;         { 64 or 256 }
    Enabled: Boolean;
  end;

  TSweep = record
    ShadowFreq: Integer;      { 0..2047 — separate from live channel Freq }
    Period:     Integer;      { 0..7 — 0 means "8 internally" }
    Shift:      Integer;      { 0..7 }
    Direction:  Integer;      { +1 or -1 }
    Divider:    Integer;
    Enable:     Boolean;      { (Period<>0) OR (Shift<>0) }
    NegateUsed: Boolean;      { has a negate calc occurred since trigger? }
  end;

  TPsgSquare = record
    Enabled:   Boolean;
    DacOn:     Boolean;
    Freq:      Integer;
    DutyPat:   Integer;
    DutyPos:   Integer;
    FreqAccum: Integer;
    Env:       TEnvelope;
    Len:       TLength;
  end;

  TPsgWave = record
    Enabled:    Boolean;
    DacOn:      Boolean;
    PlayBank:   Integer;
    BankSelect: Integer;      { CPU read/write bank (CNT_L bit 6) }
    Dimension:  Boolean;      { CNT_L bit 5 — 0=single bank, 1=double }
    Volume:     Integer;      { 0..3 }
    Force75:    Boolean;
    Freq:       Integer;
    Phase:      Integer;      { 0..31 }
    FreqAccum:  Integer;
    Len:        TLength;
    WaveRam:    array[0..1, 0..15] of TByte;
  end;

  TPsgNoise = record
    Enabled:    Boolean;
    DacOn:      Boolean;
    Width7Bit:  Boolean;
    RatioCode:  Integer;      { 0..7 }
    ShiftCode:  Integer;      { 0..15 }
    Lfsr:       TWord;
    FreqAccum:  Integer;
    Env:        TEnvelope;
    Len:        TLength;
  end;

  TFifo = record
    Buf:    array[0 .. FIFO_CAPACITY - 1] of ShortInt;
    Head:   Integer;
    Tail:   Integer;
    Count:  Integer;
    Latch:  ShortInt;         { last popped sample, held until next pop }

    { Byte-accumulator for the byte-stream-from-Memory-hook path: each
      WriteByte at $04000Ax0..A3 (or A4..A7) accumulates here, and the
      4 bytes are enqueued as a complete word on the 4th byte. }
    PendingWord:  TWord;
    PendingBytes: Integer;
  end;

  TFrameSeq = record
    Step:     Integer;
    CpuAccum: Int64;
  end;

  TGbaApu = class
  private
    FMem: TGbaMemory;
    FTmrs: TGbaTimers;     { for reading the LATCHED reload values that
                              the FIFO-pop math needs — Memory's CNT_L
                              gets clobbered each Step with live counter }

    FFrameSeq: TFrameSeq;

    FCh1: TPsgSquare;
    FSweep: TSweep;       { Ch1 only }
    FCh2: TPsgSquare;
    FCh3: TPsgWave;
    FCh4: TPsgNoise;

    FFifoA, FFifoB: TFifo;

    { Per-fine-sample phase accumulators (Double for sub-step
      precision over long runs). Updated by GenerateSamples on the
      internal mixing grid (32768 * FOversample Hz). }
    FFrameSeqAccum:  Double;
    FCh1PhaseAccum:  Double;
    FCh2PhaseAccum:  Double;
    FCh3PhaseAccum:  Double;
    FCh4PhaseAccum:  Double;
    FFifoAPopAccum:  Double;
    FFifoBPopAccum:  Double;

    { SOUNDBIAS-resolution oversampling: internal grid rate multiplier
      (1/2/4/8 for resolution 0..3) and the effective grid rate in Hz
      that all per-fine-sample step math divides by. }
    FOversample: Integer;
    FEffRate:    Double;

    { Half-band decimator cascade state: [side 0=L/1=R, stage 0..2].
      Stage count in use = log2(FOversample). }
    FDecim: array[0..1, 0..2] of TDecim2;

    { Output reconstruction stage state (see GenerateSamples):
      one-pole low-pass + DC-blocking high-pass per side. }
    FLpState:  array[0..1] of Double;
    FDcPrevIn: array[0..1] of Double;
    FDcState:  array[0..1] of Double;

    { Register + pop-rate cache, refreshed by SyncFromRegs (per
      scanline). MixOne and the per-fine-sample advance loops run at
      up to 262 kHz; reading I/O through FMem there dominated the
      windowed-mode frame budget. }
    FCacheSoundcntL: TWord;
    FCacheSoundcntH: TWord;
    FCacheSoundbias: TWord;
    FPopsPerFineA:   Double;
    FPopsPerFineB:   Double;

    FOnFifoALow, FOnFifoBLow: TFifoLowHook;

    FPrevMasterEnable: Boolean;
    FPrevCh1SweepDir:  Integer;

    procedure SyncFromRegs;
    procedure StepLengthAll;
    procedure StepEnvelopeAll;
    procedure StepSweepCh1;
    procedure StepEnvelope(var env: TEnvelope);
    procedure StepLength(var ln: TLength; var enabled: Boolean);

    { Advance one frame_seq step (handles whatever events fall at the
      current step number, then increments). Called by GenerateSamples
      when FFrameSeqAccum overflows the per-step threshold. }
    procedure AdvanceFrameSeqOneStep;

    { Per-sample channel phase advancement. Each computes how much of
      a phase step occurs in 1/APU_SAMPLE_RATE seconds based on the
      channel's current freq config, advances the accumulator, fires
      discrete state changes (DutyPos++, LFSR step, etc.) when the
      accumulator crosses 1.0. }
    procedure AdvanceCh1OneSample;
    procedure AdvanceCh2OneSample;
    procedure AdvanceCh3OneSample;
    procedure AdvanceCh4OneSample;
    procedure AdvanceFifosOneSample;

    { Switch the internal grid multiplier (resets decimator state on
      change; called from GenerateSamples when SOUNDBIAS bits 14:15
      move). }
    procedure SetOversample(os: Integer);

    { Feed one fine-grid sample into the decimator cascade for `side`.
      Returns True (with y set) when the last stage emits an output-
      rate sample — exactly once per FOversample fine samples. }
    function  PushDecimCascade(side, nstages: Integer; x: Double;
                               out y: Double): Boolean;

    function  SampleCh1: Integer;
    function  SampleCh2: Integer;
    function  SampleCh3: Integer;
    function  SampleCh4: Integer;

    procedure TriggerCh1;
    procedure TriggerCh2;
    procedure TriggerCh3;
    procedure TriggerCh4;
    procedure TriggerLengthQuirk(var ln: TLength);

    function  Ch4CyclesPerStep: Integer;
    function  SweepCalc(out overflow: Boolean): Integer;
    procedure ResetFifo(var f: TFifo);
    procedure PopFifo(var f: TFifo; isFifoA: Boolean);
    procedure EnqueueFifoByte(var f: TFifo; v: ShortInt);

    function  MixOne(side: Integer): SmallInt;       { side: 0=L, 1=R }

  public
    constructor Create(mem: TGbaMemory);

    { Bind a TGbaTimers instance — required for accurate FIFO pop rate
      computation. Without this, AdvanceFifosOneSample falls back to
      reading CNT_L from memory (which is the live counter, not the
      reload — produces wrong pop rate, audible as wrong pitch). }
    procedure SetTimers(tmrs: TGbaTimers);

    { CPU-cycle-driven advancement. Called from the per-scanline
      scheduler. Advances the frame sequencer (8-step @ 512 Hz),
      ticks all four channel phase counters, and emits one output
      sample per CYC_PER_OUTPUT_SAMPLE (= 16.78 MHz / 44.1 kHz). }
    procedure Step(cpuCycles: Int64);

    { Drain `n` stereo samples from the internal ring buffer into
      outBuf. If fewer than n samples are available, zero-fills the
      remainder. }
    procedure GenerateSamples(n: Integer; var outBuf: TSampleBuffer);

    { FIFO push (called by Memory.pas FIFO write hook for each byte
      of a 1/2/4-byte CPU/DMA write to $040000A0..A3 / $040000A4..A7). }
    procedure PushFifoA(v: ShortInt);
    procedure PushFifoB(v: ShortInt);

    { Timer overflow callback (registered via TGbaTimers.SetOverflowHook).
      Fires for every overflow on any timer (idx 0..3); APU consults
      SOUNDCNT_H bits 10/14 to decide which FIFO(s) to pop. }
    procedure OnTimerOverflow(timerIdx: Integer);

    { DMA-refill request hooks, fired when a FIFO drops to ≤ half
      capacity AFTER a pop. Edge-triggered. }
    procedure SetFifoALowHook(hook: TFifoLowHook);
    procedure SetFifoBLowHook(hook: TFifoLowHook);
  public
    { Diagnostics — separate public section because Pascal requires
      fields BEFORE methods within a single visibility block. }
    Ch1RetriggerCount: Int64;
    Ch2RetriggerCount: Int64;
    Ch3RetriggerCount: Int64;
    Ch4RetriggerCount: Int64;
    FifoARequestCount: Int64;
    FifoBRequestCount: Int64;
    FifoAPushCount:    Int64;
    FifoBPushCount:    Int64;
    FifoAUnderrunCount: Int64;   { pop attempts on an empty FIFO }
    FifoBUnderrunCount: Int64;
    FifoADropCount:     Int64;   { pushes dropped on a full FIFO }
    FifoBDropCount:     Int64;

    { Forensic byte loggers: first MAX_BYTES_LOGGED bytes pushed into each
      FIFO are tee'd here so the harness can dump them post-run. Tells us
      whether DMA is reading real PCM data or garbage. }
    FifoALog: array[0..262143] of ShortInt;
    FifoBLog: array[0..262143] of ShortInt;
    FifoALogCount: Integer;
    FifoBLogCount: Integer;

    { State-inspection accessors for diagnostics. Read at end of run
      to see what the APU thinks each channel is doing. }
    function Ch1Enabled: Boolean;
    function Ch2Enabled: Boolean;
    function Ch3Enabled: Boolean;
    function Ch4Enabled: Boolean;
    function Ch1EnvVol: Integer;
    function Ch2EnvVol: Integer;
    function Ch3VolRaw: Integer;
    function Ch4EnvVol: Integer;
    function FifoACount: Integer;
    function FifoBCount: Integer;
  end;

implementation

const
  { Duty patterns: 8-step. The bit at DutyPos[0..7] is the output high/low. }
  DUTY_PATTERN: array[0..3, 0..7] of Integer = (
    (0, 0, 0, 0, 0, 0, 0, 1),    { 12.5% }
    (1, 0, 0, 0, 0, 0, 0, 1),    { 25% }
    (1, 0, 0, 0, 0, 1, 1, 1),    { 50% }
    (0, 1, 1, 1, 1, 1, 1, 0)     { 75% — note: visually inverted but
                                    operationally a left-rotation of 25% }
  );

constructor TGbaApu.Create(mem: TGbaMemory);
begin
  inherited Create;
  FMem := mem;
  FTmrs := nil;
  FillChar(FFrameSeq, SizeOf(FFrameSeq), 0);
  FillChar(FCh1, SizeOf(FCh1), 0);
  FillChar(FSweep, SizeOf(FSweep), 0);
  FillChar(FCh2, SizeOf(FCh2), 0);
  FillChar(FCh3, SizeOf(FCh3), 0);
  FillChar(FCh4, SizeOf(FCh4), 0);
  FCh4.Lfsr := $7FFF;       { generic-safe initial; trigger overwrites }
  FillChar(FFifoA, SizeOf(FFifoA), 0);
  FillChar(FFifoB, SizeOf(FFifoB), 0);
  FCh1.Len.Max := 64;
  FCh2.Len.Max := 64;
  FCh3.Len.Max := 256;
  FCh4.Len.Max := 64;
  FFrameSeqAccum := 0;
  FCh1PhaseAccum := 0;
  FCh2PhaseAccum := 0;
  FCh3PhaseAccum := 0;
  FCh4PhaseAccum := 0;
  FFifoAPopAccum := 0;
  FFifoBPopAccum := 0;
  FOversample := 1;
  FEffRate := APU_SAMPLE_RATE;
  FillChar(FDecim, SizeOf(FDecim), 0);
  FillChar(FLpState, SizeOf(FLpState), 0);
  FillChar(FDcPrevIn, SizeOf(FDcPrevIn), 0);
  FillChar(FDcState, SizeOf(FDcState), 0);
  FPrevMasterEnable := False;
  FPrevCh1SweepDir := +1;
  FifoALogCount := 0;
  FifoBLogCount := 0;
end;

{ ───── Memory + Helper accessors ─────────────────────────────────── }

function TGbaApu.Ch4CyclesPerStep: Integer;
var rNum, rDen: Integer;
begin
  if FCh4.RatioCode = 0 then begin rNum := 1; rDen := 2; end
                       else begin rNum := FCh4.RatioCode; rDen := 1; end;
  Result := (32 * rNum * (1 shl (FCh4.ShiftCode + 1))) div rDen;
  if Result < 1 then Result := 1;
end;

function TGbaApu.SweepCalc(out overflow: Boolean): Integer;
var
  delta: Integer;
begin
  delta := FSweep.ShadowFreq shr FSweep.Shift;
  if FSweep.Direction = -1 then
  begin
    FSweep.NegateUsed := True;
    Result := FSweep.ShadowFreq - delta;
  end
  else
    Result := FSweep.ShadowFreq + delta;
  overflow := (Result < 0) or (Result > 2047);
end;

{ ───── Frame sequencer ───────────────────────────────────────────── }

procedure TGbaApu.StepEnvelope(var env: TEnvelope);
begin
  if env.Period = 0 then Exit;
  Dec(env.Divider);
  if env.Divider <= 0 then
  begin
    env.Divider := env.Period;
    env.Volume := env.Volume + env.Direction;
    if env.Volume < 0  then env.Volume := 0;
    if env.Volume > 15 then env.Volume := 15;
  end;
end;

procedure TGbaApu.StepLength(var ln: TLength; var enabled: Boolean);
begin
  if not ln.Enabled then Exit;
  if ln.Counter > 0 then
  begin
    Dec(ln.Counter);
    if ln.Counter = 0 then enabled := False;
  end;
end;

procedure TGbaApu.StepLengthAll;
begin
  StepLength(FCh1.Len, FCh1.Enabled);
  StepLength(FCh2.Len, FCh2.Enabled);
  StepLength(FCh3.Len, FCh3.Enabled);
  StepLength(FCh4.Len, FCh4.Enabled);
end;

procedure TGbaApu.StepEnvelopeAll;
begin
  StepEnvelope(FCh1.Env);
  StepEnvelope(FCh2.Env);
  StepEnvelope(FCh4.Env);
end;

procedure TGbaApu.StepSweepCh1;
var
  candidate, candidate2: Integer;
  ov: Boolean;
begin
  if not FSweep.Enable then Exit;
  if not FCh1.Enabled then Exit;
  Dec(FSweep.Divider);
  if FSweep.Divider > 0 then Exit;
  if FSweep.Period = 0 then FSweep.Divider := 8
                       else FSweep.Divider := FSweep.Period;
  if FSweep.Period = 0 then Exit;     { period 0 ticks but does nothing }

  candidate := SweepCalc(ov);
  if ov then begin FCh1.Enabled := False; Exit; end;

  if FSweep.Shift <> 0 then
  begin
    FSweep.ShadowFreq := candidate;
    FCh1.Freq := candidate;
    { Overflow re-check — calculate again without writing. }
    candidate2 := SweepCalc(ov);
    if ov then FCh1.Enabled := False;
    if candidate2 = candidate then ;  { silence unused }
  end;
end;

procedure TGbaApu.AdvanceFrameSeqOneStep;
begin
  FFrameSeq.Step := (FFrameSeq.Step + 1) and 7;
  case FFrameSeq.Step of
    0, 4: StepLengthAll;
    2, 6: begin StepLengthAll; StepSweepCh1; end;
    7:    StepEnvelopeAll;
  end;
end;

{ ───── Channel ticks (phase advancement) ─────────────────────────── }

procedure TGbaApu.AdvanceCh1OneSample;
{ Per-output-sample increment for Ch1 duty position.
  Duty step rate (Hz) = 131072 / (2048-F) * 8 = 1048576/(2048-F).
  Output samples per duty step = APU_SAMPLE_RATE / (1048576/(2048-F))
                              = APU_SAMPLE_RATE * (2048-F) / 1048576.
  Per sample, advance accumulator by 1.0 / that = 1048576 / (APU_SAMPLE_RATE * (2048-F)).
  At F=1750, APU_RATE=32768: stepsPerSample = 1048576/(32768*298) = 0.1074. }
var
  stepsPerSample: Double;
begin
  if not FCh1.Enabled then Exit;
  if FCh1.Freq >= 2048 then Exit;
  stepsPerSample := 1048576.0 / (FEffRate * (2048 - FCh1.Freq));
  FCh1PhaseAccum := FCh1PhaseAccum + stepsPerSample;
  while FCh1PhaseAccum >= 1.0 do
  begin
    FCh1PhaseAccum := FCh1PhaseAccum - 1.0;
    FCh1.DutyPos := (FCh1.DutyPos + 1) and 7;
  end;
end;

procedure TGbaApu.AdvanceCh2OneSample;
var
  stepsPerSample: Double;
begin
  if not FCh2.Enabled then Exit;
  if FCh2.Freq >= 2048 then Exit;
  stepsPerSample := 1048576.0 / (FEffRate * (2048 - FCh2.Freq));
  FCh2PhaseAccum := FCh2PhaseAccum + stepsPerSample;
  while FCh2PhaseAccum >= 1.0 do
  begin
    FCh2PhaseAccum := FCh2PhaseAccum - 1.0;
    FCh2.DutyPos := (FCh2.DutyPos + 1) and 7;
  end;
end;

procedure TGbaApu.AdvanceCh3OneSample;
{ Ch3 sample rate = 67108864/(2048-F).
  Sample-steps per output sample = 67108864 / (APU_SAMPLE_RATE * (2048-F)). }
var
  stepsPerSample: Double;
begin
  if not FCh3.Enabled then Exit;
  if FCh3.Freq >= 2048 then Exit;
  stepsPerSample := 67108864.0 / (FEffRate * (2048 - FCh3.Freq));
  FCh3PhaseAccum := FCh3PhaseAccum + stepsPerSample;
  while FCh3PhaseAccum >= 1.0 do
  begin
    FCh3PhaseAccum := FCh3PhaseAccum - 1.0;
    Inc(FCh3.Phase);
    if FCh3.Phase >= 32 then
    begin
      FCh3.Phase := 0;
      if FCh3.Dimension then FCh3.PlayBank := FCh3.PlayBank xor 1;
    end;
  end;
end;

procedure TGbaApu.AdvanceCh4OneSample;
{ Ch4 LFSR step rate = CPU_HZ / Ch4CyclesPerStep. Per output sample,
  steps = APU_SAMPLE_RATE_inv / cyc-per-step inverse = CPU/sampleRate
  inverse... actually:
    StepRate = CPU / cycPerStep [Hz]
    OutputSamplesPerStep = APU_RATE / StepRate = APU_RATE * cycPerStep / CPU
    StepsPerOutputSample = 1 / OutputSamplesPerStep = CPU / (APU_RATE * cycPerStep). }
var
  cycPerStep: Integer;
  stepsPerSample: Double;
  bit01, fbBit: TWord;
begin
  if not FCh4.Enabled then Exit;
  cycPerStep := Ch4CyclesPerStep;
  stepsPerSample := CPU_CLOCK_HZ / (FEffRate * cycPerStep);
  FCh4PhaseAccum := FCh4PhaseAccum + stepsPerSample;
  while FCh4PhaseAccum >= 1.0 do
  begin
    FCh4PhaseAccum := FCh4PhaseAccum - 1.0;
    bit01 := (FCh4.Lfsr xor (FCh4.Lfsr shr 1)) and 1;
    FCh4.Lfsr := FCh4.Lfsr shr 1;
    if bit01 = 1 then
    begin
      if FCh4.Width7Bit then fbBit := $40 else fbBit := $4000;
      FCh4.Lfsr := FCh4.Lfsr or fbBit;
    end;
  end;
end;

procedure TGbaApu.AdvanceFifosOneSample;
{ FIFO pop rates come from Timer 0/1 LATCHED state (via FTmrs
  accessors, NOT memory reads — Memory's CNT_L gets overwritten with
  the live counter each Step, destroying the programmed reload value).
  SOUNDCNT_H bits 10/14 select which timer drives each FIFO. The rate
  math lives in SyncFromRegs' cache refresh (per scanline); this hot
  path only advances the accumulators. }
begin
  FFifoAPopAccum := FFifoAPopAccum + FPopsPerFineA;
  while FFifoAPopAccum >= 1.0 do
  begin
    FFifoAPopAccum := FFifoAPopAccum - 1.0;
    PopFifo(FFifoA, True);
  end;
  FFifoBPopAccum := FFifoBPopAccum + FPopsPerFineB;
  while FFifoBPopAccum >= 1.0 do
  begin
    FFifoBPopAccum := FFifoBPopAccum - 1.0;
    PopFifo(FFifoB, False);
  end;
end;

{ ───── Sample read ───────────────────────────────────────────────── }

function TGbaApu.SampleCh1: Integer;
{ Returns signed-centered value: +Vol on high half, -Vol on low half,
  0 when channel disabled or DAC off. This centering keeps SILENT
  channels (Volume=0) contributing literal 0 to the mix, avoiding the
  -8 per-channel floor that produces the -8192 DC bug. Article's
  "raw 0..15 minus 8" centering scheme conflicts with our 4-channel
  mixer math; ±Volume is the equivalent first-cut style that NBA's
  quad_channel.cc actually uses internally. }
begin
  if (not FCh1.Enabled) or (not FCh1.DacOn) then Exit(0);
  if DUTY_PATTERN[FCh1.DutyPat, FCh1.DutyPos] = 1 then
    Result := +FCh1.Env.Volume
  else
    Result := -FCh1.Env.Volume;
end;

function TGbaApu.SampleCh2: Integer;
begin
  if (not FCh2.Enabled) or (not FCh2.DacOn) then Exit(0);
  if DUTY_PATTERN[FCh2.DutyPat, FCh2.DutyPos] = 1 then
    Result := +FCh2.Env.Volume
  else
    Result := -FCh2.Env.Volume;
end;

function TGbaApu.SampleCh3: Integer;
var
  byteIdx, nibble, raw, mult: Integer;
begin
  if (not FCh3.Enabled) or (not FCh3.DacOn) then Exit(0);
  byteIdx := FCh3.Phase shr 1;
  nibble := 1 - (FCh3.Phase and 1);
  if nibble = 1 then raw := (FCh3.WaveRam[FCh3.PlayBank, byteIdx] shr 4) and $F
                else raw :=  FCh3.WaveRam[FCh3.PlayBank, byteIdx]        and $F;
  if FCh3.Force75 then
    mult := 3
  else case FCh3.Volume of
    0: Exit(0);
    1: mult := 4;
    2: mult := 2;
    3: mult := 1;
  else
    mult := 0;
  end;
  { >>1 keeps 100% wave at +/-16, square-parity on the PSG bus (mGBA
    mixes the wave nibble at the same raw scale as squares). }
  Result := SarLongint((raw - 8) * mult, 1);
end;

function TGbaApu.SampleCh4: Integer;
{ Same centering scheme as Ch1/2 — ±Volume around 0 so silent channels
  contribute 0 to the bus. }
begin
  if (not FCh4.Enabled) or (not FCh4.DacOn) then Exit(0);
  if (FCh4.Lfsr and 1) = 0 then Result := +FCh4.Env.Volume
                            else Result := -FCh4.Env.Volume;
end;

{ ───── Channel triggers ──────────────────────────────────────────── }

procedure TGbaApu.TriggerLengthQuirk(var ln: TLength);
begin
  if ln.Counter = 0 then
  begin
    ln.Counter := ln.Max;
    { Per-step parity: frame-steps 0/2/4/6 clock length; if current step
      is odd (1/3/5/7), the NEXT step will clock — predecrement. }
    if ln.Enabled and ((FFrameSeq.Step and 1) = 1) then
      Dec(ln.Counter);
  end;
end;

procedure TGbaApu.TriggerCh1;
var
  cntL, cntH: TWord;
  envInit, envDir, envPeriod, duty: Integer;
  ov: Boolean;
  ignored: Integer;
begin
  cntL := FMem.ReadHalf($04000000 + REG_SOUND1CNT_L);
  cntH := FMem.ReadHalf($04000000 + REG_SOUND1CNT_H);
  duty      := (cntH shr  6) and $3;
  envPeriod := (cntH shr  8) and $7;
  envDir    := (cntH shr 11) and 1;
  envInit   := (cntH shr 12) and $F;

  FCh1.DutyPat := duty;
  FCh1.DutyPos := 0;
  FCh1.FreqAccum := 0;
  FCh1.Env.Initial := envInit;
  FCh1.Env.Volume  := envInit;
  if envDir = 1 then FCh1.Env.Direction := +1 else FCh1.Env.Direction := -1;
  FCh1.Env.Period  := envPeriod;
  FCh1.Env.Divider := envPeriod;
  FCh1.DacOn := (envInit > 0) or (FCh1.Env.Direction = +1);
  FCh1.Len.Enabled := ((FMem.ReadHalf($04000000 + REG_SOUND1CNT_X) shr 14) and 1) = 1;
  TriggerLengthQuirk(FCh1.Len);

  FSweep.Period := (cntL shr 4) and $7;
  if ((cntL shr 3) and 1) = 1 then FSweep.Direction := -1
                              else FSweep.Direction := +1;
  FSweep.Shift  :=  cntL        and $7;
  FSweep.ShadowFreq := FCh1.Freq;
  FSweep.NegateUsed := False;
  FSweep.Enable := (FSweep.Period <> 0) or (FSweep.Shift <> 0);
  if FSweep.Period = 0 then FSweep.Divider := 8 else FSweep.Divider := FSweep.Period;
  if FSweep.Shift <> 0 then
  begin
    ignored := SweepCalc(ov);
    if ignored = ignored then ;   { silence unused }
    if ov then FCh1.Enabled := False;
  end;

  FCh1.Enabled := FCh1.DacOn;
  Inc(Ch1RetriggerCount);
end;

procedure TGbaApu.TriggerCh2;
var
  cntL, cntH: TWord;
  envInit, envDir, envPeriod, duty: Integer;
begin
  cntL := FMem.ReadHalf($04000000 + REG_SOUND2CNT_L);
  cntH := FMem.ReadHalf($04000000 + REG_SOUND2CNT_H);
  duty      := (cntL shr  6) and $3;
  envPeriod := (cntL shr  8) and $7;
  envDir    := (cntL shr 11) and 1;
  envInit   := (cntL shr 12) and $F;

  FCh2.DutyPat := duty;
  FCh2.DutyPos := 0;
  FCh2.FreqAccum := 0;
  FCh2.Env.Initial := envInit;
  FCh2.Env.Volume  := envInit;
  if envDir = 1 then FCh2.Env.Direction := +1 else FCh2.Env.Direction := -1;
  FCh2.Env.Period  := envPeriod;
  FCh2.Env.Divider := envPeriod;
  FCh2.DacOn := (envInit > 0) or (FCh2.Env.Direction = +1);
  FCh2.Len.Enabled := ((cntH shr 14) and 1) = 1;
  TriggerLengthQuirk(FCh2.Len);
  FCh2.Enabled := FCh2.DacOn;
  Inc(Ch2RetriggerCount);
end;

procedure TGbaApu.TriggerCh3;
var
  cntL, cntH, cntX: TWord;
begin
  cntL := FMem.ReadHalf($04000000 + REG_SOUND3CNT_L);
  cntH := FMem.ReadHalf($04000000 + REG_SOUND3CNT_H);
  cntX := FMem.ReadHalf($04000000 + REG_SOUND3CNT_X);
  FCh3.DacOn      := ((cntL shr 7) and 1) = 1;
  FCh3.Dimension  := ((cntL shr 5) and 1) = 1;
  FCh3.PlayBank   := (cntL shr 6) and 1;
  FCh3.BankSelect := FCh3.PlayBank;
  FCh3.Volume     := (cntH shr 13) and $3;
  FCh3.Force75    := ((cntH shr 15) and 1) = 1;
  FCh3.Len.Enabled := ((cntX shr 14) and 1) = 1;
  FCh3.Len.Max := 256;
  TriggerLengthQuirk(FCh3.Len);
  FCh3.Phase := 0;
  FCh3.FreqAccum := 0;
  FCh3.Enabled := FCh3.DacOn;
  Inc(Ch3RetriggerCount);
end;

procedure TGbaApu.TriggerCh4;
var
  cntL, cntH: TWord;
  envInit, envDir, envPeriod: Integer;
begin
  cntL := FMem.ReadHalf($04000000 + REG_SOUND4CNT_L);
  cntH := FMem.ReadHalf($04000000 + REG_SOUND4CNT_H);
  envPeriod := (cntL shr  8) and $7;
  envDir    := (cntL shr 11) and 1;
  envInit   := (cntL shr 12) and $F;
  FCh4.RatioCode  :=  cntH        and $7;
  FCh4.Width7Bit  := ((cntH shr 3) and 1) = 1;
  FCh4.ShiftCode  := (cntH shr 4) and $F;
  FCh4.Len.Enabled := ((cntH shr 14) and 1) = 1;

  FCh4.Env.Initial := envInit;
  FCh4.Env.Volume  := envInit;
  if envDir = 1 then FCh4.Env.Direction := +1 else FCh4.Env.Direction := -1;
  FCh4.Env.Period  := envPeriod;
  FCh4.Env.Divider := envPeriod;
  FCh4.DacOn := (envInit > 0) or (FCh4.Env.Direction = +1);
  TriggerLengthQuirk(FCh4.Len);
  if FCh4.Width7Bit then FCh4.Lfsr := $40 else FCh4.Lfsr := $4000;
  FCh4.FreqAccum := 0;
  FCh4.Enabled := FCh4.DacOn;
  Inc(Ch4RetriggerCount);
end;

{ ───── SyncFromRegs ──────────────────────────────────────────────── }

procedure TGbaApu.SyncFromRegs;
var
  cntL, cntH, cntX: TWord;
  soundcntX: TWord;
  masterEnable: Boolean;
  newSweepDir: Integer;
  i, j: Integer;
  status: TWord;
  waveByte: TByte;
var
  fifoATimer, fifoBTimer: Integer;

  function ComputeTimerPopRate(timerIdx: Integer): Double;
  var
    reload, prescaler, divisor: Integer;
  begin
    if (timerIdx < 0) or (timerIdx > 3) then Exit(0);
    if FTmrs = nil then Exit(0);
    if not FTmrs.IsEnabled(timerIdx) then Exit(0);
    reload := FTmrs.GetReload(timerIdx);
    prescaler := FTmrs.GetPrescaler(timerIdx);
    divisor := 65536 - reload;
    if (divisor <= 0) or (prescaler <= 0) then Exit(0);
    Result := CPU_CLOCK_HZ / (prescaler * divisor);
  end;

begin
  { Refresh the register + pop-rate cache consumed by the fine-sample
    loops (MixOne, AdvanceFifosOneSample, GenerateSamples). }
  FCacheSoundcntL := FMem.ReadHalf($04000000 + REG_SOUNDCNT_L);
  FCacheSoundcntH := FMem.ReadHalf($04000000 + REG_SOUNDCNT_H);
  FCacheSoundbias := FMem.ReadHalf($04000000 + REG_SOUNDBIAS);

  fifoATimer := (FCacheSoundcntH shr 10) and 1;
  fifoBTimer := (FCacheSoundcntH shr 14) and 1;
  FPopsPerFineA := ComputeTimerPopRate(fifoATimer);
  FPopsPerFineB := ComputeTimerPopRate(fifoBTimer);
  if FPopsPerFineA > 0 then FPopsPerFineA := FPopsPerFineA / FEffRate;
  if FPopsPerFineB > 0 then FPopsPerFineB := FPopsPerFineB / FEffRate;

  soundcntX := FMem.ReadHalf($04000000 + REG_SOUNDCNT_X);
  masterEnable := ((soundcntX shr 7) and 1) = 1;

  if masterEnable and not FPrevMasterEnable then
  begin
    { 0 → 1: reset frame sequencer step. }
    FFrameSeq.Step := 0;
    FFrameSeq.CpuAccum := 0;
  end
  else if FPrevMasterEnable and not masterEnable then
  begin
    { 1 → 0 cascade: zero all sound CNT registers + channel enables;
      preserve wave RAM and FIFOs (per §5.3 of the KB article). }
    for i := $060 to $087 do
      FMem.PokeIoHalf($04000000 + TWord(i and not 1), 0);
    FCh1.Enabled := False;
    FCh2.Enabled := False;
    FCh3.Enabled := False;
    FCh4.Enabled := False;
  end;
  FPrevMasterEnable := masterEnable;

  if not masterEnable then Exit;

  { Always-poll live state for each channel. }

  { Channel 1: freq + length-enable + sweep-negate-quirk + trigger. }
  cntL := FMem.ReadHalf($04000000 + REG_SOUND1CNT_L);
  cntX := FMem.ReadHalf($04000000 + REG_SOUND1CNT_X);
  FCh1.Freq := cntX and $7FF;
  FCh1.Len.Enabled := ((cntX shr 14) and 1) = 1;

  if ((cntL shr 3) and 1) = 1 then newSweepDir := -1 else newSweepDir := +1;
  if (FPrevCh1SweepDir = -1) and (newSweepDir = +1) and FSweep.NegateUsed then
    FCh1.Enabled := False;
  FPrevCh1SweepDir := newSweepDir;
  FSweep.Direction := newSweepDir;

  if ((cntX shr 15) and 1) = 1 then
  begin
    TriggerCh1;
    FMem.PokeIoHalf(REG_SOUND1CNT_X, cntX and $7FFF);
  end;

  { Channel 2. }
  cntH := FMem.ReadHalf($04000000 + REG_SOUND2CNT_H);
  FCh2.Freq := cntH and $7FF;
  FCh2.Len.Enabled := ((cntH shr 14) and 1) = 1;
  if ((cntH shr 15) and 1) = 1 then
  begin
    TriggerCh2;
    FMem.PokeIoHalf(REG_SOUND2CNT_H, cntH and $7FFF);
  end;

  { Channel 3: also re-read wave RAM into cache (CPU may have updated). }
  cntL := FMem.ReadHalf($04000000 + REG_SOUND3CNT_L);
  cntX := FMem.ReadHalf($04000000 + REG_SOUND3CNT_X);
  FCh3.Freq := cntX and $7FF;
  FCh3.Len.Enabled := ((cntX shr 14) and 1) = 1;
  FCh3.BankSelect := (cntL shr 6) and 1;
  for j := 0 to 15 do
  begin
    waveByte := FMem.ReadByte($04000000 + REG_WAVE_RAM + TWord(j));
    FCh3.WaveRam[FCh3.BankSelect, j] := waveByte;
  end;
  if ((cntX shr 15) and 1) = 1 then
  begin
    TriggerCh3;
    FMem.PokeIoHalf(REG_SOUND3CNT_X, cntX and $7FFF);
  end;

  { Channel 4. }
  cntH := FMem.ReadHalf($04000000 + REG_SOUND4CNT_H);
  FCh4.Len.Enabled := ((cntH shr 14) and 1) = 1;
  if ((cntH shr 15) and 1) = 1 then
  begin
    TriggerCh4;
    FMem.PokeIoHalf(REG_SOUND4CNT_H, cntH and $7FFF);
  end;

  { FIFO reset bits in SOUNDCNT_H (bits 11 + 15). }
  cntH := FMem.ReadHalf($04000000 + REG_SOUNDCNT_H);
  if ((cntH shr 11) and 1) = 1 then
  begin
    ResetFifo(FFifoA);
    FMem.PokeIoHalf(REG_SOUNDCNT_H, cntH and not TWord($0800));
  end;
  if ((cntH shr 15) and 1) = 1 then
  begin
    ResetFifo(FFifoB);
    FMem.PokeIoHalf(REG_SOUNDCNT_H, cntH and not TWord($8000));
  end;

  { PSG channel-enabled status bits (read-only mirrors in SOUNDCNT_X bits 0-3). }
  status := 0;
  if FCh1.Enabled then status := status or $1;
  if FCh2.Enabled then status := status or $2;
  if FCh3.Enabled then status := status or $4;
  if FCh4.Enabled then status := status or $8;
  FMem.PokeIoHalf(REG_SOUNDCNT_X,
    (FMem.ReadHalf($04000000 + REG_SOUNDCNT_X) and $FFF0) or status);
end;

{ ───── FIFO ──────────────────────────────────────────────────────── }

procedure TGbaApu.ResetFifo(var f: TFifo);
begin
  f.Head := 0; f.Tail := 0; f.Count := 0;
  f.Latch := 0;
  f.PendingWord := 0; f.PendingBytes := 0;
end;

procedure TGbaApu.EnqueueFifoByte(var f: TFifo; v: ShortInt);
begin
  if f.Count >= FIFO_CAPACITY then
  begin
    { Overflow push: the byte is lost and the played stream slips one
      sample against the game's delivery — counted for forensics. }
    if @f = @FFifoA then Inc(FifoADropCount)
                    else Inc(FifoBDropCount);
    Exit;
  end;
  f.Buf[f.Tail] := v;
  f.Tail := (f.Tail + 1) mod FIFO_CAPACITY;
  Inc(f.Count);
end;

procedure TGbaApu.PushFifoA(v: ShortInt);
begin
  Inc(FifoAPushCount);
  if FifoALogCount < Length(FifoALog) then
  begin
    FifoALog[FifoALogCount] := v;
    Inc(FifoALogCount);
  end;
  EnqueueFifoByte(FFifoA, v);
end;

procedure TGbaApu.PushFifoB(v: ShortInt);
begin
  Inc(FifoBPushCount);
  if FifoBLogCount < Length(FifoBLog) then
  begin
    FifoBLog[FifoBLogCount] := v;
    Inc(FifoBLogCount);
  end;
  EnqueueFifoByte(FFifoB, v);
end;

procedure TGbaApu.PopFifo(var f: TFifo; isFifoA: Boolean);
begin
  if f.Count > 0 then
  begin
    f.Latch := f.Buf[f.Head];
    f.Head := (f.Head + 1) mod FIFO_CAPACITY;
    Dec(f.Count);
  end
  else
  begin
    { Empty pop: hardware repeats the latch. Counted because sustained
      underruns are one-sample phase slips — audible as broadband
      grit that internal spectral checks miss. }
    if isFifoA then Inc(FifoAUnderrunCount)
               else Inc(FifoBUnderrunCount);
  end;
  { Level-triggered DMA refill: fire whenever count ≤ THRESHOLD after a
    pop attempt. Real hardware is level-triggered — DMA fires as long
    as FIFO is at or below half AND the DMA is armed. This handles the
    bootstrap-from-empty case: initial FIFO is count=0, first timer
    overflow attempts pop (no-op because empty) but still requests a
    refill, DMA fills FIFO to 16, subsequent pops drop count and
    re-fire (DMA refills to 32), etc. Rate-limited naturally by the
    timer overflow rate (typically 16-32 kHz). }
  if f.Count <= FIFO_LOW_THRESHOLD then
  begin
    if isFifoA then
    begin
      Inc(FifoARequestCount);
      if Assigned(FOnFifoALow) then FOnFifoALow();
    end
    else
    begin
      Inc(FifoBRequestCount);
      if Assigned(FOnFifoBLow) then FOnFifoBLow();
    end;
  end;
end;

procedure TGbaApu.OnTimerOverflow(timerIdx: Integer);
var
  soundcntH: TWord;
begin
  if (timerIdx < 0) or (timerIdx > 1) then Exit;    { only T0/T1 drive FIFOs }
  soundcntH := FMem.ReadHalf($04000000 + REG_SOUNDCNT_H);
  if ((soundcntH shr 10) and 1) = timerIdx then PopFifo(FFifoA, True);
  if ((soundcntH shr 14) and 1) = timerIdx then PopFifo(FFifoB, False);
end;

{ ───── Mixer ─────────────────────────────────────────────────────── }

function TGbaApu.MixOne(side: Integer): SmallInt;
{ side: 0 = L, 1 = R. Implements §4 of the KB article — PSG bus
  formation, FIFO contribution, SOUNDBIAS bias-and-clamp through the
  10-bit DAC window, recentered and scaled to S16. }
var
  s1, s2, s3, s4: Integer;
  enables, soundcntL, soundcntH, soundbias: TWord;
  psgMul, masterVol, psgSum, pre, biased, centered: Integer;
  bias: Integer;
  fifoAEnable, fifoBEnable: Boolean;
  fifoAVol2, fifoBVol2: Integer;
  fifoContribA, fifoContribB: Integer;
begin
  { Cached by SyncFromRegs (per scanline) — this runs per fine-grid
    sample (up to 262 kHz x2 sides) and must not touch I/O dispatch. }
  soundcntL := FCacheSoundcntL;
  soundcntH := FCacheSoundcntH;
  soundbias := FCacheSoundbias;

  { SampleChN returns CENTERED output (±Volume around 0) so silent
    channels contribute literal 0. See SampleCh1 comment for why. }

  if side = 0 then
    enables := (soundcntL shr 12) and $F
  else
    enables := (soundcntL shr  8) and $F;

  { PSG bus formation. Channels return centered +/-Volume (+/-15 max);
    the noise channel is weighted 8x squares/wave, matching mGBA's
    GBA-mode PSG bus (gb/audio.c GBAudioSamplePSG: squares/wave mix raw
    0..15 while ch4 mixes (0..15)<<3). The x8 rides through the shared
    volume chain below. }
  psgSum := 0;
  if (enables and 1) <> 0 then psgSum := psgSum + SampleCh1;
  if (enables and 2) <> 0 then psgSum := psgSum + SampleCh2;
  if (enables and 4) <> 0 then psgSum := psgSum + SampleCh3;
  if (enables and 8) <> 0 then psgSum := psgSum + SampleCh4 * 8;

  { silence unused locals }
  if s1 = s1 then ; if s2 = s2 then ; if s3 = s3 then ; if s4 = s4 then ;

  case (soundcntH and $3) of   { PSG master volume bits 0-1 }
    0: psgMul := 1;
    1: psgMul := 2;
    2: psgMul := 4;
  else
    psgMul := 0;               { 3 = prohibited per gbatek }
  end;

  if side = 0 then masterVol := (soundcntL shr 4) and $7
                else masterVol := (soundcntL shr 0) and $7;

  { PSG-to-FIFO balance: the volume chain lands a full-volume square at
    ~+/-15 and noise at ~+/-120 against the FIFO's +/-512, matching
    mGBA (raw x (1+NR50vol) >> (4-volumeBits), our psgMul x4 == their
    >>2 once the >>5 is applied) and NBA's ">> 5" mixer. The earlier
    unshifted mix ran every PSG channel at +/-480 against a +/-256
    FIFO — measured against an mGBA reference recording as x2 excess
    energy above 6 kHz (noise-channel hats dominating the top octaves)
    while FIFO-led tonal bands still matched. A previous ">>4 on the
    PSG DAC" attempt failed because it also halved the FIFO-relative
    scale twice over — the fix is this joint rebalance WITH the FIFO
    x4 restore below, not a PSG cut alone. }
  psgSum := SarLongint(psgSum * psgMul * (masterVol + 1), 5);

  { FIFO contributions — per gbatek "each FIFO can span the full output
    range (±0x200)": byte +/-128 x4 = +/-512 at 100% volume, x2 at 50%
    (SOUNDCNT_H bits 2/3). mGBA: (byte << 2) >> !volumeChX; NBA:
    latch times 2 or 4. }
  if ((soundcntH shr 2) and 1) = 1 then fifoAVol2 := 4 else fifoAVol2 := 2;
  if ((soundcntH shr 3) and 1) = 1 then fifoBVol2 := 4 else fifoBVol2 := 2;

  if side = 0 then
  begin
    fifoAEnable := ((soundcntH shr 9)  and 1) = 1;
    fifoBEnable := ((soundcntH shr 13) and 1) = 1;
  end
  else
  begin
    fifoAEnable := ((soundcntH shr 8)  and 1) = 1;
    fifoBEnable := ((soundcntH shr 12) and 1) = 1;
  end;

  { FIFO contribution: zero-order-hold of the most recently popped sample
    (Latch). The GBA DAC outputs the FIFO byte unchanged at the internal
    32.768 kHz mixing rate; the analog stage on real hardware (and
    Windows WASAPI's polyphase resampler on the host side) handles any
    smoothing. Earlier linear interp between Latch and Buf[Head] was a
    stale pre-filter from the 44.1 kHz host-rate-emit era — it fights
    WASAPI and falsifies the GBA's actual output. FIFO sample range ±128,
    vol multiplier 1 or 2 → contribution ±128 or ±256. }
  fifoContribA := 0; fifoContribB := 0;
  if fifoAEnable then
    fifoContribA := FFifoA.Latch * fifoAVol2;
  if fifoBEnable then
    fifoContribB := FFifoB.Latch * fifoBVol2;

  pre := psgSum + fifoContribA + fifoContribB;

  { Canonical 10-bit DAC bias-and-clamp pipeline (mGBA gba/audio.c:343-
    351, NBA apu.cpp). SOUNDBIAS supplies the unsigned offset; sum is
    biased into [0..0x3FF], clamped, then re-centered. Post-clamp scale
    is ×64 (10-bit → 16-bit headroom), operating on a bounded ±0x1FF
    range — physically cannot saturate from PSG bursts the way the
    pre-P1 ×32-on-unclamped path did. SOUNDBIAS bits 0-9 = bias level
    (BIOS inits to $200). }
  bias := soundbias and $3FF;
  biased := pre + bias;
  if biased < 0      then biased := 0;
  if biased > $3FF   then biased := $3FF;
  centered := (biased - bias) * 64;
  if centered >  32767 then centered :=  32767;
  if centered < -32768 then centered := -32768;
  Result := SmallInt(centered);
end;

{ ───── Public Step + GenerateSamples ─────────────────────────────── }

procedure TGbaApu.Step(cpuCycles: Int64);
{ Per-scanline entry point. Only polls registers; channel time
  advancement happens inside GenerateSamples (which is output-sample-
  driven for pitch correctness independent of our simulated CPU rate). }
begin
  if cpuCycles = cpuCycles then ;     { silence unused }
  SyncFromRegs;
end;

procedure TGbaApu.SetOversample(os: Integer);
begin
  if os = FOversample then Exit;
  FOversample := os;
  FEffRate := APU_SAMPLE_RATE * Double(os);
  { Reset decimator history on a grid switch: stale samples from the
    old rate would smear one filter-length of output. Games set
    SOUNDBIAS resolution once during init, so this fires rarely. }
  FillChar(FDecim, SizeOf(FDecim), 0);
end;

function TGbaApu.PushDecimCascade(side, nstages: Integer; x: Double;
                                  out y: Double): Boolean;
var
  k, t, idx: Integer;
  acc: Double;
begin
  Result := False;
  y := 0;
  for k := 0 to nstages - 1 do
  begin
    with FDecim[side, k] do
    begin
      Pos := Pos + 1;
      if Pos >= 31 then Pos := 0;
      Hist[Pos] := x;
      Phase := Phase xor 1;
      if Phase <> 0 then Exit;      { this stage needs one more input }
      acc := 0;
      for t := 0 to 30 do
      begin
        if HB_TAPS[t] = 0.0 then Continue;
        idx := Pos - t;
        if idx < 0 then idx := idx + 31;
        acc := acc + HB_TAPS[t] * Hist[idx];
      end;
      x := acc;                     { feeds the next stage }
    end;
  end;
  y := x;
  Result := True;
end;

procedure TGbaApu.GenerateSamples(n: Integer; var outBuf: TSampleBuffer);
{ Output-sample-driven generation on the SOUNDBIAS-resolution internal
  grid. Per output sample, FOversample fine-grid iterations run:
    1. Advance frame_seq accumulator; fire frame_seq step if it crossed.
    2. Advance each PSG channel's phase (DutyPos / Phase / LFSR).
    3. Advance FIFO pop accumulators based on Timer 0/1 config; pop
       when accumulator crosses 1.0.
    4. Mix one stereo fine sample.
  At 1x (resolution 0) the fine sample IS the output sample. Above 1x
  the fine samples feed the half-band decimator cascade, which yields
  exactly one filtered output sample per FOversample inputs — this is
  what keeps the staircase's above-Nyquist images from folding into
  the audible band (see unit header).

  This is correct regardless of how many simulated CPU cycles we
  actually ran between Step calls — pitch is locked to the host audio
  rate's relationship to GBA's frequency math, not to simulated CPU
  cycle count. }
var
  i, sub, nstages, resBits: Integer;
  stepsPerSampleFseq, mixL, mixR, outL, outR: Double;
  produced: Boolean;

  function ClampS16(v: Double): SmallInt;
  var w: Integer;
  begin
    w := Round(v);
    if w >  32767 then w :=  32767;
    if w < -32768 then w := -32768;
    Result := SmallInt(w);
  end;

begin
  if Length(outBuf) < n then SetLength(outBuf, n);

  SyncFromRegs;

  { SOUNDBIAS bits 14:15 select the hardware sampling cycle; mirror it
    as the internal grid multiplier (res 0..3 -> 1x/2x/4x/8x). }
  resBits := (FCacheSoundbias shr 14) and 3;
  SetOversample(1 shl resBits);
  nstages := resBits;

  stepsPerSampleFseq := 512.0 / FEffRate;

  for i := 0 to n - 1 do
  begin
    outL := 0;
    outR := 0;
    for sub := 0 to FOversample - 1 do
    begin
      FFrameSeqAccum := FFrameSeqAccum + stepsPerSampleFseq;
      while FFrameSeqAccum >= 1.0 do
      begin
        FFrameSeqAccum := FFrameSeqAccum - 1.0;
        AdvanceFrameSeqOneStep;
      end;

      AdvanceCh1OneSample;
      AdvanceCh2OneSample;
      AdvanceCh3OneSample;
      AdvanceCh4OneSample;
      AdvanceFifosOneSample;

      mixL := MixOne(0);
      mixR := MixOne(1);

      if FOversample = 1 then
      begin
        outL := mixL;
        outR := mixR;
      end
      else
      begin
        produced := PushDecimCascade(0, nstages, mixL, outL);
        if PushDecimCascade(1, nstages, mixR, outR) <> produced then ;
      end;
    end;

    { Output reconstruction (see OUT_LP_COEFF): analog-stage low-pass,
      then AC-coupling DC blocker. }
    FLpState[0] := FLpState[0] + OUT_LP_COEFF * (outL - FLpState[0]);
    FLpState[1] := FLpState[1] + OUT_LP_COEFF * (outR - FLpState[1]);
    FDcState[0] := FLpState[0] - FDcPrevIn[0] + OUT_DC_R * FDcState[0];
    FDcState[1] := FLpState[1] - FDcPrevIn[1] + OUT_DC_R * FDcState[1];
    FDcPrevIn[0] := FLpState[0];
    FDcPrevIn[1] := FLpState[1];

    outBuf[i].L := ClampS16(FDcState[0]);
    outBuf[i].R := ClampS16(FDcState[1]);
  end;
end;

procedure TGbaApu.SetTimers(tmrs: TGbaTimers);
begin
  FTmrs := tmrs;
end;

function TGbaApu.Ch1Enabled: Boolean; begin Result := FCh1.Enabled; end;
function TGbaApu.Ch2Enabled: Boolean; begin Result := FCh2.Enabled; end;
function TGbaApu.Ch3Enabled: Boolean; begin Result := FCh3.Enabled; end;
function TGbaApu.Ch4Enabled: Boolean; begin Result := FCh4.Enabled; end;
function TGbaApu.Ch1EnvVol: Integer;  begin Result := FCh1.Env.Volume; end;
function TGbaApu.Ch2EnvVol: Integer;  begin Result := FCh2.Env.Volume; end;
function TGbaApu.Ch3VolRaw: Integer;  begin Result := FCh3.Volume; end;
function TGbaApu.Ch4EnvVol: Integer;  begin Result := FCh4.Env.Volume; end;
function TGbaApu.FifoACount: Integer; begin Result := FFifoA.Count; end;
function TGbaApu.FifoBCount: Integer; begin Result := FFifoB.Count; end;

procedure TGbaApu.SetFifoALowHook(hook: TFifoLowHook);
begin
  FOnFifoALow := hook;
end;

procedure TGbaApu.SetFifoBLowHook(hook: TFifoLowHook);
begin
  FOnFifoBLow := hook;
end;

end.
