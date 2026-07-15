unit Gba_Dbg;
{
  Pascal-side helper for the DbgLog wire convention. Writes formatted
  strings to EWRAM at $0203FF80..$0203FFFF where the emulator's
  dbg_log poll (see `dbg_log.pas`) picks them up and prints /
  ring-buffers them.

  ── Use ──

    uses Gba_Dbg;

    begin
      DbgLog('Boot complete, frame=%d', [framecount]);
      DbgLog('Player at (%d, %d) HP=%d', [x, y, hp]);
      DbgLogStr('checkpoint reached');
      DbgLogLevel(DBG_WARN, 'low ammo: %d rounds', [ammo]);
    end.

  ── Convention surface ──

    $0203FF80..$0203FFFE  string content (null-terminated, ≤127 chars)
    $0203FFFF             ready byte:
                            0     → idle (no message pending)
                            != 0  → message ready; value is the LOG LEVEL
                                    (1 info, 2 warn, 3 error)

  Game code MUST write the string FIRST, ready byte LAST. Once the
  ready byte is set, the emulator may consume the message at any frame
  boundary. The emulator clears the ready byte after capture, so the
  game can write a new message the very next frame without waiting.

  ── Compile target ──

  This unit assumes FPC's `-Tgba` cross-compile target. It uses raw
  pointer writes to specific GBA-only memory addresses; compiling on
  a host platform produces code that will segfault when run, but the
  source is target-portable for inspection / review.

  ── Format() caveat ──

  Without a working devkitARM libsysbase + newlib heap, FPC's
  `Format` (used by `DbgLog` and `DbgLogLevel`) may produce garbage
  strings — the heap allocator falls back on `sbrk` which our stub
  libsysbase provides only trivially. `DbgLogStr` (no formatting)
  is purely byte copies + ready-byte write — no heap needed. Until
  we ship a real libgba / libsysbase, prefer `DbgLogStr` with
  pre-built strings.

  ── Cost ──

  `DbgLogStr` zero-fills the full 127-byte region first, then copies N
  content bytes, the null terminator, and the ready byte. Roughly
  127 + N + 2 EWRAM byte writes. The zero-fill prevents stale trailing
  bytes from a prior longer message bleeding through past the new
  message's null terminator -- post-mortem inspection of the raw
  $0203FF80..$0203FFFE region matches the emulator-side capture byte
  for byte. EWRAM is 3-cycle access vs IWRAM's 1-cycle, so this is
  ~3x more expensive than the original IWRAM-based design, but on a
  debug-narration path the absolute cost is still ~20 µs per call --
  irrelevant for shipping code that uses DbgLog sparsely.

  ── Why EWRAM and not IWRAM ──

  The original convention placed the buffer in IWRAM at $03007E80 with
  a comment claiming it sat "comfortably out of the way of normal cart
  use" below the BIOS IRQ stack. That assertion was wrong: the BIOS
  post-reset SP_usr is $03007F00, and the cart's user stack grows DOWN
  through any IWRAM region nominally reserved below it. The first
  nested function call's frame lands inside such a region. Writing to
  the upper portion of the buffer clobbers the callers' saved fp/lr/pc
  and produces unmapped-access floods. Relocated to the EWRAM tail on
  2026-05-22 for that reason (see the matching note in dbg_log.pas).

  ── Pairing with mGBA ──

  This convention is not mGBA-compatible (mGBA uses $04FFF600+ MMIO
  with a 0xC0DE enable handshake). A future enhancement would teach
  the Pascal helper to ALSO mirror the message to the mGBA region,
  so the same source runs identically under both emulators. For now:
  Pascal-emulator only.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  { Level constants — convention, not enforced. Callers may pass any
    non-zero byte but these match the dbg_log.pas log-level
    interpretation. }
  DBG_INFO  = 1;
  DBG_WARN  = 2;
  DBG_ERROR = 3;

  { Wire-format addresses. MUST match dbg_log.pas exactly. }
  DBG_REGION_BASE   = $0203FF80;
  DBG_STRING_MAX    = 127;
  DBG_SENTINEL_ADDR = $0203FFFF;

{ Write a pre-formatted string. Capped at DBG_STRING_MAX chars; longer
  strings are truncated (no error). Ready byte is set to DBG_INFO. }
procedure DbgLogStr(const s: ansistring);

{ Format and write. Identical to DbgLogStr(Format(fmt, args)). }
procedure DbgLog(const fmt: ansistring; const args: array of const);

{ Write with explicit log level (1..255). Use DBG_WARN / DBG_ERROR
  constants for human-readable call sites. }
procedure DbgLogLevel(level: Byte; const fmt: ansistring;
                      const args: array of const);

{ Block until the emulator's dbg_log poll has consumed our last
  message (ready byte cleared back to 0). Use between DbgLog
  calls when sending a burst that exceeds 1 message per emulated
  frame — without this, later messages overwrite earlier ones
  before the poll observes them. }
procedure DbgLogWaitConsumed;

implementation

procedure DbgLogStrWithLevel(const s: ansistring; level: Byte);
var
  i, n: Integer;
  p: ^Byte;
begin
  n := Length(s);
  if n > DBG_STRING_MAX then n := DBG_STRING_MAX;

  { Zero the full DBG_STRING_MAX-byte buffer FIRST. Without this, a new
    short message that overwrites only the head bytes leaves stale
    content from a prior longer message past its own null terminator.
    The emulator-side capture's C-string read stops at the first null
    so the trailing stale bytes are normally invisible -- BUT any
    direct inspection of the raw 127-byte region (a debugger UI,
    a post-mortem dump, a future register-corruption regression that
    sprinkles non-printable bytes mid-string) picks them up and
    masquerades the stale data as new content. Cheap defense at ~127
    EWRAM byte writes per debug-log call. Safe in EWRAM (no stack
    overlap); was unsafe in the original IWRAM location, see header
    "Why EWRAM and not IWRAM" note. }
  p := Pointer(DBG_REGION_BASE);
  for i := 0 to DBG_STRING_MAX - 1 do
  begin
    p^ := 0;
    Inc(p);
  end;

  { String content. Index 1-based because Pascal strings are. The
    pointer p walks the destination EWRAM bytes; we deliberately use
    raw pointer arithmetic rather than Move() because Move pulls in
    RTL machinery a -Tgba ROM may not have. }
  p := Pointer(DBG_REGION_BASE);
  for i := 1 to n do
  begin
    p^ := Byte(s[i]);
    Inc(p);
  end;
  p^ := 0;   { null-terminate the string content }

  { Ready byte LAST -- this is the ordering contract with the emulator.
    Once set, the emulator may consume the message on the next frame
    boundary; setting it before the content is fully written would
    race. }
  PByte(DBG_SENTINEL_ADDR)^ := level;
end;

procedure DbgLogStr(const s: ansistring);
begin
  DbgLogStrWithLevel(s, DBG_INFO);
end;

procedure DbgLog(const fmt: ansistring; const args: array of const);
begin
  DbgLogStrWithLevel(Format(fmt, args), DBG_INFO);
end;

procedure DbgLogLevel(level: Byte; const fmt: ansistring;
                     const args: array of const);
begin
  DbgLogStrWithLevel(Format(fmt, args), level);
end;

procedure DbgLogWaitConsumed;
begin
  while PByte(DBG_SENTINEL_ADDR)^ <> 0 do ;
end;

end.
