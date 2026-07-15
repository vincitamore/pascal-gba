program test_replay;
{
  Unit tests for the replay engine (`src/replay.pas`). Exercises the
  script parser, event scheduling, KEYINPUT override flow, and
  record-mode roundtrip — without needing an emulator scaffolded
  around it.

  Each test writes a tiny script to a temp file, loads it through
  TReplayEngine, then either inspects internal state (EventCount,
  LoadedPath) or runs Tick() across a synthetic frame range and
  asserts the resulting KEYINPUT mask landed correctly.

  Why a dedicated test program: replay's behaviour is most easily
  asserted against a stub TGbaInput that captures every
  OverrideKeyState call. The phase-B tests use real TGbaMemory; we
  want isolation here.
}

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, GbaTypes, Memory, Input, Replay;

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

procedure CheckEqHex(const name: string; expected, actual: TWord);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name, '  (= $', IntToHex(actual, 4), ')');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  ', name,
            '  expected $', IntToHex(expected, 4),
            ', got $',      IntToHex(actual, 4));
    Inc(FailCount);
  end;
end;

procedure CheckBool(const name: string; expected, actual: Boolean);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name, '  (', actual, ')');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  ', name, '  expected ', expected, ', got ', actual);
    Inc(FailCount);
  end;
end;

function WriteTempScript(const content: string): string;
{ Drop a tiny script next to the test exe so it cleans up with bin/. }
var
  f: Text;
begin
  Result := ExtractFilePath(ParamStr(0)) +
            Format('test_replay_temp_%d.txt', [Random($FFFF)]);
  AssignFile(f, Result);
  Rewrite(f);
  Write(f, content);
  CloseFile(f);
end;

procedure TestParseBasic;
{ Smallest interesting script: press + release at known frames. }
var
  mem: TGbaMemory;
  kbd: TGbaInput;
  re:  TReplayEngine;
  path: string;
begin
  Writeln('--- TestParseBasic ---');
  mem := TGbaMemory.Create;
  kbd := TGbaInput.Create(mem, nil);
  re  := TReplayEngine.Create(kbd, mem);
  try
    path := WriteTempScript(
      '0 press START' + LineEnding +
      '60 release START' + LineEnding);
    CheckBool('LoadScript succeeds', True, re.LoadScript(path));
    CheckEq  ('EventCount = 2',      2,    re.EventCount);
  finally
    DeleteFile(path);
    re.Free; kbd.Free; mem.Free;
  end;
end;

procedure TestParseCommentsBlankLines;
{ Comments + blanks must not affect parse. }
var
  mem: TGbaMemory;
  kbd: TGbaInput;
  re:  TReplayEngine;
  path: string;
begin
  Writeln('--- TestParseCommentsBlankLines ---');
  mem := TGbaMemory.Create;
  kbd := TGbaInput.Create(mem, nil);
  re  := TReplayEngine.Create(kbd, mem);
  try
    path := WriteTempScript(
      '# leading comment' + LineEnding +
      '' + LineEnding +
      '10 press A     # inline comment' + LineEnding +
      '' + LineEnding +
      '# another comment' + LineEnding +
      '20 release A' + LineEnding);
    CheckBool('LoadScript succeeds',     True, re.LoadScript(path));
    CheckEq  ('EventCount ignores noise', 2,   re.EventCount);
  finally
    DeleteFile(path);
    re.Free; kbd.Free; mem.Free;
  end;
end;

procedure TestParseTapExpands;
{ A tap expands into press@N + release@N+1 — two events. }
var
  mem: TGbaMemory;
  kbd: TGbaInput;
  re:  TReplayEngine;
  path: string;
begin
  Writeln('--- TestParseTapExpands ---');
  mem := TGbaMemory.Create;
  kbd := TGbaInput.Create(mem, nil);
  re  := TReplayEngine.Create(kbd, mem);
  try
    path := WriteTempScript('100 tap START' + LineEnding);
    CheckBool('LoadScript succeeds',         True, re.LoadScript(path));
    CheckEq  ('tap expanded into 2 events',  2,    re.EventCount);
  finally
    DeleteFile(path);
    re.Free; kbd.Free; mem.Free;
  end;
end;

procedure TestParseUnknownButton;
{ Unknown button name is a fatal parse error — engine left empty. }
var
  mem: TGbaMemory;
  kbd: TGbaInput;
  re:  TReplayEngine;
  path: string;
