unit Dbg_Log;
{
  Game-side `DbgLog` capture for the headless/dev harness.

  Pascal game code (compiled with FPC -Tgba) calls `DbgLog('msg %d',
  [42])` from `gba_dbg.pas` (the Pascal-side helper unit); that helper
  writes the formatted string into a known EWRAM region. This emulator-
  side unit polls the region once per frame, reads any pending message,
  prints it to stdout via SafeLog, and clears the ready byte.

  ── Wire format ──

    $0203FF80..$0203FFFE  string content (null-terminated, ≤127 chars)
    $0203FFFF             ready byte:
                            0     → idle (no message pending)
                            != 0  → message ready; value is the LOG LEVEL
                                    (1 info, 2 warn, 3 error — convention,
                                    not enforced).

  The emulator reads the string up to the first null byte or 127 chars,
  whichever comes first. Non-printable bytes are mapped to '?' so the
  output doesn't garble the host log. The ready byte is cleared via host
  WriteByte after capture — game code can safely write a new message
  the very next frame.

  ── Ring buffer ──

  The last `DBG_RING_CAPACITY` messages are retained in a circular
  buffer so the F12 debug dump can print a "DbgLog tail" section
  showing the most recent game-side narration. Helpful for diagnosing
  "what was the game doing when it wedged" without re-running with
  a tee'd stdout.

  ── Why EWRAM tail, not IWRAM ──

  mGBA uses a special MMIO region at $04FFF600+ for its debug-print
  protocol. The original convention placed the buffer in IWRAM at
  $03007E80, with a comment claiming it sat "comfortably out of the way
  of normal cart use" below the BIOS IRQ stack. That assertion was
  wrong: the BIOS post-reset SP_usr is $03007F00 and the cart's user
  stack grows down through any IWRAM region nominally reserved below
  it. The first nested function call's frame lands inside such a
  region. Pre-existing code happened to be safe because it only wrote
  the lowest portion of the buffer (below the deepest active frame at
  the moment of the call), but any operation that touched the upper
  portion (a defensive zero-fill, a future raw-buffer inspect) clobbered
  callers' saved registers.

  Relocated 2026-05-22 to the EWRAM tail at $0203FF80..$0203FFFF. EWRAM
  is 256 KB and the upper end is structurally inaccessible from the
  IWRAM stack — no user-stack overlap is possible regardless of cart
  call depth. Trade-off: EWRAM access is 3-cycle vs IWRAM's 1-cycle,
  so each DbgLog call pays roughly ~3x the per-byte cost. On a 16.78
  MHz cart that is ~20 microseconds vs ~5 microseconds per call, both
  negligible on a debug-narration path. Real hardware: writes/reads go
  through the same EWRAM bus the BIOS uses for the cart's heap and
  ROM-to-EWRAM copy paths, so behaviour is well-understood and stable.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes, Memory;

const
  { Convention surface — Pascal-side helper at `gba_dbg.pas` MUST
    agree on these constants byte-for-byte. }
  DBG_REGION_BASE   = $0203FF80;
  DBG_REGION_SIZE   = 128;
  DBG_STRING_MAX    = DBG_REGION_SIZE - 1;   { 127 chars + null }
  DBG_SENTINEL_ADDR = DBG_REGION_BASE + DBG_REGION_SIZE - 1;  { $0203FFFF }

  { Ring buffer depth. 16 entries × ~80-char average ≈ 1.3 KB —
    enough to capture the narration during a typical wedge without
    blowing the per-frame budget. }
  DBG_RING_CAPACITY = 16;

type
  TDbgLogEntry = record
    Frame: Int64;
    Level: TByte;
    Text:  string;
  end;

  TDbgLog = class
  private
    FMem:        TGbaMemory;
    FRing:       array[0 .. DBG_RING_CAPACITY - 1] of TDbgLogEntry;
    FRingHead:   Integer;     { next write slot, wraps mod CAPACITY }
    FRingCount:  Integer;     { entries currently in ring (0..CAPACITY) }
    FTotalCount: Int64;       { total messages ever captured }

    procedure AppendToRing(const entry: TDbgLogEntry);
  public
    constructor Create(mem: TGbaMemory);

    { Called once per emulated frame. Polls the ready byte; if non-zero,
      reads the string, prints it, appends to ring, and clears the
      ready byte. Cheap when there's nothing to do (single byte read +
      zero-check). }
    procedure Tick(frame: Int64);

    { F12 dump support — write the ring buffer to the supplied text
      file in chronological order (oldest first). Header includes the
      total-count so a reader can see whether messages have been
      dropped beyond the ring capacity. }
    procedure WriteTail(var f: Text);

    { Diagnostic accessors. EntryCount returns 0 when no messages have
      ever been captured; TotalCount distinguishes "ring just rotated"
      from "no messages this run". }
    function  EntryCount: Integer;
    function  GetEntry(idx: Integer): TDbgLogEntry;
    property  TotalCount: Int64 read FTotalCount;
  end;

