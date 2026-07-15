unit Memory;
{
  GBA memory subsystem — the 16MB virtual address space with mirroring,
  special write semantics, and (eventually) wait-state timing.

  ── Address space layout ──

    $00000000 – $00003FFF  BIOS                 16 KB,  read-only after boot
    $00004000 – $01FFFFFF  unmapped             open-bus on read, ignored on write
    $02000000 – $023FFFFF  EWRAM (256 KB)       mirrored every $40000 in $02xxxxxx
    $02400000 – $02FFFFFF  unmapped
    $03000000 – $03FFFFFF  IWRAM (32 KB)        mirrored every $8000
    $04000000 – $040003FE  I/O registers
    $04000400 – $04FFFFFF  unmapped (mostly)
    $05000000 – $05FFFFFF  Palette RAM (1 KB)   mirrored every $400
    $06000000 – $06FFFFFF  VRAM (96 KB)         mirror pattern: every $20000,
                                                 within each, offsets $18000–$1FFFF
                                                 mirror $10000–$17FFF
    $07000000 – $07FFFFFF  OAM (1 KB)           mirrored every $400
    $08000000 – $0DFFFFFF  Game Pak ROM         up to 32 MB, mirrored per ROM size
    $0E000000 – $0FFFFFFF  Game Pak SRAM        64 KB max, mirrored every $10000

  ── Special write semantics (per GBATEK) ──

    Palette RAM: 8-bit writes duplicate the byte to fill a halfword.
    OAM:         8-bit writes are dropped entirely.
    VRAM:        8-bit writes to BG region duplicate to halfword ; 8-bit writes
                 to OBJ region are dropped. Mode-aware; for v1 we duplicate
                 across all of VRAM (conservative — matches real hardware in
                 BG mode 0-2, which most commercial titles use).
    BIOS:        all writes ignored.
    ROM:         all writes ignored (writes are how cart save banks get
                 selected in EEPROM/Flash carts, but that's the save backend's
                 concern, not raw memory's).

  ── I/O registers ──

  Bytes $04000000..$040003FF are I/O registers — currently stored as raw
  bytes in FIo with no side effects. The PPU/APU/DMA/timer/IRQ subsystems
  will progressively hook reads/writes to specific offsets. For Phase B, we
  just provide flat storage so code that reads a register it just wrote sees
  the same value back.

  ── Open bus / unmapped reads ──

  Real GBA returns "open-bus" values (typically the last-fetched instruction
  or a prefetch pattern) for unmapped reads. For Phase B v1 we return 0
  with a one-line stderr warning. Most well-behaved commercial code never
  reads from unmapped addresses.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes;

const
  BIOS_SIZE     = 16 * 1024;       { $00004000 }
  EWRAM_SIZE    = 256 * 1024;      { $00040000 }
  EWRAM_MASK    = EWRAM_SIZE - 1;
  IWRAM_SIZE    = 32 * 1024;       { $00008000 }
  IWRAM_MASK    = IWRAM_SIZE - 1;
  IO_SIZE       = $400;
  IO_MASK       = IO_SIZE - 1;
  PALETTE_SIZE  = $400;
  PALETTE_MASK  = PALETTE_SIZE - 1;
  VRAM_SIZE     = 96 * 1024;       { $00018000 }
  OAM_SIZE      = $400;
  OAM_MASK      = OAM_SIZE - 1;
  SRAM_SIZE     = 64 * 1024;       { $00010000 }
  SRAM_MASK     = SRAM_SIZE - 1;

  { Region top-bit identifiers — bits 27:24 of an address uniquely select
    a region except for the unmapped gaps inside $00xxxxxx and $04xxxxxx.
    We use a single byte (the high nibble of the upper 16 bits — actually
    just bits 27:24) for fast dispatch. }
  REGION_BIOS    = $0;
  REGION_EWRAM   = $2;
  REGION_IWRAM   = $3;
  REGION_IO      = $4;
  REGION_PALETTE = $5;
  REGION_VRAM    = $6;
  REGION_OAM     = $7;
  { Game-pak ROM occupies a 32 MB space at each wait-state mirror, so
    each mirror covers TWO region-nibbles:
      WS0  →  $08000000-$09FFFFFF  (nibbles $8 + $9)
      WS1  →  $0A000000-$0BFFFFFF  (nibbles $A + $B)
      WS2  →  $0C000000-$0DFFFFFF  (nibbles $C + $D)
    All six nibbles index into the same FRom buffer with FRomMask
    handling the per-cart mirror size. The Phase B initial implementation
    only handled $8/$A/$C; BIOS-driven boot of a commercial title reads
    from $0BFFFFE0 (WS1 high half) and surfaced the gap. }
  REGION_ROM0_LO = $8;
  REGION_ROM0_HI = $9;
  REGION_ROM1_LO = $A;
  REGION_ROM1_HI = $B;
  REGION_ROM2_LO = $C;
  REGION_ROM2_HI = $D;
  REGION_SRAM    = $E;

type
  THaltRequestHook    = procedure of object;
  TFifoPushHook       = procedure(v: ShortInt) of object;
  TDmaControlHook     = procedure(channelIdx: Integer) of object;
  TSaveReadHook       = function (addr: TWord): TByte of object;
  TSaveWriteHook      = procedure(addr: TWord; v: TByte) of object;

  TGbaMemory = class
  private
    FOnHaltRequest: THaltRequestHook;
    FOnFifoAPush:   TFifoPushHook;
    FOnFifoBPush:   TFifoPushHook;
    FOnDmaControl:  TDmaControlHook;
    FOnSaveRead:    TSaveReadHook;
    FOnSaveWrite:   TSaveWriteHook;
  private
    FBios:    array[0 .. BIOS_SIZE    - 1] of TByte;
    FEwram:   array[0 .. EWRAM_SIZE   - 1] of TByte;
    FIwram:   array[0 .. IWRAM_SIZE   - 1] of TByte;
    FIo:      array[0 .. IO_SIZE      - 1] of TByte;
    FPalette: array[0 .. PALETTE_SIZE - 1] of TByte;
    FVram:    array[0 .. VRAM_SIZE    - 1] of TByte;
    FOam:     array[0 .. OAM_SIZE     - 1] of TByte;
    FSram:    array[0 .. SRAM_SIZE    - 1] of TByte;

    { ROM is dynamically allocated to match the cart's actual size (carts
      vary from 4 MB to 32 MB). FRomMask is (round-up-power-of-2(size)) - 1
      so we can mirror with a single AND. }
    FRom:     array of TByte;
    FRomMask: TWord;

    FBiosLoaded: Boolean;
    FRomLoaded:  Boolean;
  public
    { When set non-zero by the test harness, the first unmapped access
      latches the offending address here so the harness can identify
      "where the wedge started" without scrolling through 10K warnings. }
    FirstUnmappedAddr:    TWord;
    UnmappedWriteCount:   Int64;
    UnmappedReadCount:    Int64;
    IntrCheckWriteCount:  Int64;
    LastIntrCheckWrite:   THalf;
  private

    function ResolveVramOffset(addr: TWord): Integer; inline;
    procedure WarnOpenBus(op: string; addr: TWord);

  public
    constructor Create;

    { Load files into the appropriate regions. Both are best-effort: a
      missing BIOS leaves the region zeroed (so the CPU faults reading
      the reset vector — we'll surface that clearly); a missing ROM
      leaves ROM empty (open-bus reads return 0). }
    function LoadBios(const path: string): Boolean;
    function LoadRom(const path: string): Boolean;

    { Method-of-object hooks compatible with TArmCore's TMemReadWord etc.
      The CPU calls these for every fetch and every LDR/STR.

      ── Read vs write authority ──

      `ReadByte/Half/Word` and the non-Cpu `WriteByte/Half/Word` are the
      RAW memory backend — host-side code (PPU updating VCOUNT, IRQ
      pushing into IF, input.pas asserting KEYINPUT) calls Write* to
      mutate hardware-managed registers.

      CPU-driven stores go through `CpuWriteByte/Half/Word` which enforce
      read-only-from-CPU semantics: writes to hardware-managed registers
      (KEYINPUT, VCOUNT) are silently dropped to match real GBA behavior.
      Without this, cart code (or stray DMA copies) can corrupt the
      keypad / scanline state in ways real hardware shields against.
      Headless screenshot runs that stall on KEYINPUT are the usual
      symptom when this path is wrong. }
    function  ReadByte(addr: TWord): TByte;
    function  ReadHalf(addr: TWord): THalf;
    function  ReadWord(addr: TWord): TWord;
    procedure WriteByte(addr: TWord; v: TByte);
    procedure WriteHalf(addr: TWord; v: THalf);
    procedure WriteWord(addr: TWord; v: TWord);

    { CPU-store path — apply read-only enforcement, then dispatch to
      the raw Write* methods. Wire these into TArmCore's memory hooks
      via SetMemoryHooks; the raw Write* methods stay for host use. }
    procedure CpuWriteByte(addr: TWord; v: TByte);
    procedure CpuWriteHalf(addr: TWord; v: THalf);
    procedure CpuWriteWord(addr: TWord; v: TWord);

    { Setup-time escape hatch — write a word directly into the BIOS
      region (which is read-only from the CPU's perspective). Used by
      tests to install IRQ vectors and handler addresses without
      shipping an actual BIOS image, and conceptually equivalent to
      what LoadBios does when loading the BIOS from a file. Not for
      use from CPU emulation paths. }
    procedure PokeBiosWord(offsetBytes: Integer; v: TWord);

    { Raw I/O register write — bypasses the special-semantic handlers
      (write-1-clear for IF, etc.). For internal subsystem use only
      (Irq.Request setting a bit in IF, etc.). The CPU's normal store
      path uses WriteHalf which DOES apply special semantics. }
    procedure PokeIoHalf(offsetWithinIo: Integer; v: THalf);

    { Register a callback fired when the CPU writes a halt-request to
      HALTCNT ($04000301 with bit 7 = 0). Real BIOS uses this to
      implement IntrWait/VBlankIntrWait — write HALTCNT, CPU halts,
      next IRQ wakes the CPU and resumes inside the BIOS handler.
      Without this hook the CPU never halts, BIOS IntrWait busy-loops
      forever, and the game hangs in BIOS code. }
    procedure SetHaltRequestHook(hook: THaltRequestHook);

    { Register callbacks fired when the CPU or DMA writes a byte to
      Direct-Sound FIFO A ($040000A0-$A3) or FIFO B ($040000A4-$A7).
      Each byte of the write routes to one PushFifo call — a 32-bit STR
      to $040000A0 produces four PushFifoA calls in order. This is the
      DMA→FIFO routing path used by commercial games. }
    procedure SetFifoAPushHook(hook: TFifoPushHook);
    procedure SetFifoBPushHook(hook: TFifoPushHook);

    { Register a callback fired whenever the CPU writes any byte that
      overlaps a DMA channel's CNT_H halfword (the register that contains
      the enable bit). Without this, enable-edge detection must be polled
      — and mp2k's V-blank handler does `disable; update SAD; enable` in
      a few-instruction window, so any poll cadence coarser than per-
      instruction misses the re-arm. Per-write hook makes detection
      exact at near-zero cost. }
    procedure SetDmaControlHook(hook: TDmaControlHook);

    { Register callbacks for accesses to the cart save region
      ($0E000000-$0EFFFFFF). With hooks installed, ReadByte and WriteByte
      delegate to them; otherwise the legacy FSram array still receives
      writes (and reads). Wire from save.pas:
        mem.SetSaveReadHook(@gsave.ReadByte);
        mem.SetSaveWriteHook(@gsave.WriteByte);
      Halfword writes route the low byte through the write hook (real
      hardware presents only an 8-bit data bus to the cart save area). }
    procedure SetSaveReadHook(hook: TSaveReadHook);
    procedure SetSaveWriteHook(hook: TSaveWriteHook);

    property BiosLoaded: Boolean read FBiosLoaded;
    property RomLoaded:  Boolean read FRomLoaded;
    property RomSize:    TWord   read FRomMask;   { actually mask, not size }
  end;

implementation

constructor TGbaMemory.Create;
begin
  inherited Create;
  FillChar(FBios,    SizeOf(FBios),    0);
  FillChar(FEwram,   SizeOf(FEwram),   0);
  FillChar(FIwram,   SizeOf(FIwram),   0);
  FillChar(FIo,      SizeOf(FIo),      0);
  FillChar(FPalette, SizeOf(FPalette), 0);
  FillChar(FVram,    SizeOf(FVram),    0);
  FillChar(FOam,     SizeOf(FOam),     0);
  FillChar(FSram,    SizeOf(FSram),    0);
  SetLength(FRom, 0);
  FRomMask     := 0;
  FBiosLoaded  := False;
  FRomLoaded   := False;
  FirstUnmappedAddr := 0;
  UnmappedWriteCount := 0;
  UnmappedReadCount := 0;

  { Real GBA cold-boot state: SOUNDBIAS = $0200 (bias level $100, 9-bit
    resolution at 32 kHz). Real BIOS init confirms this; games that
    don't go through BIOS init (audio_smoke smoke tests) need it set
    explicitly or their mixer output is clamped to positive-only
    (verified by Python WAV analysis 2026-05-18). }
  FIo[$088] := $00;
  FIo[$089] := $02;
end;

procedure TGbaMemory.WarnOpenBus(op: string; addr: TWord);
begin
  { Latch the first unmapped address so the test harness can identify
    where things went wrong. After the first, increment counters and
    stay quiet — otherwise the log fills with thousands of warnings. }
  if FirstUnmappedAddr = 0 then FirstUnmappedAddr := addr;
  if Pos('write', op) > 0 then Inc(UnmappedWriteCount)
                          else Inc(UnmappedReadCount);
end;

function TGbaMemory.ResolveVramOffset(addr: TWord): Integer; inline;
{ VRAM has a non-trivial mirror: 96 KB live in a 128 KB stride. Within
  each $20000-aligned block, offsets $00000-$17FFF map directly; offsets
  $18000-$1FFFF mirror $10000-$17FFF (so the upper 32K mirrors the
  middle 32K, not the first 32K). }
var
  inner: Integer;
begin
  inner := addr and $1FFFF;
  if inner >= $18000 then inner := inner - $8000;
  Result := inner;
end;

function TGbaMemory.LoadBios(const path: string): Boolean;
var
  f: file of Byte;
  count: Integer;
begin
  Result := False;
  if not FileExists(path) then
  begin
    SafeLogErr(Format('Memory: BIOS file not found at "%s" — BIOS region will be zero (boot from $00000000 will fail).', [path]));
    Exit;
  end;
  AssignFile(f, path);
  Reset(f);
  try
    count := FileSize(f);
    if count > BIOS_SIZE then count := BIOS_SIZE;
    BlockRead(f, FBios[0], count);
    FBiosLoaded := True;
    Result := True;
    SafeLog(Format('Memory: BIOS loaded (%d bytes from "%s")', [count, path]));
  finally
    CloseFile(f);
  end;
end;

function TGbaMemory.LoadRom(const path: string): Boolean;
var
  f: file of Byte;
  count: Integer;
  paddedSize: TWord;
begin
  Result := False;
  if not FileExists(path) then
  begin
    SafeLogErr(Format('Memory: ROM file not found at "%s"', [path]));
    Exit;
  end;
  AssignFile(f, path);
  Reset(f);
  try
    count := FileSize(f);
    { Round up to next power of two for the mirror mask. Real GBA cart
      ROM is always power-of-2 sized (4/8/16/32 MB), but some homebrew
      or trimmed dumps aren't — the mask still gives "valid mirror" for
      addresses up to paddedSize. }
    paddedSize := 1;
    while paddedSize < TWord(count) do paddedSize := paddedSize shl 1;
    SetLength(FRom, paddedSize);
    FillChar(FRom[0], paddedSize, 0);
    BlockRead(f, FRom[0], count);
    FRomMask := paddedSize - 1;
    FRomLoaded := True;
    Result := True;
    SafeLog(Format('Memory: ROM loaded (%d bytes, padded to $%x)', [count, paddedSize]));
  finally
    CloseFile(f);
  end;
end;

{ ───── Read paths ────────────────────────────────────────────────── }

function TGbaMemory.ReadByte(addr: TWord): TByte;
var
  region: Integer;
  offset: TWord;
begin
  region := (addr shr 24) and $F;
  case region of
    REGION_BIOS:
      if addr < BIOS_SIZE then Result := FBios[addr] else Result := 0;
    REGION_EWRAM:    Result := FEwram[addr and EWRAM_MASK];
    REGION_IWRAM:    Result := FIwram[addr and IWRAM_MASK];
    REGION_IO:
      begin
        offset := addr and IO_MASK;
        if (addr and $FFFFFF) < IO_SIZE then Result := FIo[offset] else Result := 0;
      end;
    REGION_PALETTE:  Result := FPalette[addr and PALETTE_MASK];
    REGION_VRAM:     Result := FVram[ResolveVramOffset(addr)];
    REGION_OAM:      Result := FOam[addr and OAM_MASK];
    REGION_ROM0_LO, REGION_ROM0_HI,
    REGION_ROM1_LO, REGION_ROM1_HI,
    REGION_ROM2_LO, REGION_ROM2_HI:
      if FRomLoaded then
        Result := FRom[(addr - $08000000) and FRomMask]
      else
        Result := 0;
    REGION_SRAM:
      begin
        if Assigned(FOnSaveRead) then
          Result := FOnSaveRead(addr)
        else
          Result := FSram[addr and SRAM_MASK];
      end;
  else
    WarnOpenBus('byte read', addr);
    Result := 0;
  end;
end;

function TGbaMemory.ReadHalf(addr: TWord): THalf;
var
  a: TWord;
begin
  { Force halfword alignment (ARM7TDMI doesn't fault — it does a rotated
    read on misalignment for LDR but LDRH simply force-aligns). }
  a := addr and not TWord($1);
  Result := THalf(ReadByte(a)) or (THalf(ReadByte(a + 1)) shl 8);
end;

function TGbaMemory.ReadWord(addr: TWord): TWord;
var
  a: TWord;
begin
  { Force word alignment; the rotated-read semantics for misaligned LDR
    live in ArmCore (per ARM ARM §A2.6), where the rotation amount
    depends on the original low bits. For raw memory we just align down. }
  a := addr and not TWord($3);
  Result :=  TWord(ReadByte(a))
          or (TWord(ReadByte(a + 1)) shl 8)
          or (TWord(ReadByte(a + 2)) shl 16)
          or (TWord(ReadByte(a + 3)) shl 24);
end;

{ ───── Write paths ───────────────────────────────────────────────── }

procedure TGbaMemory.WriteByte(addr: TWord; v: TByte);
var
  region: Integer;
  offset: TWord;
  half: THalf;
begin
  region := (addr shr 24) and $F;
  case region of
    REGION_BIOS:     ;  { read-only }
    REGION_EWRAM:    FEwram[addr and EWRAM_MASK] := v;
    REGION_IWRAM:    FIwram[addr and IWRAM_MASK] := v;
    REGION_IO:
      begin
        offset := addr and IO_MASK;
        if (addr and $FFFFFF) < IO_SIZE then
        begin
          { Byte-level write-1-clear for IF bytes $04000202/$04000203. }
          if (addr = $04000202) or (addr = $04000203) then
            FIo[offset] := FIo[offset] and not v
          else
            FIo[offset] := v;

          { HALTCNT at $04000301. Bit 7 = 0 → halt (wake on any IRQ);
            bit 7 = 1 → stop (wake on keypad only). We treat both as
            halt for now — Stop is rare and commercial titles rarely use it. }
          if (addr = $04000301) and Assigned(FOnHaltRequest) then
            FOnHaltRequest();

          { Direct-Sound FIFO writes — route to APU. Each byte of a
            multi-byte write produces one PushFifo call (via WriteWord/
            WriteHalf cascading through WriteByte). }
          if (addr >= $040000A0) and (addr <= $040000A3) and Assigned(FOnFifoAPush) then
            FOnFifoAPush(ShortInt(v))
          else if (addr >= $040000A4) and (addr <= $040000A7) and Assigned(FOnFifoBPush) then
            FOnFifoBPush(ShortInt(v));

          { DMA CNT_H byte writes ($040000BA/$BB/$C6/$C7/$D2/$D3/$DE/$DF) —
            fire the DMA control hook so the DMA subsystem can detect
            enable-edges immediately. mp2k's V-blank handler does
            disable+enable in a few-cycle window that poll-based detection
            (even per-instruction) cannot reliably catch. }
          if Assigned(FOnDmaControl) then
          begin
            case addr of
              $040000BA, $040000BB: FOnDmaControl(0);
              $040000C6, $040000C7: FOnDmaControl(1);
              $040000D2, $040000D3: FOnDmaControl(2);
              $040000DE, $040000DF: FOnDmaControl(3);
            end;
          end;
        end;
      end;
    REGION_PALETTE:
      begin
        { Palette: byte write duplicates the byte to fill the halfword. }
        half := (THalf(v) shl 8) or THalf(v);
        WriteHalf(addr and not TWord($1), half);
      end;
    REGION_VRAM:
      begin
        { VRAM: byte write to BG region duplicates ; to OBJ region drops.
          For Phase B v1, duplicate everywhere (matches BG behavior, which
          is what most commercial titles need). Real BG/OBJ split depends
          on display mode. }
        half := (THalf(v) shl 8) or THalf(v);
        WriteHalf(addr and not TWord($1), half);
      end;
    REGION_OAM:      ;  { byte writes to OAM are dropped entirely }
    REGION_ROM0_LO, REGION_ROM0_HI,
    REGION_ROM1_LO, REGION_ROM1_HI,
    REGION_ROM2_LO, REGION_ROM2_HI: ;  { ROM is read-only from the CPU's perspective }
    REGION_SRAM:
      begin
        if Assigned(FOnSaveWrite) then
          FOnSaveWrite(addr, v)
        else
          FSram[addr and SRAM_MASK] := v;
      end;
  else
    WarnOpenBus('byte write', addr);
  end;
end;

procedure TGbaMemory.WriteHalf(addr: TWord; v: THalf);
var
  a: TWord;
  region: Integer;
  offset: TWord;
begin
  a := addr and not TWord($1);
  region := (a shr 24) and $F;

  case region of
    REGION_BIOS:     ;
    REGION_EWRAM:
      begin
        FEwram[(a + 0) and EWRAM_MASK] := TByte(v        and $FF);
        FEwram[(a + 1) and EWRAM_MASK] := TByte((v shr 8) and $FF);
      end;
    REGION_IWRAM:
      begin
        FIwram[(a + 0) and IWRAM_MASK] := TByte(v        and $FF);
        FIwram[(a + 1) and IWRAM_MASK] := TByte((v shr 8) and $FF);
        { Diagnostic counters for the BIOS IntrCheck flag at IWRAM[$7FF8]
          (mirror of $03007FF8 / $03FFFFF8). Useful when investigating
          IntrWait/VBlankIntrWait wedges. }
        if (a and $7FFF) = $7FF8 then
        begin
          Inc(IntrCheckWriteCount);
          LastIntrCheckWrite := v;
        end;
      end;
    REGION_IO:
      begin
        offset := a and IO_MASK;
        if (a and $FFFFFF) < IO_SIZE then
        begin
          { Special-semantic registers handled inline. Most I/O is plain
            storage; a few have hardware quirks the CPU's write must
            observe. }
          if a = $04000202 then
          begin
            { IF: write-1-clear. Each 1 bit in the written value clears
              that bit in memory; 0 bits are no-op. (Real BIOS writes
              the source-bit value to ack.) }
            FIo[offset]     := FIo[offset]     and not TByte(v and $FF);
            FIo[offset + 1] := FIo[offset + 1] and not TByte((v shr 8) and $FF);
          end
          else
          begin
            FIo[offset]     := TByte(v        and $FF);
            FIo[offset + 1] := TByte((v shr 8) and $FF);
          end;

          { HALTCNT byte at $04000301 covered by a halfword write to
            $04000300 (the most common BIOS encoding — STRH against the
            POSTFLG+HALTCNT pair). Word writes to $04000300 reach here
            via WriteWord → WriteHalf, so this branch covers both. }
          if (a = $04000300) and Assigned(FOnHaltRequest) then
            FOnHaltRequest();

          { Direct-Sound FIFO halfword writes. Decompose into two byte
            pushes (low byte first). Word writes to FIFO addresses
            arrive here via WriteWord → WriteHalf, producing four push
            calls in total. }
          if (a >= $040000A0) and (a < $040000A4) and Assigned(FOnFifoAPush) then
          begin
            FOnFifoAPush(ShortInt(v and $FF));
            FOnFifoAPush(ShortInt((v shr 8) and $FF));
          end
          else if (a >= $040000A4) and (a < $040000A8) and Assigned(FOnFifoBPush) then
          begin
            FOnFifoBPush(ShortInt(v and $FF));
            FOnFifoBPush(ShortInt((v shr 8) and $FF));
          end;

          { DMA CNT_H halfword writes — see WriteByte for rationale. }
          if Assigned(FOnDmaControl) then
          begin
            case a of
              $040000BA: FOnDmaControl(0);
              $040000C6: FOnDmaControl(1);
              $040000D2: FOnDmaControl(2);
              $040000DE: FOnDmaControl(3);
            end;
          end;
        end;
      end;
    REGION_PALETTE:
      begin
        offset := a and PALETTE_MASK;
        FPalette[offset]     := TByte(v        and $FF);
        FPalette[offset + 1] := TByte((v shr 8) and $FF);
      end;
    REGION_VRAM:
      begin
        offset := ResolveVramOffset(a);
        FVram[offset]     := TByte(v        and $FF);
        FVram[offset + 1] := TByte((v shr 8) and $FF);
      end;
    REGION_OAM:
      begin
        offset := a and OAM_MASK;
        FOam[offset]     := TByte(v        and $FF);
        FOam[offset + 1] := TByte((v shr 8) and $FF);
      end;
    REGION_ROM0_LO, REGION_ROM0_HI,
    REGION_ROM1_LO, REGION_ROM1_HI,
    REGION_ROM2_LO, REGION_ROM2_HI: ;
    REGION_SRAM:
      begin
        { SRAM/Flash are 8-bit-only on real hardware — halfword writes
          present only the low byte to the cart. (Real carts may rotate
          the address, but the most common pattern is "write the low
          byte to the addressed offset.") }
        if Assigned(FOnSaveWrite) then
          FOnSaveWrite(a, TByte(v and $FF))
        else
          FSram[a and SRAM_MASK] := TByte(v and $FF);
      end;
  else
    WarnOpenBus('halfword write', a);
  end;
end;

procedure TGbaMemory.WriteWord(addr: TWord; v: TWord);
var
  a: TWord;
begin
  a := addr and not TWord($3);
  WriteHalf(a,     THalf( v          and $FFFF));
  WriteHalf(a + 2, THalf((v shr 16)  and $FFFF));
end;

function IsCpuReadOnlyHalf(addr: TWord): Boolean; inline;
{ Read-only halfword IO registers per GBATEK §15. Each address listed
  here corresponds to a register that real hardware drives from
  internal state — CPU writes are silently dropped by the bus.

    $04000006 VCOUNT   — current scanline, driven by PPU scanout
    $04000130 KEYINPUT — keypad state, driven by hardware key matrix

  Adding to this list should be backed by GBATEK + a cross-reference
  against mGBA/NBA's MMIO write dispatchers — many GBA registers have
  mixed semantics (some bits writable, some not) and bulk-dropping is
  only correct when ALL bits are hardware-driven. }
begin
  case (addr and not TWord($1)) of
    $04000006, $04000130: Result := True;
  else
    Result := False;
  end;
end;

function IsCpuReadOnlyByte(addr: TWord): Boolean; inline;
{ Single-byte view of the read-only halfword set, for STRB stores. }
begin
  case addr of
    $04000006, $04000007,
    $04000130, $04000131: Result := True;
  else
    Result := False;
  end;
end;

procedure TGbaMemory.CpuWriteByte(addr: TWord; v: TByte);
begin
  if IsCpuReadOnlyByte(addr) then Exit;
  WriteByte(addr, v);
end;

procedure TGbaMemory.CpuWriteHalf(addr: TWord; v: THalf);
begin
  if IsCpuReadOnlyHalf(addr) then Exit;
  WriteHalf(addr, v);
end;

procedure TGbaMemory.CpuWriteWord(addr: TWord; v: TWord);
{ Word writes split into two halves so a 32-bit store partially
  overlapping a read-only halfword preserves the writable half. The
  canonical case is a STR.W to $04000130 — KEYINPUT (read-only) +
  KEYCNT (read-write) sit adjacent. Drop the low half, write the high. }
var
  a: TWord;
begin
  a := addr and not TWord($3);
  CpuWriteHalf(a,     THalf( v         and $FFFF));
  CpuWriteHalf(a + 2, THalf((v shr 16) and $FFFF));
end;

procedure TGbaMemory.PokeBiosWord(offsetBytes: Integer; v: TWord);
begin
  if (offsetBytes < 0) or (offsetBytes + 3 >= BIOS_SIZE) then Exit;
  FBios[offsetBytes + 0] := TByte( v         and $FF);
  FBios[offsetBytes + 1] := TByte((v shr 8)  and $FF);
  FBios[offsetBytes + 2] := TByte((v shr 16) and $FF);
  FBios[offsetBytes + 3] := TByte((v shr 24) and $FF);
end;

procedure TGbaMemory.PokeIoHalf(offsetWithinIo: Integer; v: THalf);
begin
  if (offsetWithinIo < 0) or (offsetWithinIo + 1 >= IO_SIZE) then Exit;
  FIo[offsetWithinIo]     := TByte(v        and $FF);
  FIo[offsetWithinIo + 1] := TByte((v shr 8) and $FF);
end;

procedure TGbaMemory.SetHaltRequestHook(hook: THaltRequestHook);
begin
  FOnHaltRequest := hook;
end;

procedure TGbaMemory.SetFifoAPushHook(hook: TFifoPushHook);
begin
  FOnFifoAPush := hook;
end;

procedure TGbaMemory.SetFifoBPushHook(hook: TFifoPushHook);
begin
  FOnFifoBPush := hook;
end;

procedure TGbaMemory.SetDmaControlHook(hook: TDmaControlHook);
begin
  FOnDmaControl := hook;
end;

procedure TGbaMemory.SetSaveReadHook(hook: TSaveReadHook);
begin
  FOnSaveRead := hook;
end;

procedure TGbaMemory.SetSaveWriteHook(hook: TSaveWriteHook);
begin
  FOnSaveWrite := hook;
end;

end.