begin
  Writeln('--- TestParseUnknownButton ---');
  mem := TGbaMemory.Create;
  kbd := TGbaInput.Create(mem, nil);
  re  := TReplayEngine.Create(kbd, mem);
  try
    path := WriteTempScript('0 press TURBO' + LineEnding);
    CheckBool('LoadScript fails',  False, re.LoadScript(path));
    CheckEq  ('EventCount = 0',     0,    re.EventCount);
  finally
    DeleteFile(path);
    re.Free; kbd.Free; mem.Free;
  end;
end;

procedure TestParseMissingFile;
var
  mem: TGbaMemory;
  kbd: TGbaInput;
  re:  TReplayEngine;
begin
  Writeln('--- TestParseMissingFile ---');
  mem := TGbaMemory.Create;
  kbd := TGbaInput.Create(mem, nil);
  re  := TReplayEngine.Create(kbd, mem);
  try
    CheckBool('LoadScript fails on missing path', False,
              re.LoadScript('this/path/does/not/exist.txt'));
  finally
    re.Free; kbd.Free; mem.Free;
  end;
end;

procedure TestParseOutOfOrderSorts;
{ Out-of-order events are valid (sort happens at load time). }
var
  mem: TGbaMemory;
  kbd: TGbaInput;
  re:  TReplayEngine;
  path: string;
begin
  Writeln('--- TestParseOutOfOrderSorts ---');
  mem := TGbaMemory.Create;
  kbd := TGbaInput.Create(mem, nil);
  re  := TReplayEngine.Create(kbd, mem);
  try
    path := WriteTempScript(
      '60 press A' + LineEnding +
      '30 press B' + LineEnding +
      '0  press START' + LineEnding);
    CheckBool('LoadScript succeeds',          True, re.LoadScript(path));
    CheckEq  ('EventCount = 3 (sorted load)', 3,    re.EventCount);
  finally
    DeleteFile(path);
    re.Free; kbd.Free; mem.Free;
  end;
end;

procedure TestTickAppliesEvents;
{ End-to-end: load a script, tick across frames, verify KEYINPUT
  mask transitions match the scripted events. KEYINPUT is active-low:
  $03FF = nothing pressed, $03FE = A pressed (bit 0 clear), etc. }
var
  mem: TGbaMemory;
  kbd: TGbaInput;
  re:  TReplayEngine;
  path: string;
  frame: Integer;
begin
  Writeln('--- TestTickAppliesEvents ---');
  mem := TGbaMemory.Create;
  kbd := TGbaInput.Create(mem, nil);
  re  := TReplayEngine.Create(kbd, mem);
  try
    path := WriteTempScript(
      '5  press A' + LineEnding +
      '10 release A' + LineEnding +
      '15 press START' + LineEnding);
    CheckBool('LoadScript succeeds', True, re.LoadScript(path));

    { Pre-event state: nothing pressed. }
    for frame := 0 to 4 do re.Tick(frame);
    CheckEqHex('frame 4 KEYINPUT = $03FF', $03FF,
               mem.ReadHalf($04000130));

    { Frame 5: A pressed (bit 0 clears). }
    re.Tick(5);
    CheckEqHex('frame 5 A-pressed = $03FE', $03FE,
               mem.ReadHalf($04000130));

    { Frames 6-9: still pressed. }
    for frame := 6 to 9 do re.Tick(frame);
    CheckEqHex('frame 9 still A-pressed', $03FE,
               mem.ReadHalf($04000130));

    { Frame 10: A released. }
    re.Tick(10);
    CheckEqHex('frame 10 A-released = $03FF', $03FF,
               mem.ReadHalf($04000130));

    { Frame 15: START pressed (bit 3 clears, $03FF and not $08 = $03F7). }
    for frame := 11 to 14 do re.Tick(frame);
    re.Tick(15);
    CheckEqHex('frame 15 START-pressed = $03F7', $03F7,
               mem.ReadHalf($04000130));

    CheckBool('Finished after last scripted frame', True, re.Finished);
  finally
    DeleteFile(path);
    re.Free; kbd.Free; mem.Free;
  end;
end;

procedure TestRecordRoundtrip;
{ Load a script, run it, record to a new file, then load that file
  and compare event counts. The recorded events should match the
  original (modulo tap expansion). }
