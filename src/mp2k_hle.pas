unit Mp2k_Hle;
{
  HLE of the GBA mp2k (Music Player 2000 / M4A) sound engine.

  Replaces parts of the cart's in-ROM mp2k engine with a Pascal
  implementation. Almost every commercial GBA title uses mp2k — some
  call BIOS sound SWIs ($19-$1F, $28-$29) for the audio work, some ship
  the engine entirely in cart code. We intercept both flavours.

  ── Why HLE this engine ──

  Two reasons stack:

  1. CORRECTNESS. mp2k engines call internal helper functions that
     depend on subtle behaviour of subsystems we don't perfectly model
     (hardware timers, DMA edge cases, BIOS sound work-area shape).
     Cart-side mp2k engines specifically can dead-lock during boot
     when one of these dependencies behaves slightly differently.
     Canonical example: a commercial mp2k title's ROM boot-stalls in a
     poll at $0808AE06 waiting for a Timer-2 ISR to set $03000F74. No
     static install path for that ISR exists in 8 MB of cart ROM — real
     hardware must reach the install via something we don't model.
     Bypassing the engine sidesteps the entire question.

  2. FIDELITY. The real engine runs at 16-32 kHz internal sample rate
     because that's what the GBA APU can stream via Direct Sound DMA at
     full game CPU budget. We can render at the host audio rate with
     cubic interpolation and proper reverb — a clean improvement.

  ── Phase A (this commit): boot-flag setter ──

  Detects the engine struct at the canonical $03000F6C address using a
  signature (struct[+12] = $04000108 = TM2CNT_L base, set by engine init
  when it binds to Timer 2). Each emulated frame, simulates the engine's
  per-IRQ countdown that the cart's Timer-2 ISR would do:
    - halfword at struct[+6] is a frame counter (typically inits to 40)
    - byte at struct[+8] is a "boot-ready" flag the engine polls
    - when counter hits 0, flag is set to 1
  Once the flag is set, the engine's boot poll exits and init continues.
  Sample rendering still uses the cart's mixer at this phase, so audio
  may sound subtly off until Phase B lands.

  ── Phase B (next): SoundInfo intercept + channel mix ──

  - Scan EWRAM periodically for the SoundInfo magic value (0x68736D54
    'Tmsh' for newer mp2k variants, 0x68736D53 'Smsh' for the BIOS
    variant).
  - When found, take over channel mixing guided by the engine's
    community documentation (Sappy/M4A research, GBATEK).
  - Per-frame: read SoundInfo, advance channel envelopes, sample
    waveforms, mix to stereo float buffer, feed our TGbaAudio output.

  ── Phase C (later): polish ──

  Cubic interpolation, reverb, accurate envelope state machine,
  compressed-sample (GBA "PROCSND") decoding.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes, Memory;

type
  TMp2kHle = class
  private
    FMem: TGbaMemory;

    { Whether the engine struct's signature has been detected. Toggles
      true once and stays true; we don't try to recover from games that
      tear down and re-init mp2k mid-run. Logged once on first detection
      so host diagnostics can show HLE engaged. }
    FEngineDetected: Boolean;

    { Phase-A counters for diagnostic surfacing in F12 dumps and end-of-
      run summaries. }
    FCountdownTicks: Int64;
    FBootFlagSet:    Int64;  { frame the boot flag was set, 0 = not yet }
  public
    constructor Create(mem: TGbaMemory);

    { Called once per emulated frame from gba_runner. Detects engine
      setup and performs the Phase-A countdown work. Cheap when the
      engine isn't yet set up (single memory read + compare). }
    procedure Tick(frame: Int64);

    property EngineDetected: Boolean read FEngineDetected;
    property CountdownTicks: Int64   read FCountdownTicks;
    property BootFlagSet:    Int64   read FBootFlagSet;
  end;

implementation

const
  { mp2k engine struct lives at $03000F6C in every mp2k cart we have on
    hand (commercial titles place it at exactly this IWRAM address). The
    address is hard-coded by the engine code itself, not configurable
    per-cart, so this constant is correct for ANY mp2k-using game. }
  MP2K_STRUCT_BASE = $03000F6C;

  { Field offsets within the engine struct (per commercial-title disasm
    + countdown_and_set_flag at $0808AC20 in a commercial mp2k title's
    ROM):
      +0   : Thumb fn ptr to SRAM helper (LDRB R0,[R0]; BX LR)
      +4   : packed config (sample count low, source low)
      +6   : countdown counter (halfword) — initial value typ. 40
      +8   : boot-ready flag (byte)  — what the engine's poll checks
      +12  : Timer-2 register address ($04000108) — signature field }
  MP2K_HELPER_FN  = MP2K_STRUCT_BASE + 0;
  MP2K_COUNTER    = MP2K_STRUCT_BASE + 6;
  MP2K_BOOT_FLAG  = MP2K_STRUCT_BASE + 8;
  MP2K_TIMER_ADDR = MP2K_STRUCT_BASE + 12;

  { TM2CNT_L hardware register — mp2k pinned to Timer 2 stores this here
    as part of init. Acts as our 'engine is set up' signature. }
  TIMER2_REG = $04000108;

constructor TMp2kHle.Create(mem: TGbaMemory);
begin
  inherited Create;
  FMem := mem;
  FEngineDetected := False;
  FCountdownTicks := 0;
  FBootFlagSet := 0;
end;

procedure TMp2kHle.Tick(frame: Int64);
var
  helperFn, timerAddr: TWord;
begin
  { Detect engine setup. The engine's struct-init writes a Thumb fn
    pointer to +0 and the timer-2 register address to +12. Until init
    runs, both are zero. The combination is the cleanest signature we
    have — engine code at $0808AC7C does these two writes back-to-back
    in setup. }
  helperFn  := FMem.ReadWord(MP2K_HELPER_FN);
  timerAddr := FMem.ReadWord(MP2K_TIMER_ADDR);

  if (helperFn = 0) or (timerAddr <> TIMER2_REG) then
    Exit;  { engine not set up yet }

  if not FEngineDetected then
  begin
    FEngineDetected := True;
    SafeLog(Format('mp2k_hle: engine detected at $%08x (helper=$%08x), frame %d',
      [TWord(MP2K_STRUCT_BASE), helperFn, frame]));
  end;

  { Phase-A: drive the cart-side Timer-2 ISR's boot-ready flag forward
    as fast as possible.

    The real-hardware ISR (countdown_and_set_flag at $0808AC20 in a
    commercial mp2k title's ROM) ticks a halfword counter at +6 down
    per Timer-2 IRQ (~16 IRQs per frame on hardware, ~9 in our
    slightly-undercounted emulation), setting the boot-ready flag at
    +8 when it hits zero. The engine's boot poll exits on flag != 0.
    After the poll exits, the game's setup ($0808AC7C) re-arms the next
    cycle by CLEARING the flag back to 0 and reloading the counter
    (see STRB R3=0,[R0=$03000F74] at $0808ACC6). Each cycle is one step
    of cart-side boot work — for the title that motivated this path,
    that is polling consecutive 8 KiB SRAM regions during the
    save-format check, which takes 8+ cycles total.

    Our first attempt decremented once per frame, which made each cycle
    cost ~40 frames vs the ~2.5 frames it costs on real hardware. With
    8+ such cycles plus more init steps, total boot time blew past 60
    seconds — far past interactive tolerance even though the boot was
    technically progressing (R5 advanced $0E00F07F → $0E00D07F across
    dumps, confirming linear save-walk progress).

    Switch to: set the flag every frame when it's zero. Each
    setup-clear/HLE-set cycle now costs exactly 2 frames (setup
    clears, next frame we set), making total boot work ~30× faster.
    Counter is forced to 0 too so any code reading it for diagnostic
    purposes sees a consistent state. Functionally equivalent to
    "boot-ready flag is always set when the poll runs", which is what
    real hardware effectively delivers at its IRQ rate. }
  if FMem.ReadByte(MP2K_BOOT_FLAG) = 0 then
  begin
    FMem.WriteByte(MP2K_BOOT_FLAG, 1);
    FMem.WriteHalf(MP2K_COUNTER, 0);
    Inc(FCountdownTicks);
    if FBootFlagSet = 0 then
    begin
      FBootFlagSet := frame;
      SafeLog(Format('mp2k_hle: first boot-ready flag set @ $%08x = 1, frame %d',
        [TWord(MP2K_BOOT_FLAG), frame]));
    end;
  end;
end;

end.
