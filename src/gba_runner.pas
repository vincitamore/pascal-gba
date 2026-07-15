unit Gba_Runner;
{
  Reusable GBA emulator driver. Owns the full pipeline lifecycle:
  create all subsystems → wire hooks → load BIOS + ROM + save → run the
  scheduler loop until the display window closes (or a frame limit
  hits) → flush save + tear down.

  ── Why a unit ──

  Both the console test harness (`gbarun.pas`) and the Lazarus app
  shell (`lazarus/gbashell/`) drive the emulator through the same path.
  Factoring the driver into a unit was the precondition for the shell
  to do ROM validation without per-ROM harnesses.

  ── API ──

  Build a `TGbaRunOptions`, call `RunGba(opts)`. The procedure blocks
  until the display window closes. On return, save has been flushed to
  disk; all subsystems are freed.

  Diagnostic output goes to stdout (frame-60 progress, end-of-run
  summary). For headless or shell-launched runs, the caller can redirect
  or ignore. `opts.Verbose` and `opts.PrintSummary` gate the volume.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Windows, GbaTypes, Memory, ArmCore, Cart, Ppu, Display,
  Irq, Timers, Dma, Input, Bios_Hle, Apu, Audio, Wav_Dump, Save,
  Mp2k_Hle, Replay, Dbg_Log, Game_Snapshot,
  Classes, FpImage, FpWritePNG;

type
  TGbaRunOptions = record
    RomPath:        string;        { required }
    BiosPath:       string;        { required }
    DumpAudioPath:  string;        { '' = no WAV dump }
    MaxFrames:      Integer;       { 0 = run until window closes }
    WindowScale:    Integer;       { typically 3 (= 720x480 window) }
    WindowTitle:    string;        { e.g. "Pascal GBA" }
    Verbose:        Boolean;       { print frame-60 progress lines }
    PrintSummary:   Boolean;       { print end-of-run subsystem summary }
    DebugPokeAddr:  TWord;          { 0 = disabled; otherwise IWRAM address to set each frame }
    DebugPokeByte:  TByte;

    { Headless / dev-harness flags. }
    Headless:       Boolean;       { no Win32 window, no waveOut, no 60 FPS pacer }
    ScreenshotPath: string;        { '' = no PNG capture }
    ScreenshotFrame: Integer;      { 0 = end of run; >0 = at the END of that frame number (1-indexed) }

    { Scripted input replay / recording. }
    ReplayPath:     string;        { '' = no replay; otherwise read script before run }
    RecordPath:     string;        { '' = no record; otherwise capture input events to script on exit }

    { DbgLog ring buffer tail dump at shutdown. }
    DbglogOutPath:  string;        { '' = no dump; otherwise write captured DbgLog tail to this file at exit }
  end;

function DefaultRunOptions: TGbaRunOptions;
procedure RunGba(const opts: TGbaRunOptions);

implementation

const
  CYCLES_PER_SCANLINE = 1232;
  CYCLES_VISIBLE      = 960;   { drawing cycles (per GBATEK §15.1) }
  CYCLES_HBLANK       = 272;   { 1232 - 960 — HBlank period }
  SCANLINES_VISIBLE   = 160;
  SCANLINES_TOTAL     = 228;

function IrqSourceName(idx: Integer): string;
{ GBA per-source IRQ index → name. Indices match the bit-cascade in the
  game's IRQ handler: V-blank=0 .. GamePak=13. }
begin
  case idx of
    0:  Result := 'V-blank';
    1:  Result := 'H-blank';
    2:  Result := 'V-count';
    3:  Result := 'Timer0';
    4:  Result := 'Timer1';
    5:  Result := 'Timer2';
    6:  Result := 'Timer3';
    7:  Result := 'SerialComm';
    8:  Result := 'DMA0';
    9:  Result := 'DMA1';
    10: Result := 'DMA2';
    11: Result := 'DMA3';
    12: Result := 'Keypad';
    13: Result := 'GamePak';
  else
    Result := '(unused)';
  end;
end;

function SwiName(num: Integer): string;
{ Human-readable name for known BIOS SWI numbers (GBA BIOS, per GBATEK).
  Returns '?' for SWIs without a documented purpose so the dump signals
  'unexpected SWI seen' rather than silently labelling it. }
begin
  case num of
    $00: Result := 'SoftReset';
    $01: Result := 'RegisterRamReset';
    $02: Result := 'Halt';
    $03: Result := 'Stop';
    $04: Result := 'IntrWait';
    $05: Result := 'VBlankIntrWait';
    $06: Result := 'Div';
    $07: Result := 'DivArm';
    $08: Result := 'Sqrt';
    $09: Result := 'ArcTan';
    $0A: Result := 'ArcTan2';
    $0B: Result := 'CpuSet';
    $0C: Result := 'CpuFastSet';
    $0D: Result := 'GetBiosChecksum';
    $0E: Result := 'BgAffineSet';
    $0F: Result := 'ObjAffineSet';
    $10: Result := 'BitUnPack';
    $11: Result := 'LZ77UnCompWram';
    $12: Result := 'LZ77UnCompVram';
    $13: Result := 'HuffUnComp';
    $14: Result := 'RLUnCompWram';
    $15: Result := 'RLUnCompVram';
    $16: Result := 'Diff8bitUnFilterWram';
    $17: Result := 'Diff8bitUnFilterVram';
    $18: Result := 'Diff16bitUnFilter';
    $19: Result := 'SoundBias';
    $1A: Result := 'SoundDriverInit';
    $1B: Result := 'SoundDriverMode';
    $1C: Result := 'SoundDriverMain';
    $1D: Result := 'SoundDriverVSync';
    $1E: Result := 'SoundChannelClear';
    $1F: Result := 'MidiKey2Freq';
    $20: Result := 'MusicPlayerOpen';
    $21: Result := 'MusicPlayerStart';
    $22: Result := 'MusicPlayerStop';
    $23: Result := 'MusicPlayerContinue';
    $24: Result := 'MusicPlayerFadeOut';
    $25: Result := 'MultiBoot';
    $26: Result := 'HardReset';
    $27: Result := 'CustomHalt';
    $28: Result := 'SoundDriverVSyncOff';
    $29: Result := 'SoundDriverVSyncOn';
    $2A: Result := 'SoundGetJumpList';
  else
    Result := '?';
  end;
end;

function FindDispatchTable(mem: TGbaMemory; handlerBase: TWord): TWord;
(* The GBA IRQ handler installed by mp2k-using games has a stereotyped
   ARM-mode dispatch tail:

     LDR  R1, [PC, #imm12]    ; 0xE59F1xxx  ← load table base from literal pool
     ADD  R1, R1, R2          ; 0xE0811002  ← R2 = source_idx * 4
     LDR  R0, [R1]            ; 0xE5910000  ← per-source fn ptr
     PUSH {LR}                ; 0xE92D4000
     ADD  LR, PC, #0          ; 0xE28FE000
     BX   R0                  ; 0xE12FFF10

   The table address itself differs per ROM (and per build): one
   commercial title keeps it at $03002FE0 (literal at handler+$128),
   another at $03006630 (literal at handler+$134). Resolve it dynamically
   by scanning the first 1 KiB
   of the handler for the 4-instruction prefix and following the LDR's
   PC-relative offset to the literal pool. Returns 0 if the handler
   doesn't match the pattern (e.g. a non-mp2k cart). *)
var
  pc, ldrR1, addR1, ldrR0, literalAddr: TWord;
  off: Integer;
begin
  Result := 0;
  pc := handlerBase;
  while pc < handlerBase + 1024 do
  begin
    ldrR1 := mem.ReadWord(pc);
    addR1 := mem.ReadWord(pc + 4);
    ldrR0 := mem.ReadWord(pc + 8);
    if ((ldrR1 and $FFFFF000) = $E59F1000) and
       (addR1 = $E0811002) and
       (ldrR0 = $E5910000) then
    begin
      off := ldrR1 and $FFF;
      literalAddr := pc + 8 + TWord(off);
      Result := mem.ReadWord(literalAddr);
      Exit;
    end;
    Inc(pc, 4);
  end;
end;

function BuildDefaultDumpPath(mem: TGbaMemory; frame: Int64): string;
{ Compose the default timestamped dump path next to the host EXE:
  dumps/dump_<gameCode>_<yyyymmdd_hhnnss>_fN.txt. Used by the F12
  keypress path (no explicit destination requested); the replay-driven
  `dump-state` action supplies its own explicit path instead. }
var
  dumpDir, gameCode: string;
  i: Integer;
  b: TByte;
begin
  dumpDir := ExtractFilePath(ParamStr(0)) + 'dumps';
  if not DirectoryExists(dumpDir) then ForceDirectories(dumpDir);

  { Cart-header game code @ $080000AC (4 ASCII bytes, e.g. AWRE / BPRE).
    This is the canonical identity of the ROM the emulator is currently
    running — encoded in the cart image itself so it survives
    renamed/relocated files. Sanitised down to A-Z/0-9 to keep the
    filename portable. }
  gameCode := '';
  for i := 0 to 3 do
  begin
    b := mem.ReadByte($080000AC + TWord(i));
    if ((b >= Ord('A')) and (b <= Ord('Z'))) or
       ((b >= Ord('0')) and (b <= Ord('9'))) then
      gameCode := gameCode + Chr(b)
    else
      gameCode := gameCode + '_';
  end;

  Result := IncludeTrailingPathDelimiter(dumpDir) +
            Format('dump_%s_%s_f%d.txt',
              [gameCode, FormatDateTime('yyyymmdd_hhnnss', Now), frame]);
end;

procedure DumpDebugState(mem: TGbaMemory; cpu: TArmCore; gdma: TGbaDma;
  gapu: TGbaApu; intc: TGbaIrq; tmrs: TGbaTimers; dbglog: TDbgLog;
  frame: Int64; const path: string);
{ Write a comprehensive emulator state dump to `path`. Captures everything
  useful for diagnosing 'why is this game stuck/glitching':
    - Timestamp + frame number + ROM info
    - CPU registers (R0-R15, CPSR, banked-mode SPs, halt state)
    - Memory IE/IF/IME + IntrCheck flag
    - Sound regs (SOUNDCNT_L/H/X, SOUNDBIAS)
    - All four timers (reload, prescaler, enabled)
    - DMA per-channel state (transfer count, last SAD/DAD, arm count,
      distinct SADs)
    - APU activity counters (per-channel retrigger, FIFO push counts)
    - 256 bytes of ROM at PC (so we can decode the current instruction
      sequence)
    - 256 bytes of the IRQ handler at $03007FFC
    - 32 bytes of the mp2k engine state struct at $03000F6C
  Two callers today: the F12 keypress in the windowed display loop (path
  supplied by `BuildDefaultDumpPath` above) and the replay engine's
  `dump-state` action (path supplied by the script). Written via
  SafeLog/SafeLogErr to honor the console/GUI rules. }
var
  f: Text;
  parent, gameCode: string;
  i, j: Integer;
  line: string;
  t2Fn, dispatchTable, structFn: TWord;
  b: TByte;
begin
  { Ensure the parent dir exists. Replay-driven dumps commonly target
    a per-run output directory (e.g. bin/dumps/) that may not yet
    exist on a clean checkout; the F12 path's dumps/ folder is already
    materialised by BuildDefaultDumpPath. }
  parent := ExtractFilePath(path);
  if (parent <> '') and (not DirectoryExists(parent)) then
    ForceDirectories(parent);

  { Cart-header game code @ $080000AC (4 ASCII bytes: title initials,
    unit, destination). Used inside the dump body below to print
    'GameCode = "..."'; the default-path builder re-derives this when
    constructing the filename, but the work is 4 byte reads -- not
    worth threading. }
  gameCode := '';
  for i := 0 to 3 do
  begin
    b := mem.ReadByte($080000AC + TWord(i));
    if ((b >= Ord('A')) and (b <= Ord('Z'))) or
       ((b >= Ord('0')) and (b <= Ord('9'))) then
      gameCode := gameCode + Chr(b)
    else
      gameCode := gameCode + '_';
  end;

  AssignFile(f, path);
  try
    Rewrite(f);
  except
    on E: Exception do
    begin
      SafeLogErr(Format('dump-state: failed to open %s — %s', [path, E.Message]));
      Exit;
    end;
  end;
  try
    Writeln(f, '═══════════════════════════════════════════════════════════════');
    Writeln(f, Format('  Pascal GBA debug dump  %s  frame %d',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), frame]));
    Writeln(f, '═══════════════════════════════════════════════════════════════');
    Writeln(f);

    { Cart-header info. Title @ $080000A0 (12 bytes ASCII, sometimes
      null-padded), game code @ $080000AC (4 bytes), maker code @
      $080000B0 (2 bytes). Print exactly what's in the cart so there
      is zero ambiguity about which ROM produced this dump regardless
      of filename or how the dump file is moved around afterwards. }
    Writeln(f, '── Cart info ──');
    line := '  Title  = "';
    for i := 0 to 11 do
    begin
      b := mem.ReadByte($080000A0 + TWord(i));
      if (b >= 32) and (b < 127) then line := line + Chr(b)
      else if b = 0 then break
      else line := line + '?';
    end;
    line := line + '"';
    Writeln(f, line);
    Writeln(f, Format('  GameCode = "%s"   MakerCode = "%s%s"',
      [gameCode,
       Chr(mem.ReadByte($080000B0)),
       Chr(mem.ReadByte($080000B1))]));
    Writeln(f);

    Writeln(f, '── CPU state ──');
    Writeln(f, Format('  PC=%s  CPSR=%s  mode=%s  T=%d  halted=%d',
      [IntToHex(cpu.GetReg(R_PC), 8), IntToHex(cpu.State.CPSR, 8),
       IntToHex(cpu.State.CPSR and $1F, 2),
       Ord((cpu.State.CPSR and CPSR_T) <> 0), Ord(cpu.State.Halted)]));
    Writeln(f, Format('  R0-R3   = %s %s %s %s',
      [IntToHex(cpu.GetReg(0), 8), IntToHex(cpu.GetReg(1), 8),
       IntToHex(cpu.GetReg(2), 8), IntToHex(cpu.GetReg(3), 8)]));
    Writeln(f, Format('  R4-R7   = %s %s %s %s',
      [IntToHex(cpu.GetReg(4), 8), IntToHex(cpu.GetReg(5), 8),
       IntToHex(cpu.GetReg(6), 8), IntToHex(cpu.GetReg(7), 8)]));
    Writeln(f, Format('  R8-R12  = %s %s %s %s %s',
      [IntToHex(cpu.GetReg(8), 8), IntToHex(cpu.GetReg(9), 8),
       IntToHex(cpu.GetReg(10), 8), IntToHex(cpu.GetReg(11), 8),
       IntToHex(cpu.GetReg(12), 8)]));
    Writeln(f, Format('  SP=%s  LR=%s',
      [IntToHex(cpu.GetReg(R_SP), 8), IntToHex(cpu.GetReg(R_LR), 8)]));
    Writeln(f, Format('  Banked: R_irq_sp=%s  R_svc_sp=%s  R_usr_sp=%s',
      [IntToHex(cpu.State.R_irq_sp, 8), IntToHex(cpu.State.R_svc_sp, 8),
       IntToHex(cpu.State.R_usr_sp, 8)]));
    Writeln(f, Format('  IRQ entries: %d', [cpu.IrqEntryCount]));
    Writeln(f);

    Writeln(f, '── IRQ + Timer state ──');
    Writeln(f, Format('  IE=%s  IF=%s  IME=%s',
      [IntToHex(mem.ReadHalf($04000200), 4),
       IntToHex(mem.ReadHalf($04000202), 4),
       IntToHex(mem.ReadHalf($04000208), 4)]));
    Writeln(f, Format('  IntrCheck@$03007FF8=%s   @$03FFFFF8=%s',
      [IntToHex(mem.ReadWord($03007FF8), 8),
       IntToHex(mem.ReadWord($03FFFFF8), 8)]));
    for i := 0 to 3 do
      if tmrs.IsEnabled(i) then
        Writeln(f, Format('  Timer %d: enabled  reload=%s  prescaler=%d',
          [i, IntToHex(tmrs.GetReload(i), 4), tmrs.GetPrescaler(i)]));
    Writeln(f);

    Writeln(f, '── Sound state ──');
    Writeln(f, Format('  SOUNDCNT_L=%s  SOUNDCNT_H=%s  SOUNDCNT_X=%s  SOUNDBIAS=%s',
      [IntToHex(mem.ReadHalf($04000080), 4),
       IntToHex(mem.ReadHalf($04000082), 4),
       IntToHex(mem.ReadHalf($04000084), 4),
       IntToHex(mem.ReadHalf($04000088), 4)]));
    Writeln(f, Format('  APU: ch1 retrig=%d  ch2=%d  ch3=%d  ch4=%d',
      [gapu.Ch1RetriggerCount, gapu.Ch2RetriggerCount,
       gapu.Ch3RetriggerCount, gapu.Ch4RetriggerCount]));
    Writeln(f, Format('  APU: FIFO-A pushes=%d  FIFO-B pushes=%d',
      [gapu.FifoAPushCount, gapu.FifoBPushCount]));
    Writeln(f);

    Writeln(f, '── DMA state ──');
    for i := 0 to 3 do
      if gdma.TransferCount[i] > 0 then
        Writeln(f, Format('  DMA%d: %d transfers  last src=%s dst=%s len=%s',
          [i, gdma.TransferCount[i],
           IntToHex(gdma.LastTransferSad[i], 8),
           IntToHex(gdma.LastTransferDad[i], 8),
           IntToHex(gdma.LastTransferLen[i], 8)]));
    Writeln(f, '  Re-arm pattern:');
    for i := 0 to 3 do
      if gdma.EnableEdgeCount[i] > 0 then
      begin
        line := Format('    DMA%d: %d arms, %d distinct SADs:',
          [i, gdma.EnableEdgeCount[i], gdma.DistinctSadCount[i]]);
        for j := 0 to gdma.DistinctSadCount[i] - 1 do
          line := line + ' ' + IntToHex(gdma.DistinctSads[i, j], 8);
        Writeln(f, line);
      end;
    Writeln(f);

    Writeln(f, '── ROM bytes at PC (256 bytes around PC&~$1F) ──');
    for i := 0 to 7 do
    begin
      line := Format('  $%08x:', [(cpu.GetReg(R_PC) and not TWord($1F)) + TWord(i * 32)]);
      for j := 0 to 31 do
        line := line + ' ' + IntToHex(
          mem.ReadByte((cpu.GetReg(R_PC) and not TWord($1F)) + TWord(i * 32 + j)), 2);
      Writeln(f, line);
    end;
    Writeln(f);

    Writeln(f, Format('── IRQ handler at $%08x (512 bytes — includes jump-table literal pool) ──',
      [mem.ReadWord($03007FFC)]));
    for i := 0 to 15 do
    begin
      line := Format('  $%08x:',
        [mem.ReadWord($03007FFC) + TWord(i * 32)]);
      for j := 0 to 31 do
        line := line + ' ' + IntToHex(
          mem.ReadByte(mem.ReadWord($03007FFC) + TWord(i * 32 + j)), 2);
      Writeln(f, line);
    end;
    Writeln(f);

    Writeln(f, '── mp2k engine struct @ $03000F6C (32 bytes) ──');
    line := '  ';
    for i := 0 to 31 do
      line := line + ' ' + IntToHex(mem.ReadByte($03000F6C + TWord(i)), 2);
    Writeln(f, line);
    Writeln(f, Format('  As words: %s %s %s %s %s %s %s %s',
      [IntToHex(mem.ReadWord($03000F6C), 8),
       IntToHex(mem.ReadWord($03000F70), 8),
       IntToHex(mem.ReadWord($03000F74), 8),
       IntToHex(mem.ReadWord($03000F78), 8),
       IntToHex(mem.ReadWord($03000F7C), 8),
       IntToHex(mem.ReadWord($03000F80), 8),
       IntToHex(mem.ReadWord($03000F84), 8),
       IntToHex(mem.ReadWord($03000F88), 8)]));
    Writeln(f);

    { IRQ dispatch table: the game's IRQ handler dispatches per-source
      via a function-pointer table in IWRAM. One commercial title keeps
      the table at $03002FE0 (handler in ROM at $080000FC); another at
      $03006630 (handler copied to IWRAM at $03000718) — different per
      ROM/build. FindDispatchTable resolves the address dynamically by
      pattern-matching the dispatch tail in the handler. 0 means we
      couldn't find the pattern. }
    dispatchTable := FindDispatchTable(mem, mem.ReadWord($03007FFC));
    if dispatchTable <> 0 then
    begin
      Writeln(f, Format('── IRQ dispatch table @ $%08x (64 bytes, 16 word slots) ──',
        [dispatchTable]));
      for i := 0 to 15 do
      begin
        line := Format('  [%2d] +%3d  %-10s = $%08x',
          [i, i * 4,
           IrqSourceName(i),
           mem.ReadWord(dispatchTable + TWord(i * 4))]);
        Writeln(f, line);
      end;
      Writeln(f);

      { Follow Timer-2's function pointer: table[5] holds a Thumb fn
        pointer (LSB set). Dump 256 bytes from the function body so we
        can disassemble it offline regardless of whether it lives in
        ROM (08xxxxxx) or IWRAM (03xxxxxx). Mask LSB off — the THUMB
        bit is interpretation, not address. }
      t2Fn := mem.ReadWord(dispatchTable + 5 * 4) and not TWord($1);
      Writeln(f, Format('── Timer-2 dispatch fn @ $%08x (256 bytes, THUMB) ──', [t2Fn]));
      for i := 0 to 7 do
      begin
        line := Format('  $%08x:', [t2Fn + TWord(i * 32)]);
        for j := 0 to 31 do
          line := line + ' ' + IntToHex(mem.ReadByte(t2Fn + TWord(i * 32 + j)), 2);
        Writeln(f, line);
      end;
      Writeln(f);
    end
    else
    begin
      Writeln(f, '── IRQ dispatch table: NOT FOUND (handler pattern did not match) ──');
      Writeln(f);
    end;

    { Broader IWRAM window covering the mp2k struct neighbourhood + the
      handler vector area. $03000F00..$03000FFF covers struct base $03000F6C
      ± context; useful for cross-referencing R7-relative pointers the game
      stores around the engine struct. }
    Writeln(f, '── IWRAM @ $03000F00..$03000FFF (256 bytes — mp2k context) ──');
    for i := 0 to 7 do
    begin
      line := Format('  $%08x:', [$03000F00 + TWord(i * 32)]);
      for j := 0 to 31 do
        line := line + ' ' + IntToHex(mem.ReadByte($03000F00 + TWord(i * 32 + j)), 2);
      Writeln(f, line);
    end;
    Writeln(f);

    { Follow mp2k_struct[0] = IWRAM-installed helper function pointer.
      A commercial mp2k title's stall poll calls (*struct[0])($0E00F07F)
      via a BX-R1 trampoline at $0808BBC0 and exits if the return value
      equals 2. The function lives in IWRAM around $03007C4C
      (struct[0] = $03007C4D, Thumb bit set). Dump 128 bytes of it so we
      can decode what it actually reads and returns. }
    structFn := mem.ReadWord($03000F6C) and not TWord($1);
    if (structFn >= $03000000) and (structFn < $03008000) then
    begin
      Writeln(f, Format('── mp2k_struct[0] helper fn @ $%08x (128 bytes, THUMB) ──',
        [structFn]));
      for i := 0 to 3 do
      begin
        line := Format('  $%08x:', [structFn + TWord(i * 32)]);
        for j := 0 to 31 do
          line := line + ' ' + IntToHex(mem.ReadByte(structFn + TWord(i * 32 + j)), 2);
        Writeln(f, line);
      end;
      Writeln(f);
    end;

    { Upper IWRAM @ $03007C00..$03007FFF — covers the mp2k helper region,
      the IRQ stack, and the BIOS-area flags at $03007FF8 / $03007FFC.
      Commercial-title dumps confirm boot-loader-installed helpers live
      just below $03007FE0; capture this whole 1 KiB window so
      cross-referencing stays scrollable in one place. }
    Writeln(f, '── IWRAM @ $03007C00..$03007FFF (1024 bytes — upper IWRAM) ──');
    for i := 0 to 31 do
    begin
      line := Format('  $%08x:', [$03007C00 + TWord(i * 32)]);
      for j := 0 to 31 do
        line := line + ' ' + IntToHex(mem.ReadByte($03007C00 + TWord(i * 32 + j)), 2);
      Writeln(f, line);
    end;
    Writeln(f);

    { Save-region probe @ $0E00F060..$0E00F0FF (160 bytes around offset
      $F07F that a commercial title's poll checks). Helps confirm whether
      the SRAM helper's return value matches what's actually in the save
      backend. If our save returns 0xFF and the game expects 2, this row
      tells us immediately. }
    Writeln(f, '── Save @ $0E00F060..$0E00F0FF (160 bytes — commercial poll target) ──');
    for i := 0 to 4 do
    begin
      line := Format('  $%08x:', [$0E00F060 + TWord(i * 32)]);
      for j := 0 to 31 do
        line := line + ' ' + IntToHex(mem.ReadByte($0E00F060 + TWord(i * 32 + j)), 2);
      Writeln(f, line);
    end;
    Writeln(f);

    { OAM ($07000000, 1 KiB) — sprite attribute table. 128 sprites × 8 bytes.
      Title-screen artifacts (blue/white striped rectangles overlaying
      character art) are sprites rendering as stale tile patterns; capturing
      OAM identifies the offending slots. Per-sprite decoding:
        Attr0: y(0-7) | affine(8) | disable/dblsz(9) | mode(10-11) |
               mosaic(12) | pal8bpp(13) | shape(14-15)
        Attr1: x(0-8) | (affine_idx OR HF(12)+VF(13))(9-13) | size(14-15)
        Attr2: tile(0-9) | priority(10-11) | palBank(12-15) }
    Writeln(f, '── OAM @ $07000000 (1024 bytes, 128 sprites × 8 bytes) ──');
    for i := 0 to 31 do
    begin
      line := Format('  $%08x:', [$07000000 + TWord(i * 32)]);
      for j := 0 to 31 do
        line := line + ' ' + IntToHex(mem.ReadByte($07000000 + TWord(i * 32 + j)), 2);
      Writeln(f, line);
    end;
    Writeln(f);

    { OBJ tile data ($06010000, first 1 KiB = first 32 4bpp tile slots).
      If sprites render garbage, this is where the source pixels live.
      An all-zero region with sprites pointing at it would produce solid-
      color rectangles (palette index 0 = transparent normally); the
      striped pattern in the screenshot suggests the data is genuinely
      garbage-like (alternating bytes). }
    Writeln(f, '── OBJ VRAM @ $06010000 (1024 bytes — first 32 sprite tile slots) ──');
    for i := 0 to 31 do
    begin
      line := Format('  $%08x:', [$06010000 + TWord(i * 32)]);
      for j := 0 to 31 do
        line := line + ' ' + IntToHex(mem.ReadByte($06010000 + TWord(i * 32 + j)), 2);
      Writeln(f, line);
    end;
    Writeln(f);

    { OBJ palette @ $05000200 (512 bytes, 256 BGR555 entries). }
    Writeln(f, '── OBJ palette @ $05000200 (512 bytes, 256 BGR555 colors) ──');
    for i := 0 to 15 do
    begin
      line := Format('  $%08x:', [$05000200 + TWord(i * 32)]);
      for j := 0 to 31 do
        line := line + ' ' + IntToHex(mem.ReadByte($05000200 + TWord(i * 32 + j)), 2);
      Writeln(f, line);
    end;
    Writeln(f);

    { DISPCNT decoded — answer 'is OBJ enabled, what mapping mode' without
      re-decoding by hand. }
    Writeln(f, Format('── DISPCNT = $%04x ──', [mem.ReadHalf($04000000)]));
    Writeln(f, Format('  bgMode=%d  frameSel=%d  hbi=%d  objMap=%dD  forcedBlank=%d',
      [mem.ReadHalf($04000000) and 7,
       (mem.ReadHalf($04000000) shr 4) and 1,
       (mem.ReadHalf($04000000) shr 5) and 1,
       Integer(((mem.ReadHalf($04000000) shr 6) and 1) + 1),
       (mem.ReadHalf($04000000) shr 7) and 1]));
    Writeln(f, Format('  BG0=%d BG1=%d BG2=%d BG3=%d OBJ=%d  WIN0=%d WIN1=%d WINOBJ=%d',
      [(mem.ReadHalf($04000000) shr  8) and 1,
       (mem.ReadHalf($04000000) shr  9) and 1,
       (mem.ReadHalf($04000000) shr 10) and 1,
       (mem.ReadHalf($04000000) shr 11) and 1,
       (mem.ReadHalf($04000000) shr 12) and 1,
       (mem.ReadHalf($04000000) shr 13) and 1,
       (mem.ReadHalf($04000000) shr 14) and 1,
       (mem.ReadHalf($04000000) shr 15) and 1]));
    Writeln(f);

    { Window, blending, and BG-control registers. A commercial title's
      title-screen diagonal reveal uses WIN0/WIN1 to clip the cinematic,
      BLDCNT for the alpha-blend curtain, and per-scanline writes (HDMA)
      to either WIN0H or WIN1H. Capturing all of these at once eliminates
      guesswork about which window is active and where its edges are. }
    Writeln(f, '── PPU IO regs ──');
    Writeln(f, Format('  DISPSTAT=%s  VCOUNT=%s',
      [IntToHex(mem.ReadHalf($04000004), 4),
       IntToHex(mem.ReadHalf($04000006), 4)]));
    Writeln(f, Format('  WIN0H=%s (x1=%d x2=%d)  WIN1H=%s (x1=%d x2=%d)',
      [IntToHex(mem.ReadHalf($04000040), 4),
       (mem.ReadHalf($04000040) shr 8) and $FF,
        mem.ReadHalf($04000040)        and $FF,
       IntToHex(mem.ReadHalf($04000042), 4),
       (mem.ReadHalf($04000042) shr 8) and $FF,
        mem.ReadHalf($04000042)        and $FF]));
    Writeln(f, Format('  WIN0V=%s (y1=%d y2=%d)  WIN1V=%s (y1=%d y2=%d)',
      [IntToHex(mem.ReadHalf($04000044), 4),
       (mem.ReadHalf($04000044) shr 8) and $FF,
        mem.ReadHalf($04000044)        and $FF,
       IntToHex(mem.ReadHalf($04000046), 4),
       (mem.ReadHalf($04000046) shr 8) and $FF,
        mem.ReadHalf($04000046)        and $FF]));
    Writeln(f, Format('  WININ=%s (in0=%s in1=%s)  WINOUT=%s (out=%s obj=%s)',
      [IntToHex(mem.ReadHalf($04000048), 4),
       IntToHex( mem.ReadHalf($04000048)        and $3F, 2),
       IntToHex((mem.ReadHalf($04000048) shr 8) and $3F, 2),
       IntToHex(mem.ReadHalf($0400004A), 4),
       IntToHex( mem.ReadHalf($0400004A)        and $3F, 2),
       IntToHex((mem.ReadHalf($0400004A) shr 8) and $3F, 2)]));
    Writeln(f, Format('  BLDCNT=%s  BLDALPHA=%s  BLDY=%s',
      [IntToHex(mem.ReadHalf($04000050), 4),
       IntToHex(mem.ReadHalf($04000052), 4),
       IntToHex(mem.ReadHalf($04000054), 4)]));
    Writeln(f, Format('  BG0CNT=%s  BG1CNT=%s  BG2CNT=%s  BG3CNT=%s',
      [IntToHex(mem.ReadHalf($04000008), 4),
       IntToHex(mem.ReadHalf($0400000A), 4),
       IntToHex(mem.ReadHalf($0400000C), 4),
       IntToHex(mem.ReadHalf($0400000E), 4)]));
    Writeln(f);

    { SWI usage tally. TArmCore.SwiExecCount tallies every SWI executed
      regardless of whether the BIOS_HLE hook handled it (the hook isn't
      installed today — BIOS handles all SWIs natively). Nonzero entries
      are PROOF the SWI was actually invoked by the running game code.
      Critical for diagnosing 'did init reach the sound subsystem' vs
      'init stalled before sound init'. }
    Writeln(f, '── SWI call tally (nonzero only) ──');
    for i := 0 to 255 do
      if cpu.SwiExecCount[i] > 0 then
        Writeln(f, Format('  SWI $%02X = %d   %s',
          [i, cpu.SwiExecCount[i], SwiName(i)]));
    Writeln(f);

    { Intc is unused parameter — silence hint. }
    if intc = intc then ;

    { Game-side DbgLog ring buffer. The last N messages
      the cart wrote via the Pascal `DbgLog` helper (or any code
      following the EWRAM $0203FF80 convention). }
    dbglog.WriteTail(f);
    Writeln(f);

    Writeln(f, '── End of dump ──');
  finally
    CloseFile(f);
  end;

  SafeLog(Format('dump-state -> %s', [path]));
end;

procedure DumpGameSnapshot(mem: TGbaMemory; const path: string);
{ Read the cart-side TGameSnapshot mirror struct
  from EWRAM at $0203F000 and write a human-readable text dump to
  `path`. Schema definitions live in Game_Snapshot unit (shared
  with the cart's aw_snapshot.pas by convention + version validation).

  Wired into the replay engine's `dump-game PATH` action: when that
  action fires at frame N, this procedure reads the snapshot region
  post-Tick (which is when aw_game.GameTick wrote it) and produces
  a greppable game-state dump.

  Returns silently after writing; emits a `dump-game -> <path>`
  SafeLog confirmation. On invalid magic / version mismatch, writes
  a clear stub to the output file so a reader can see the
  diagnosis. }
var
  snap: TGameSnapshot;
  buf: array[0..SizeOf(TGameSnapshot) - 1] of Byte;
  f: Text;
  i, mapIdx, gx, gy, captureTileCount: Integer;
  parentDir: string;
begin
  { Ensure parent directory exists (mirror DumpDebugState's behavior). }
  parentDir := ExtractFilePath(path);
  if (parentDir <> '') and (not DirectoryExists(parentDir)) then
    ForceDirectories(parentDir);

  { Read raw bytes from cart EWRAM via TGbaMemory.ReadByte. Slow-path
    is fine -- dump-game fires per replay action, not per frame. }
  for i := 0 to High(buf) do
    buf[i] := Byte(mem.ReadByte(TWord(LongWord(SNAPSHOT_ADDR) + LongWord(i))));
  Move(buf[0], snap, SizeOf(TGameSnapshot));

  System.Assign(f, path);
  {$I-} System.Rewrite(f); {$I+}
  if IOResult <> 0 then
  begin
    SafeLogErr(Format('dump-game: failed to open %s', [path]));
    Exit;
  end;

  try
    if snap.Header.Magic <> SNAPSHOT_MAGIC then
    begin
      Writeln(f, Format('dump-game: invalid magic (read $%08x, expected $%08x)',
        [snap.Header.Magic, SNAPSHOT_MAGIC]));
      Writeln(f, '  cart has not initialized the snapshot region, or memory layout drifted');
      SafeLog(Format('dump-game -> %s (invalid-magic)', [path]));
      Exit;
    end;

    if snap.Header.Version <> SNAPSHOT_VERSION then
    begin
      Writeln(f, Format('dump-game: schema version mismatch (cart=%d emulator=%d)',
        [snap.Header.Version, SNAPSHOT_VERSION]));
      Writeln(f, '  rebuild emulator OR cart to align; not decoding further');
      SafeLog(Format('dump-game -> %s (version-mismatch)', [path]));
      Exit;
    end;

    Writeln(f, Format('Cart game snapshot (magic=$%08x version=%d struct=%d bytes)',
      [snap.Header.Magic, snap.Header.Version, snap.Header.StructSize]));
    Writeln(f, Format('  units=%d map=%dx%d',
      [snap.Header.UnitCount, snap.Header.MapWidth, snap.Header.MapHeight]));
    Writeln(f);

    Writeln(f, Format('Frame %d  state=%s  turn=%d-%s',
      [snap.Core.Frame, StateName(snap.Core.State),
       snap.Core.TurnNumber, FactionLetter(snap.Core.CurrentFaction)]));
    if snap.Core.SelectedUnit >= 0 then
      Writeln(f, Format('  selected=u%d', [snap.Core.SelectedUnit]))
    else
      Writeln(f, '  selected=(none)');
    Writeln(f, Format('  cursor=(%d,%d)',
      [snap.Core.CursorTileX, snap.Core.CursorTileY]));
    if snap.Core.Victor <> 0 then
      Writeln(f, Format('  victor=%s', [FactionName(snap.Core.Victor)]));
    Writeln(f);

    Writeln(f, 'Units:');
    for i := 0 to MAX_UNITS - 1 do
      if snap.Units[i].Alive <> 0 then
        Writeln(f, Format('  u%d  %-7s %-7s  hp=%-2d  tile=(%2d,%2d)  px=(%3d,%3d)  moved=%d',
          [i,
           FactionName(snap.Units[i].Faction),
           ArchetypeName(snap.Units[i].Archetype),
           snap.Units[i].HP,
           snap.Units[i].TileX, snap.Units[i].TileY,
           snap.Units[i].Px, snap.Units[i].Py,
           snap.Units[i].MovedThisTurn]))
      else
        Writeln(f, Format('  u%d  DEAD', [i]));
    Writeln(f);

    Writeln(f, 'Capturable tiles:');
    mapIdx := 0;
    captureTileCount := 0;
    for gy := 0 to MAP_H - 1 do
      for gx := 0 to MAP_W - 1 do
      begin
        if IsCapturableTerrain(snap.MapTiles[mapIdx].TerrainKind) then
        begin
          Writeln(f, Format('  (%2d,%2d) %-5s  owner=%-7s  progress=%d',
            [gx, gy,
             TerrainName(snap.MapTiles[mapIdx].TerrainKind),
             FactionName(snap.MapTiles[mapIdx].OwnerFaction),
             snap.MapTiles[mapIdx].CaptureProgress]));
          Inc(captureTileCount);
        end;
        Inc(mapIdx);
      end;
    if captureTileCount = 0 then
      Writeln(f, '  (none in current GameMap)');
    Writeln(f);

    Writeln(f, 'Map grid (T=Trace, H=Heap, C=Cache, R=ROM, B=Bus, P=Port, *=Core):');
    Writeln(f, '  faction marker after Port/Core shows current owner (- = neutral)');
    mapIdx := 0;
    for gy := 0 to MAP_H - 1 do
    begin
      Write(f, '  ');
      for gx := 0 to MAP_W - 1 do
      begin
        if IsCapturableTerrain(snap.MapTiles[mapIdx].TerrainKind) then
          Write(f, TerrainGlyph(snap.MapTiles[mapIdx].TerrainKind),
                FactionLetter(snap.MapTiles[mapIdx].OwnerFaction))
        else
          Write(f, TerrainGlyph(snap.MapTiles[mapIdx].TerrainKind), ' ');
        Inc(mapIdx);
      end;
      Writeln(f);
    end;

    SafeLog(Format('dump-game -> %s', [path]));
  finally
    System.Close(f);
  end;
end;

{ Log helper — Writeln crashes with "File not open" (FPC IOResult 103)
  when stdout isn't attached (GUI applications built with
  GraphicApplication=True have no console). Guard every diagnostic
  write so the runner works the same from a console host (gbarun.exe)
  and a GUI host (gbashell.exe). Console hosts get the output; GUI
  hosts swallow it. To capture diagnostics in a GUI app, redirect by
  setting StdOut/StdErr in the host before calling RunGba (e.g.
  AssignFile + Rewrite to a log file then SetTextBuf). }
procedure Log(const s: string);
begin
  if (TTextRec(Output).Mode <> fmOutput) and
     (TTextRec(Output).Mode <> fmInOut) then Exit;
  {$I-}
  Writeln(s);
  {$I+}
  if IOResult <> 0 then ;
end;

procedure LogErr(const s: string);
begin
  if (TTextRec(ErrOutput).Mode <> fmOutput) and
     (TTextRec(ErrOutput).Mode <> fmInOut) then Exit;
  {$I-}
  Writeln(ErrOutput, s);
  {$I+}
  if IOResult <> 0 then ;
end;

function DefaultRunOptions: TGbaRunOptions;
begin
  Result.RomPath         := '';
  Result.BiosPath        := 'bios\gba_bios.bin';
  Result.DumpAudioPath   := '';
  Result.MaxFrames       := 0;
  Result.WindowScale     := 3;
  Result.WindowTitle     := 'Pascal GBA';
  Result.Verbose         := False;
  Result.PrintSummary    := False;
  Result.DebugPokeAddr   := 0;
  Result.DebugPokeByte   := 0;
  Result.Headless        := False;
  Result.ScreenshotPath  := '';
  Result.ScreenshotFrame := 0;
  Result.ReplayPath      := '';
  Result.RecordPath      := '';
  Result.DbglogOutPath   := '';
end;

function WriteFramebufferPng(fb: PFrameBuffer; const path: string): Boolean;
{ Persist the 240×160 ARGB framebuffer as a PNG using fcl-image. The
  framebuffer is BGRA in memory (`$FF000000 | (R shl 16) | (G shl 8) | B`)
  per ppu.pas — extract R/G/B and scale 8-bit channels to fpimage's 16-bit
  by replicating the byte (`c8 → (c8 shl 8) or c8`).

  Returns True on successful write, False on any failure (file IO, missing
  parent directory, fcl-image internal error). Caller surfaces the error.
  Parent directory is created if missing — agent-driven runs commonly
  target `bin/screenshots/...` which won't exist on a clean checkout. }
var
  img: TFPMemoryImage;
  writer: TFPWriterPNG;
  stream: TFileStream;
  x, y: Integer;
  px: TWord;
  rb, gb, bb: Byte;
  parent: string;
begin
  Result := False;
  parent := ExtractFilePath(path);
  if (parent <> '') and (not DirectoryExists(parent)) then
  begin
    if not ForceDirectories(parent) then
    begin
      LogErr(Format('screenshot: failed to create parent dir "%s"', [parent]));
      Exit;
    end;
  end;

  { Channels: replicate the byte to scale 8-bit → fpimage's 16-bit
    (matches FPC's standard FPColor convention; bb*$0101 keeps gamma
    identical to what the DIB blits to screen). }

  img := TFPMemoryImage.Create(GBA_WIDTH, GBA_HEIGHT);
  try
    for y := 0 to GBA_HEIGHT - 1 do
      for x := 0 to GBA_WIDTH - 1 do
      begin
        px := fb^[y * GBA_WIDTH + x];
        rb := (px shr 16) and $FF;
        gb := (px shr  8) and $FF;
        bb :=  px         and $FF;
        img.Colors[x, y] := FPColor(
          (Word(rb) shl 8) or Word(rb),
          (Word(gb) shl 8) or Word(gb),
          (Word(bb) shl 8) or Word(bb),
          $FFFF);
      end;

    writer := TFPWriterPNG.Create;
    try
      writer.Indexed     := False;
      writer.UseAlpha    := False;
      stream := TFileStream.Create(path, fmCreate);
      try
        writer.ImageWrite(stream, img);
        Result := True;
      finally
        stream.Free;
      end;
    finally
      writer.Free;
    end;
  finally
    img.Free;
  end;

  if not Result then
    LogErr(Format('screenshot: write failed for "%s"', [path]));
end;

procedure InitCpuForReset(cpu: TArmCore);
{ Cold-boot CPU state per ARM7TDMI reset spec:
    PC   = 0      (reset vector — execution starts at BIOS code)
    CPSR = $D3    (SVC mode, I=1, F=1, ARM mode T=0)
  All other registers are undefined on real hardware. }
var s: TArmState;
begin
  s := cpu.State;
  s.CPSR  := $000000D3;
  s.R[15] := 0;
  cpu.State := s;
end;

procedure RunGba(const opts: TGbaRunOptions);
var
  mem:  TGbaMemory;
  cpu:  TArmCore;
  gpu:  TGbaPpu;
  disp: TGbaDisplay;
  intc: TGbaIrq;
  tmrs: TGbaTimers;
  gdma: TGbaDma;
  kbd:  TGbaInput;
  bios: TGbaBios;
  gapu: TGbaApu;
  snd:  TGbaAudio;
  gsave: TGbaSave;
  mp2kHle: TMp2kHle;
  replay: TReplayEngine;
  dbglog: TDbgLog;
  audioBuf: TSampleBuffer;
  wavDump: TWavWriter;
  fifoRawF: TFileStream;

  rom: array of Byte;
  f: file of Byte;
  romLen: Integer;
  info: TCartInfo;

  frame: Int64;
  loggedUnmappedOnce: Boolean;
  scanline: Integer;
  cycle: Integer;
  qpcFreq, startTs, endTs: Int64;
  elapsedSec: Double;
  dispstat, dispcnt: TWord;
  i: Integer;
  savePath: string;
  sadLine: string;

  { Headless-mode bookkeeping. }
  prevIrqEntries: Int64;       { snapshot of cpu.IrqEntryCount last frame }
  haltDeadFrames: Integer;     { consecutive frames CPU was halted with no IRQ progress }
  framesShown: Int64;          { authoritative frame counter — disp.FramesShown is windowed-only }
  screenshotDone: Boolean;     { skip end-of-run capture if we already captured at ScreenshotFrame }
  fatalReason: Integer;        { 0 clean / 2 unmapped flood / 3 halted forever }

  { Dbglog tail dump (--dbglog-out) }
  dbglogFile: Text;
  dbglogParent: string;
begin
  ExitCode := 0;
  if opts.RomPath = '' then
  begin
    LogErr('gba_runner: empty ROM path');
    ExitCode := 1;
    Exit;
  end;
  if not FileExists(opts.RomPath) then
  begin
    LogErr(Format('gba_runner: ROM not found at "%s"', [opts.RomPath]));
    ExitCode := 1;
    Exit;
  end;
  if not FileExists(opts.BiosPath) then
  begin
    LogErr(Format('gba_runner: BIOS not found at "%s"', [opts.BiosPath]));
    ExitCode := 1;
    Exit;
  end;

  Log(Format('gba_runner: rom="%s"  bios="%s"', [opts.RomPath, opts.BiosPath]));
  if opts.DumpAudioPath <> '' then
    Log(Format('  audio dump -> %s', [opts.DumpAudioPath]));

  mem    := TGbaMemory.Create;
  cpu    := TArmCore.Create;
  gpu    := TGbaPpu.Create(mem);
  intc   := TGbaIrq.Create(mem);
  tmrs   := TGbaTimers.Create(mem, intc);
  gdma   := TGbaDma.Create(mem, intc);

  { Headless: skip Win32 window + waveOut. Input is still created (with
    a nil display) so KEYINPUT keeps its "all released" default and the
    per-frame kbd.Update call no-ops cleanly. Audio samples are still
    generated by gapu each frame so APU state stays accurate — they
    just aren't submitted to a sound device. }
  if opts.Headless then
  begin
    disp := nil;
    snd  := nil;
    Log('gba_runner: headless — no Win32 window, no waveOut');
  end
  else
  begin
    disp := TGbaDisplay.Create(opts.WindowScale, opts.WindowTitle);
    snd  := TGbaAudio.Create;
  end;
  kbd     := TGbaInput.Create(mem, disp);
  bios    := TGbaBios.Create(cpu, mem);
  gapu    := TGbaApu.Create(mem);
  mp2kHle := TMp2kHle.Create(mem);
  replay  := TReplayEngine.Create(kbd, mem);
  dbglog  := TDbgLog.Create(mem);
  SetLength(audioBuf, SAMPLES_PER_FRAME);
  if opts.DumpAudioPath <> '' then
    wavDump := TWavWriter.Create(opts.DumpAudioPath, AUDIO_SAMPLE_RATE)
  else
    wavDump := nil;
  gsave := nil;

  { Replay setup happens inside the try block below — keep
    everything that can fail after the destructors are guaranteed
    to run. }

  try
    if not mem.LoadBios(opts.BiosPath) then
    begin
      LogErr('FATAL: BIOS load failed');
      ExitCode := 1;
      Exit;
    end;
    if not mem.LoadRom(opts.RomPath) then
    begin
      LogErr('FATAL: ROM load failed');
      ExitCode := 1;
      Exit;
    end;

    { Re-read ROM into a byte array for cart-header parse. The ROM
      is already in mem.FRom, but ParseCartHeader needs an array. }
    AssignFile(f, opts.RomPath);
    Reset(f);
    try
      romLen := FileSize(f);
      SetLength(rom, romLen);
      BlockRead(f, rom[0], romLen);
    finally
      CloseFile(f);
    end;

    info := ParseCartHeader(rom, romLen);
    Log(Format('Title="%s"  GameCode="%s"  Save=%s',
      [info.Title, info.GameCode, SaveTypeName(info.SaveType)]));

    { Phase H — wire cart save. .sav lives next to the ROM. }
    savePath := ChangeFileExt(opts.RomPath, '.sav');
    gsave := TGbaSave.Create(mem, info, savePath);
    mem.SetSaveReadHook(@gsave.ReadByte);
    mem.SetSaveWriteHook(@gsave.WriteByte);
    gsave.LoadFromDisk;
    Log(Format('Save backend: %s  path=%s  size=%d bytes',
      [SaveTypeName(gsave.SaveType), gsave.Path, gsave.Size]));

    cpu.SetMemoryHooks(@mem.ReadWord, @mem.ReadHalf, @mem.ReadByte,
                       @mem.CpuWriteWord, @mem.CpuWriteHalf, @mem.CpuWriteByte);
    cpu.SetIrqHook(@intc.Pending);
    cpu.SetHaltWakeHook(@intc.PendingRaw);
    mem.SetHaltRequestHook(@cpu.OnHaltRequested);
    mem.SetFifoAPushHook(@gapu.PushFifoA);
    mem.SetFifoBPushHook(@gapu.PushFifoB);
    mem.SetDmaControlHook(@gdma.OnControlWrite);
    gapu.SetFifoALowHook(@gdma.NotifyFifoA);
    gapu.SetFifoBLowHook(@gdma.NotifyFifoB);
    gapu.SetTimers(tmrs);
    kbd.UseDefaultMapping;

    { Load replay script and/or start recording. Failure
      to load a script is fatal: an unreadable / malformed script
      means the agent-driven scenario won't produce the intended
      outcome, so surface ExitCode := 1 rather than silently running
      without input. Inside the try block so cleanup runs. }
    if opts.ReplayPath <> '' then
    begin
      if not replay.LoadScript(opts.ReplayPath) then
      begin
        LogErr('FATAL: replay script failed to load');
        ExitCode := 1;
        Exit;
      end;
    end;
    if opts.RecordPath <> '' then
      replay.StartRecording(opts.RecordPath);

    InitCpuForReset(cpu);

    QueryPerformanceFrequency(qpcFreq);
    QueryPerformanceCounter(startTs);

    frame := 0;
    loggedUnmappedOnce := False;
    prevIrqEntries     := 0;
    haltDeadFrames     := 0;
    framesShown        := 0;
    screenshotDone     := False;
    fatalReason        := 0;

    { Outer loop is unconditional — termination is via Break statements
      below. Windowed mode breaks when `disp.Present` returns False
      (window closed) or on MaxFrames. Headless mode breaks on MaxFrames
      or on a fatal exit condition (unmapped flood, halted forever).
      The PER-FRAME TAIL below decides which. }
    while True do
    begin
      kbd.Update;
      replay.Tick(frame);   { apply scripted events / sample for record }

      { Drain replay side-effect queue. Side effects fire AT the
        requested frame, after PPU has rendered the prior frame -- so
        the captured framebuffer / register state is what was visible
        going into frame N (matches --screenshot-frame N semantics:
        1-indexed, "end of frame N"). }
      for i := 0 to replay.SideEffectCount - 1 do
      begin
        case replay.SideEffect(i).Kind of
          sekScreenshot:
            if WriteFramebufferPng(gpu.FrameBufferPtr, replay.SideEffect(i).Path) then
              Log(Format('replay screenshot[frame=%d] -> %s',
                [frame, replay.SideEffect(i).Path]));
          sekDumpState:
            { DumpDebugState handles parent-dir creation + error logging
              internally; on success it emits a `dump-state -> <path>`
              line. No additional Log here -- the inner log already names
              the path and a reader can pair it with the script's
              named frame from context. }
            DumpDebugState(mem, cpu, gdma, gapu, intc, tmrs, dbglog, frame,
                           replay.SideEffect(i).Path);
          sekDumpGame:
            { Read the cart's TGameSnapshot mirror struct from EWRAM
              $0203F000 and emit a human-readable text dump. See
              DumpGameSnapshot for the schema validation + decoding.
              Inner SafeLog emits a `dump-game -> <path>` confirmation. }
            DumpGameSnapshot(mem, replay.SideEffect(i).Path);
        end;
      end;

      for scanline := 0 to SCANLINES_TOTAL - 1 do
      begin
        { Surface the first unmapped memory access (CPU reading/writing
          an address no MMIO region claims). Real hardware returns
          open-bus for unmapped reads — typically the next CPU prefetch
          byte — and silently drops writes. Our memory.pas returns 0 for
          reads. Games occasionally hit unmapped addresses through
          benign code paths (uninit pointer used in a NOP path, table
          lookup that immediately re-validates, etc.) so HALTING on the
          first access wedges legitimate game progress.

          Strategy: log the first occurrence once (so a reader
          sees something happened) and KEEP RUNNING. Tests that want
          a hard stop can read mem.FirstUnmappedAddr after RunGba
          returns and assert it equals zero. }
        if (mem.FirstUnmappedAddr <> 0) and (not loggedUnmappedOnce) then
        begin
          loggedUnmappedOnce := True;
          Log(Format('UNMAPPED ACCESS at $%08x  (writes=%d reads=%d) — continuing',
            [mem.FirstUnmappedAddr, mem.UnmappedWriteCount, mem.UnmappedReadCount]));
          Log(Format('  CPU PC=%s mode=%s T=%d',
            [IntToHex(cpu.GetReg(R_PC), 8),
             IntToHex(cpu.State.CPSR and $1F, 2),
             Ord((cpu.State.CPSR and CPSR_T) <> 0)]));
        end;

        mem.WriteHalf($04000006, THalf(scanline));

        { DISPSTAT (\$04000004) per-scanline maintenance.
          - Bit 0: V-Blank flag — set during scanlines 160..226, cleared
            during scanlines 0..159 and 227.
          - Bit 1: H-Blank flag — clear here at scanline start; set after
            the visible portion below (HBlank events block).
          - Bit 2: V-Count flag — TODO, not yet implemented (a few games
            use it for music tempo / cutscene sync). }
        dispstat := mem.ReadHalf($04000004);
        dispstat := dispstat and not TWord($0002);   { clear HBlank flag }
        if (scanline >= SCANLINES_VISIBLE) and (scanline < SCANLINES_TOTAL - 1) then
          dispstat := dispstat or $0001
        else
          dispstat := dispstat and not TWord($1);
        mem.WriteHalf($04000004, THalf(dispstat));

        { Visible portion of the scanline. CPU runs ~960 cycles while
          drawing would happen on real hardware. After this block we
          render the scanline using the CURRENT state of all PPU/IO
          registers — matches what real hardware sampled per-pixel
          during the same cycles. The original 1232-at-once approach
          made render use end-of-HBlank state, which is what the game
          intended for the NEXT scanline, producing 1-pixel-tall
          artifacts at every visual element boundary (dialog box top/
          bottom, banner edges) because HBlank-IRQ-driven register
          writes for scanline N+1 corrupted scanline N's render. }
        for cycle := 1 to CYCLES_VISIBLE do
          cpu.Step;

        if scanline < SCANLINES_VISIBLE then
          gpu.RenderScanline(scanline);

        { HBlank events fire at the boundary between visible and HBlank
          cycles. Set DISPSTAT bit 1 (HBlank flag) so games polling it
          see the right value. Request HBlank IRQ if DISPSTAT bit 4
          (HBlank IRQ enable) is set — the IRQ handler then runs DURING
          the HBlank cycles below, writing registers (BGVOFS, palette,
          WIN coords) that take effect on the NEXT scanline's render.

          NotifyHBlank fires HDMA on any DMA channel with start-timing=2
          + enabled bit set. Per GBATEK, HBlank-timing DMAs are ignored
          during V-blank — we gate on scanline < SCANLINES_VISIBLE.

          Re-read DISPSTAT before OR-ing the flag in: the CPU has been
          stepping for 960 cycles and may have updated IRQ-enable bits
          (e.g. BIOS VBlankIntrWait sets bit 3 before halting). Stale
          local-variable writes here previously clobbered those changes
          and bricked BIOS boot. }
        dispstat := mem.ReadHalf($04000004) or $0002;
        mem.WriteHalf($04000004, THalf(dispstat));
        if (dispstat and $0010) <> 0 then intc.Request(IRQ_HBLANK);
        if scanline < SCANLINES_VISIBLE then
          gdma.NotifyHBlank;

        { HBlank portion of the scanline. CPU runs the remaining ~272
          cycles during which the game's HBlank IRQ handler executes.
          Register writes here affect the NEXT scanline's render. }
        for cycle := 1 to CYCLES_HBLANK do
          cpu.Step;

        tmrs.Step(CYCLES_PER_SCANLINE);
        gapu.Step(CYCLES_PER_SCANLINE);
        gdma.Step;       { safety-net poll; primary edge-detection via memory hook }

        if scanline = SCANLINES_VISIBLE then
        begin
          if (dispstat and $0008) <> 0 then intc.Request(IRQ_VBLANK);
          gdma.NotifyVBlank;
        end;
      end;

      dispcnt := mem.ReadHalf($04000000);
      if dispcnt = dispcnt then ;   { silence unused warning }

      { Audio samples are generated every frame so APU state evolves
        correctly even in headless mode. They're submitted to waveOut
        only in windowed mode; the WAV dump (if enabled) captures
        either way — useful when reproducing audio bugs from a script. }
      gapu.GenerateSamples(SAMPLES_PER_FRAME, audioBuf);
      if wavDump <> nil then wavDump.WriteSamples(audioBuf, SAMPLES_PER_FRAME);

      if not opts.Headless then
      begin
        Move(gpu.FrameBufferPtr^, disp.FrameBufferPtr^,
             GBA_DISPLAY_W * GBA_DISPLAY_H * 4);
        snd.Submit(audioBuf, SAMPLES_PER_FRAME);
        if not disp.Present then Break;
      end;
      Inc(frame);
      Inc(framesShown);

      { mp2k HLE: advance the cart's mp2k engine's boot countdown by
        one tick. The HLE detects the engine via its struct signature
        at $03000F6C and only acts when the engine is set up. Cheap
        no-op when not. Unblocks games whose boot polls a flag that
        real-hardware Timer-2 ISRs set but ours doesn't. }
      mp2kHle.Tick(frame);
      dbglog.Tick(frame);     { capture game-side DbgLog messages }

      { Debug: optionally force a byte at an IWRAM address every frame.
        Used to confirm whether a busy-wait loop is waiting on that byte
        (e.g., the mp2k engine's "audio frame ready" flag at $03000F74
        when investigating a commercial title's pre-render stall). }
      if opts.DebugPokeAddr <> 0 then
        mem.WriteByte(opts.DebugPokeAddr, opts.DebugPokeByte);

      { F12 → live debug dump while playing. Writes a comprehensive
        diagnostic file to dumps/<timestamp>.txt next to the host EXE.
        Press F12 in the emulator window when something looks wrong;
        the file captures CPU state, IRQ/timer/DMA registers, mp2k
        struct contents, PC-neighborhood ROM bytes, IRQ handler and
        jump table dumps. Headless has no keyboard so this branch is
        skipped. }
      if (disp <> nil) and disp.DumpRequested then
      begin
        DumpDebugState(mem, cpu, gdma, gapu, intc, tmrs, dbglog, frame,
                       BuildDefaultDumpPath(mem, frame));
        disp.DumpRequested := False;
      end;
      if opts.Verbose and ((frame mod 60) = 0) then
        Log(Format('  frame %d  PC=%s  hdlr@$7FFC=%s  DISPCNT=%s',
          [frame,
           IntToHex(cpu.GetReg(R_PC), 8),
           IntToHex(mem.ReadWord($03007FFC), 8),
           IntToHex(mem.ReadHalf($04000000), 4)]));

      { Screenshot capture at a specific frame number. ScreenshotFrame
        is 1-indexed (capture the end-of-frame state after frame N has
        been fully simulated and rendered). 0 means "capture at end of
        run instead" — handled after the loop exits. }
      if (opts.ScreenshotPath <> '') and (opts.ScreenshotFrame > 0)
         and (frame = opts.ScreenshotFrame) and (not screenshotDone) then
      begin
        if WriteFramebufferPng(gpu.FrameBufferPtr, opts.ScreenshotPath) then
          Log(Format('screenshot[frame=%d] -> %s', [frame, opts.ScreenshotPath]));
        screenshotDone := True;
      end;

      { Fatal-exit detection. Two conditions surface as non-zero exit
        codes — useful for agent-driven runs that want to assert "did
        this scenario reach a clean stopping point?". The thresholds
        are deliberately loose: a handful of unmapped accesses is
        benign noise; thousands suggests the cart wandered into the
        weeds. A halted CPU between IRQs is the BIOS VBlankIntrWait
        steady state; halted across many frames with no IRQ progress
        means truly wedged. }
      if (mem.UnmappedReadCount + mem.UnmappedWriteCount) > 10000 then
      begin
        Log(Format('FATAL: unmapped-access flood (reads=%d writes=%d) — aborting',
          [mem.UnmappedReadCount, mem.UnmappedWriteCount]));
        fatalReason := 2;
        Break;
      end;
      if cpu.State.Halted and (cpu.IrqEntryCount = prevIrqEntries) then
        Inc(haltDeadFrames)
      else
        haltDeadFrames := 0;
      prevIrqEntries := cpu.IrqEntryCount;
      if haltDeadFrames > 120 then     { 2 wallclock seconds at 60 Hz }
      begin
        Log('FATAL: CPU halted for 120+ frames with no IRQ progress — aborting');
        fatalReason := 3;
        Break;
      end;

      if (opts.MaxFrames > 0) and (frame >= opts.MaxFrames) then Break;
    end;

    QueryPerformanceCounter(endTs);
    if snd <> nil then
      Log(Format('Audio submit: %d buffers, %d wait iterations, %d wedge-skips',
        [snd.SubmitCount, snd.SubmitWaitCount, snd.SubmitWedgeCount]));
    elapsedSec := (endTs - startTs) / qpcFreq;
    if elapsedSec > 0 then
      Log(Format('Rendered %d frames in %.2f s (%.1f FPS).',
                 [framesShown, elapsedSec, framesShown / elapsedSec]))
    else
      Log(Format('Rendered %d frames in <1 ms.', [framesShown]));

    { End-of-run screenshot. Captures the framebuffer state at the last
      simulated frame — the natural "what did the game look like when
      we stopped" probe. Skipped if a specific-frame capture already
      fired (screenshotDone) or no path was supplied. }
    if (opts.ScreenshotPath <> '') and (not screenshotDone) then
    begin
      if WriteFramebufferPng(gpu.FrameBufferPtr, opts.ScreenshotPath) then
        Log(Format('screenshot[end,frame=%d] -> %s', [frame, opts.ScreenshotPath]));
    end;

    { Dump the DbgLog ring-buffer tail to file if requested. Captures the
      last DBG_RING_CAPACITY game-side messages -- useful for headless
      runs where the live trace was buffered/truncated. }
    if opts.DbglogOutPath <> '' then
    begin
      dbglogParent := ExtractFilePath(opts.DbglogOutPath);
      if (dbglogParent <> '') and (not DirectoryExists(dbglogParent)) then
        ForceDirectories(dbglogParent);
      AssignFile(dbglogFile, opts.DbglogOutPath);
      try
        Rewrite(dbglogFile);
        Writeln(dbglogFile, Format('# DbgLog tail dumped at host frame %d', [frame]));
        dbglog.WriteTail(dbglogFile);
        CloseFile(dbglogFile);
        Log(Format('dbglog tail -> %s', [opts.DbglogOutPath]));
      except
        on E: Exception do
          LogErr(Format('dbglog tail: failed to write %s: %s',
            [opts.DbglogOutPath, E.Message]));
      end;
    end;

    { Surface the final exit status. 0 = clean. Non-zero = the loop
      broke for one of the fatal reasons tracked above. }
    if fatalReason <> 0 then ExitCode := fatalReason;

    if opts.PrintSummary then
    begin
      Log(Format('IRQ entries: %d', [cpu.IrqEntryCount]));
      Log(Format('APU activity: ch1 retrig=%d  ch2=%d  ch3=%d  ch4=%d  FIFO-A pushes=%d  FIFO-B pushes=%d',
        [gapu.Ch1RetriggerCount, gapu.Ch2RetriggerCount,
         gapu.Ch3RetriggerCount, gapu.Ch4RetriggerCount,
         gapu.FifoAPushCount, gapu.FifoBPushCount]));
      Log(Format('FIFO integrity: A underruns=%d drops=%d  B underruns=%d drops=%d',
        [gapu.FifoAUnderrunCount, gapu.FifoADropCount,
         gapu.FifoBUnderrunCount, gapu.FifoBDropCount]));
      Log('DMA transfer summary:');
      for i := 0 to 3 do
        if gdma.TransferCount[i] > 0 then
          Log(Format('  DMA%d: %d transfers  last src=$%08x dst=$%08x',
            [i, gdma.TransferCount[i],
             gdma.LastTransferSad[i], gdma.LastTransferDad[i]]));
      Log('DMA re-arm pattern:');
      for i := 0 to 3 do
        if gdma.EnableEdgeCount[i] > 0 then
        begin
          { Build the multi-SAD line in one string so the GUI host
            (which has no console) sees a single Log call. }
          sadLine := Format('  DMA%d: %d arms, %d distinct SADs:',
            [i, gdma.EnableEdgeCount[i], gdma.DistinctSadCount[i]]);
          for cycle := 0 to gdma.DistinctSadCount[i] - 1 do
            sadLine := sadLine + Format(' $%08x', [gdma.DistinctSads[i, cycle]]);
          Log(sadLine);
        end;

      { Extended diagnostic dump — used when investigating why a game
        boots into a wedge state. Restores the per-subsystem detail
        that the original console harness printed before refactoring. }
      Log('');
      Log(Format('IE=$%04x IF=$%04x IME=$%04x  IntrCheck@$03007FF8=$%08x  IntrCheck@$03FFFFF8=$%08x',
        [mem.ReadHalf($04000200), mem.ReadHalf($04000202),
         mem.ReadHalf($04000208), mem.ReadWord($03007FF8),
         mem.ReadWord($03FFFFF8)]));
      Log(Format('Sound regs: SOUNDCNT_L=$%04x SOUNDCNT_H=$%04x SOUNDCNT_X=$%04x SOUNDBIAS=$%04x',
        [mem.ReadHalf($04000080), mem.ReadHalf($04000082),
         mem.ReadHalf($04000084), mem.ReadHalf($04000088)]));
      for i := 0 to 3 do
        if tmrs.IsEnabled(i) then
          Log(Format('Timer %d: enabled  reload=$%04x  prescaler=%d',
            [i, tmrs.GetReload(i), tmrs.GetPrescaler(i)]));
      Log(Format('Final PC = $%08x  CPSR.mode=%s  T=%d  halted=%d',
        [cpu.GetReg(R_PC), IntToHex(cpu.State.CPSR and $1F, 2),
         Ord((cpu.State.CPSR and CPSR_T) <> 0), Ord(cpu.State.Halted)]));
      Log(Format('R0-R7   = %s %s %s %s %s %s %s %s',
        [IntToHex(cpu.GetReg(0), 8), IntToHex(cpu.GetReg(1), 8),
         IntToHex(cpu.GetReg(2), 8), IntToHex(cpu.GetReg(3), 8),
         IntToHex(cpu.GetReg(4), 8), IntToHex(cpu.GetReg(5), 8),
         IntToHex(cpu.GetReg(6), 8), IntToHex(cpu.GetReg(7), 8)]));
      Log(Format('R8-R12  = %s %s %s %s %s  SP=%s LR=%s',
        [IntToHex(cpu.GetReg(8), 8), IntToHex(cpu.GetReg(9), 8),
         IntToHex(cpu.GetReg(10), 8), IntToHex(cpu.GetReg(11), 8),
         IntToHex(cpu.GetReg(12), 8),
         IntToHex(cpu.GetReg(R_SP), 8), IntToHex(cpu.GetReg(R_LR), 8)]));
      { Dump 32 bytes (16 THUMB instructions / 8 ARM) around PC. }
      sadLine := Format('Bytes @ PC&~7=$%08x:', [cpu.GetReg(R_PC) and not TWord($7)]);
      for i := 0 to 31 do
        sadLine := sadLine + ' ' + IntToHex(
          mem.ReadByte((cpu.GetReg(R_PC) and not TWord($7)) + TWord(i)), 2);
      Log(sadLine);
      { Dump 128 bytes around PC's containing 32-byte block. Reveals
        the literal pool entries (LDR Rd, [PC, #n] target addresses). }
      sadLine := Format('Bytes @ $%08x..+128:', [(cpu.GetReg(R_PC) and not TWord($1F))]);
      for i := 0 to 127 do
        sadLine := sadLine + ' ' + IntToHex(
          mem.ReadByte((cpu.GetReg(R_PC) and not TWord($1F)) + TWord(i)), 2);
      Log(sadLine);
      { IRQ handler at the address the game installed at $03007FFC. }
      sadLine := Format('IRQ handler @ $%08x (first 64 bytes):',
        [mem.ReadWord($03007FFC)]);
      for i := 0 to 255 do
        sadLine := sadLine + ' ' + IntToHex(
          mem.ReadByte(mem.ReadWord($03007FFC) + TWord(i)), 2);
      Log(sadLine);
      { Also dump the polled struct at $03000F6C and the SRAM byte at
        $0E00F07F (addresses a commercial title's busy-wait reads). }
      Log(Format('IWRAM $03000F6C..+16: %s %s %s %s',
        [IntToHex(mem.ReadWord($03000F6C), 8),
         IntToHex(mem.ReadWord($03000F70), 8),
         IntToHex(mem.ReadWord($03000F74), 8),
         IntToHex(mem.ReadWord($03000F78), 8)]));
      Log(Format('SRAM $0E00F070..+16: %s %s %s %s',
        [IntToHex(mem.ReadWord($0E00F070), 8),
         IntToHex(mem.ReadWord($0E00F074), 8),
         IntToHex(mem.ReadWord($0E00F078), 8),
         IntToHex(mem.ReadWord($0E00F07C), 8)]));
    end;
  finally
    if wavDump <> nil then wavDump.Free;
    { Alongside a WAV dump, emit the raw FIFO push logs (first 256 KiB
      per FIFO) for content-vs-pipeline forensics: the logged bytes are
      the PCM exactly as the game delivered it, before any hold/mix
      stage. <dump>.fifoa.raw / .fifob.raw, signed 8-bit mono. }
    if (opts.DumpAudioPath <> '') and (gapu <> nil) then
    begin
      try
        if gapu.FifoALogCount > 0 then
        begin
          fifoRawF := TFileStream.Create(opts.DumpAudioPath + '.fifoa.raw', fmCreate);
          fifoRawF.WriteBuffer(gapu.FifoALog[0], gapu.FifoALogCount);
          fifoRawF.Free;
        end;
        if gapu.FifoBLogCount > 0 then
        begin
          fifoRawF := TFileStream.Create(opts.DumpAudioPath + '.fifob.raw', fmCreate);
          fifoRawF.WriteBuffer(gapu.FifoBLog[0], gapu.FifoBLogCount);
          fifoRawF.Free;
        end;
      except
        on E: Exception do Log('fifo log dump failed: ' + E.Message);
      end;
    end;
    if gsave   <> nil then begin gsave.Flush; gsave.Free; end;
    if replay  <> nil then replay.Free;   { Free flushes recording on its own }
    if dbglog  <> nil then dbglog.Free;
    mp2kHle.Free;
    if snd  <> nil then snd.Free;
    gapu.Free;
    bios.Free;
    kbd.Free;
    if disp <> nil then disp.Free;
    gdma.Free; tmrs.Free; intc.Free; gpu.Free; cpu.Free; mem.Free;
  end;
end;

end.
