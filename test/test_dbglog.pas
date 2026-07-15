program test_dbglog;
{
  Unit tests for game-side DbgLog capture (`src/dbg_log.pas`).
  Exercises the IWRAM-region poll, string read, ring-buffer behaviour,
  and flag-byte clear cycle.

  We don't need a -Tgba cross-compile to test this side — Pascal game
  code's job is to write the IWRAM bytes through normal stores; here
  we just poke them directly via TGbaMemory.WriteByte and call
  dbglog.Tick. Same result.

  Tests cover:
    - Single message capture (string read, level passed through,
      flag-byte clear)
    - Multi-message capture (chronological ordering in ring)
    - Ring overflow (oldest entries drop when capacity exceeded)
    - Non-printable bytes mapped to '?'
    - Truncation at string-max length
    - Flag byte = 0 -> no capture (no spurious tick)
}

{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, Memory, Dbg_Log;

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

procedure CheckEq(const name: string; expected, actual: Integer);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name, '  (= ', actual, ')');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  ', name, '  expected ', expected, ', got ', actual);
    Inc(FailCount);
  end;
end;

procedure CheckEqStr(const name: string; expected, actual: string);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name, '  ("', actual, '")');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  ', name);
    Writeln('         expected: "', expected, '"');
    Writeln('         got:      "', actual, '"');
    Inc(FailCount);
  end;
end;

procedure CheckEqInt64(const name: string; expected, actual: Int64);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name, '  (= ', actual, ')');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  ', name, '  expected ', expected, ', got ', actual);
    Inc(FailCount);
  end;
end;