implementation

constructor TDbgLog.Create(mem: TGbaMemory);
begin
  inherited Create;
  FMem        := mem;
  FRingHead   := 0;
  FRingCount  := 0;
  FTotalCount := 0;
end;

procedure TDbgLog.AppendToRing(const entry: TDbgLogEntry);
begin
  FRing[FRingHead] := entry;
  FRingHead := (FRingHead + 1) mod DBG_RING_CAPACITY;
  if FRingCount < DBG_RING_CAPACITY then Inc(FRingCount);
  Inc(FTotalCount);
end;

procedure TDbgLog.Tick(frame: Int64);
var
  ready: TByte;
  i: Integer;
  ch: TByte;
  s: string;
  entry: TDbgLogEntry;
begin
  ready := FMem.ReadByte(DBG_SENTINEL_ADDR);
  if ready = 0 then Exit;

  { Read the null-terminated string. Cap at DBG_STRING_MAX so we don't
    runaway-read into the ready byte; map non-printable bytes to
    '?' so the log stays text-safe. }
  s := '';
  for i := 0 to DBG_STRING_MAX - 1 do
  begin
    ch := FMem.ReadByte(DBG_REGION_BASE + TWord(i));
    if ch = 0 then Break;
    if (ch >= 32) and (ch < 127) then
      s := s + Chr(ch)
    else
      s := s + '?';
  end;

  SafeLog(Format('[dbglog f%d L%d] %s', [frame, ready, s]));

  entry.Frame := frame;
  entry.Level := ready;
  entry.Text  := s;
  AppendToRing(entry);

  { Clear ready byte via host write path (FMem.WriteByte). IWRAM has no
    read-only enforcement so a plain WriteByte works. We do NOT clear
    the string buffer — the next message will overwrite it on its way
    to setting the ready byte, and leaving stale text doesn't affect
    correctness (ready = 0 means "ignore the buffer"). }
  FMem.WriteByte(DBG_SENTINEL_ADDR, 0);
end;

procedure TDbgLog.WriteTail(var f: Text);
var
  i, idx: Integer;
begin
  Writeln(f, Format('── DbgLog tail (%d in ring, %d total) ──',
    [FRingCount, FTotalCount]));
  for i := 0 to FRingCount - 1 do
  begin
    { Chronological order: oldest first. With FRingHead pointing at
      the next write slot, the oldest entry is FRingHead - FRingCount
      (mod CAPACITY). }
    idx := (FRingHead - FRingCount + i + DBG_RING_CAPACITY)
           mod DBG_RING_CAPACITY;
    Writeln(f, Format('  f%d L%d  %s',
      [FRing[idx].Frame, FRing[idx].Level, FRing[idx].Text]));
  end;
end;

function TDbgLog.EntryCount: Integer;
begin
  Result := FRingCount;
end;

function TDbgLog.GetEntry(idx: Integer): TDbgLogEntry;
var
  realIdx: Integer;
begin
  if (idx < 0) or (idx >= FRingCount) then
  begin
    Result.Frame := -1;
    Result.Level := 0;
    Result.Text  := '';
    Exit;
  end;
  realIdx := (FRingHead - FRingCount + idx + DBG_RING_CAPACITY)
             mod DBG_RING_CAPACITY;
  Result := FRing[realIdx];
end;

end.