var
  mem: TGbaMemory;
  kbd: TGbaInput;
  re:  TReplayEngine;
  re2: TReplayEngine;
  inputPath, recordPath: string;
  frame: Integer;
begin
  Writeln('--- TestRecordRoundtrip ---');
  mem := TGbaMemory.Create;
  kbd := TGbaInput.Create(mem, nil);
  re  := TReplayEngine.Create(kbd, mem);
  try
    inputPath := WriteTempScript(
      '5  press A' + LineEnding +
      '10 release A' + LineEnding);
    recordPath := ExtractFilePath(ParamStr(0)) +
                  Format('test_replay_record_%d.txt', [Random($FFFF)]);

    CheckBool('LoadScript succeeds', True, re.LoadScript(inputPath));
    re.StartRecording(recordPath);
    for frame := 0 to 20 do re.Tick(frame);
    CheckBool('FlushRecording succeeds', True, re.FlushRecording);
    CheckEq  ('Recorded 2 events',       2,    re.RecordCount);

    { Load the recording back through a fresh engine. }
    re2 := TReplayEngine.Create(kbd, mem);
    try
      CheckBool('Roundtripped script loads', True, re2.LoadScript(recordPath));
      CheckEq  ('Roundtripped count matches', 2, re2.EventCount);
    finally
      re2.Free;
    end;

    DeleteFile(inputPath);
    DeleteFile(recordPath);
  finally
    re.Free; kbd.Free; mem.Free;
  end;
end;

procedure TestParseDumpStateAction;
{ The path-shaped `dump-state` action mirrors `screenshot` but routes to
  DumpDebugState rather than the framebuffer writer. Parser stores the
  path as the event's Path field; Tick at the matching frame queues a
  TReplaySideEffect with Kind=sekDumpState and the supplied path. The
  replay engine itself has no DumpDebugState access -- the host
  (gba_runner) drains the queue. We test the bridge: parse + queue. }
var
  mem: TGbaMemory;
  kbd: TGbaInput;
  re:  TReplayEngine;
  path: string;
  fx:  TReplaySideEffect;
begin
  Writeln('--- TestParseDumpStateAction ---');
  mem := TGbaMemory.Create;
  kbd := TGbaInput.Create(mem, nil);
  re  := TReplayEngine.Create(kbd, mem);
  try
    path := WriteTempScript(
      '10 dump-state bin/dump_f10.txt' + LineEnding);
    CheckBool('LoadScript succeeds',          True, re.LoadScript(path));
    CheckEq  ('EventCount = 1',                1,   re.EventCount);

    { Frames 0-9: nothing scheduled, no side effects. }
    re.Tick(0);
    CheckEq  ('frame 0 no side effects',       0,   re.SideEffectCount);
    re.Tick(9);
    CheckEq  ('frame 9 no side effects',       0,   re.SideEffectCount);

    { Frame 10: dump-state fires, side effect queued. }
    re.Tick(10);
    CheckEq  ('frame 10 one side effect',      1,   re.SideEffectCount);
    fx := re.SideEffect(0);
    CheckEq  ('side effect Kind = sekDumpState',
              Ord(sekDumpState), Ord(fx.Kind));
    CheckBool('side effect Path = bin/dump_f10.txt',
              True, fx.Path = 'bin/dump_f10.txt');

    { Frame 11: queue drained at start of Tick. }
    re.Tick(11);
    CheckEq  ('frame 11 queue drained',        0,   re.SideEffectCount);
  finally
    DeleteFile(path);
    re.Free; kbd.Free; mem.Free;
  end;
end;

begin
  Randomize;
  Writeln('Replay engine tests');
  Writeln('==========================================');
  Writeln('');
  TestParseBasic;            Writeln('');
  TestParseCommentsBlankLines; Writeln('');
  TestParseTapExpands;       Writeln('');
  TestParseUnknownButton;    Writeln('');
  TestParseMissingFile;      Writeln('');
  TestParseOutOfOrderSorts;  Writeln('');
  TestTickAppliesEvents;     Writeln('');
  TestRecordRoundtrip;       Writeln('');
  TestParseDumpStateAction;  Writeln('');
  Writeln('==========================================');
  Writeln(Format('Result: %d pass, %d fail', [PassCount, FailCount]));
  if FailCount > 0 then Halt(1);
end.