procedure WriteMessage(mem: TGbaMemory; const s: string; level: TByte);
{ Helper — write a message + flag byte into the convention region as a
  game-side caller would. Doesn't null-terminate beyond `s` since the
  region's previous content is irrelevant (flag = 0 stops reads). }
var
  i, n: Integer;
begin
  n := Length(s);
  if n > DBG_STRING_MAX then n := DBG_STRING_MAX;
  for i := 1 to n do
    mem.WriteByte(DBG_REGION_BASE + TWord(i - 1), TByte(Ord(s[i])));
  mem.WriteByte(DBG_REGION_BASE + TWord(n), 0);   { null-terminate }
  mem.WriteByte(DBG_SENTINEL_ADDR, level);         { trigger }
end;

procedure TestSingleMessage;
var
  mem: TGbaMemory;
  log: TDbgLog;
  e: TDbgLogEntry;
begin
  Writeln('--- TestSingleMessage ---');
  mem := TGbaMemory.Create;
  log := TDbgLog.Create(mem);
  try
    WriteMessage(mem, 'hello world', 1);
    log.Tick(42);
    CheckEq    ('EntryCount = 1', 1, log.EntryCount);
    CheckEqInt64('TotalCount = 1', 1, log.TotalCount);
    e := log.GetEntry(0);
    CheckEqStr ('captured text = "hello world"', 'hello world', e.Text);
    CheckEq    ('captured level = 1',   1,  e.Level);
    CheckEqInt64('captured frame = 42', 42, e.Frame);
    CheckEq    ('flag byte cleared to 0', 0,
                mem.ReadByte(DBG_SENTINEL_ADDR));
  finally
    log.Free; mem.Free;
  end;
end;

procedure TestNoMessageNoCapture;
var
  mem: TGbaMemory;
  log: TDbgLog;
begin
  Writeln('--- TestNoMessageNoCapture ---');
  mem := TGbaMemory.Create;
  log := TDbgLog.Create(mem);
  try
    log.Tick(100);
    log.Tick(101);
    log.Tick(102);
    CheckEq    ('EntryCount = 0',  0, log.EntryCount);
    CheckEqInt64('TotalCount = 0', 0, log.TotalCount);
  finally
    log.Free; mem.Free;
  end;
end;

procedure TestMultipleMessages;
var
  mem: TGbaMemory;
  log: TDbgLog;
  e0, e1, e2: TDbgLogEntry;
begin
  Writeln('--- TestMultipleMessages ---');
  mem := TGbaMemory.Create;
  log := TDbgLog.Create(mem);
  try
    WriteMessage(mem, 'first',  1);  log.Tick(10);
    WriteMessage(mem, 'second', 2);  log.Tick(20);
    WriteMessage(mem, 'third',  3);  log.Tick(30);
    CheckEq    ('EntryCount = 3', 3, log.EntryCount);
    CheckEqInt64('TotalCount = 3', 3, log.TotalCount);
    e0 := log.GetEntry(0); e1 := log.GetEntry(1); e2 := log.GetEntry(2);
    CheckEqStr ('oldest is "first"',  'first',  e0.Text);
    CheckEqStr ('middle is "second"', 'second', e1.Text);
    CheckEqStr ('newest is "third"',  'third',  e2.Text);
    CheckEqInt64('frame[0] = 10', 10, e0.Frame);
    CheckEqInt64('frame[2] = 30', 30, e2.Frame);
  finally
    log.Free; mem.Free;
  end;
end;

procedure TestRingOverflowDropsOldest;
var
  mem: TGbaMemory;
  log: TDbgLog;
  e0, e_last: TDbgLogEntry;
  i: Integer;
begin
  Writeln('--- TestRingOverflowDropsOldest ---');
  mem := TGbaMemory.Create;
  log := TDbgLog.Create(mem);
  try
    { Write CAPACITY+5 messages. Oldest 5 should be evicted. }
    for i := 0 to DBG_RING_CAPACITY + 4 do
    begin
      WriteMessage(mem, Format('msg%d', [i]), 1);
      log.Tick(Int64(i));
    end;
    CheckEq    ('EntryCount = CAPACITY',
                DBG_RING_CAPACITY, log.EntryCount);
    CheckEqInt64('TotalCount = CAPACITY+5',
                Int64(DBG_RING_CAPACITY + 5), log.TotalCount);
    { Oldest entry in ring is msg5 (msg0..msg4 dropped). }
    e0 := log.GetEntry(0);
    CheckEqStr ('oldest is "msg5"', 'msg5', e0.Text);
    { Newest entry is msg(CAPACITY+4). }
    e_last := log.GetEntry(log.EntryCount - 1);
    CheckEqStr ('newest is "msg' + IntToStr(DBG_RING_CAPACITY + 4) + '"',
                'msg' + IntToStr(DBG_RING_CAPACITY + 4), e_last.Text);
  finally
    log.Free; mem.Free;
  end;
end;

procedure TestNonPrintableMapsToQuestion;
var
  mem: TGbaMemory;
  log: TDbgLog;
  e: TDbgLogEntry;
begin
  Writeln('--- TestNonPrintableMapsToQuestion ---');
  mem := TGbaMemory.Create;
  log := TDbgLog.Create(mem);
  try
    { Manual write: A, [bell], B, [null]. The bell character is < 32. }
    mem.WriteByte(DBG_REGION_BASE + 0, Ord('A'));
    mem.WriteByte(DBG_REGION_BASE + 1, 7);   { bell }
    mem.WriteByte(DBG_REGION_BASE + 2, Ord('B'));
    mem.WriteByte(DBG_REGION_BASE + 3, 0);
    mem.WriteByte(DBG_SENTINEL_ADDR,   1);
    log.Tick(0);
    e := log.GetEntry(0);
    CheckEqStr('non-printable mapped to ?', 'A?B', e.Text);
  finally
    log.Free; mem.Free;
  end;
end;

procedure TestTruncationAtMax;
var
  mem: TGbaMemory;
  log: TDbgLog;
  e: TDbgLogEntry;
  long: string;
  i: Integer;
begin
  Writeln('--- TestTruncationAtMax ---');
  mem := TGbaMemory.Create;
  log := TDbgLog.Create(mem);
  try
    { Build a 200-char source string. WriteMessage caps at DBG_STRING_MAX. }
    long := '';
    for i := 1 to 200 do long := long + 'X';
    WriteMessage(mem, long, 1);
    log.Tick(0);
    e := log.GetEntry(0);
    CheckEq('captured length = DBG_STRING_MAX',
            DBG_STRING_MAX, Length(e.Text));
  finally
    log.Free; mem.Free;
  end;
end;

procedure TestSentinelClearBlocksReread;
var
  mem: TGbaMemory;
  log: TDbgLog;
begin
  Writeln('--- TestSentinelClearBlocksReread ---');
  mem := TGbaMemory.Create;
  log := TDbgLog.Create(mem);
  try
    WriteMessage(mem, 'only-once', 1);
    log.Tick(0);
    log.Tick(1);   { flag byte cleared, so no capture }
    log.Tick(2);   { still no capture }
    CheckEq    ('EntryCount = 1 after repeated ticks',  1, log.EntryCount);
    CheckEqInt64('TotalCount = 1 after repeated ticks', 1, log.TotalCount);
  finally
    log.Free; mem.Free;
  end;
end;

begin
  Writeln('DbgLog capture tests');
  Writeln('==========================================');
  Writeln('');
  TestSingleMessage;             Writeln('');
  TestNoMessageNoCapture;        Writeln('');
  TestMultipleMessages;          Writeln('');
  TestRingOverflowDropsOldest;   Writeln('');
  TestNonPrintableMapsToQuestion; Writeln('');
  TestTruncationAtMax;           Writeln('');
  TestSentinelClearBlocksReread; Writeln('');
  Writeln('==========================================');
  Writeln(Format('Result: %d pass, %d fail', [PassCount, FailCount]));
  if FailCount > 0 then Halt(1);
end.
