program test_kit;
{
  Host-side tests for the cart framework kit's pure units:
  Kit_Rng (determinism, range), Kit_Fixed (arithmetic), Kit_Scene
  (switch semantics), Kit_Save's pure checksum helper.

  Kit_Input and the Sram* half of Kit_Save touch cart MMIO and are
  exercised by the kit demo cart (test\kit_demo.pp) instead.
}

{$mode objfpc}{$H+}

uses
  SysUtils, Kit_Rng, Kit_Fixed, Kit_Scene, Kit_Save;

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

procedure CheckEq(const name: string; expected, actual: Int64);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name);
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  ', name, '  expected=', expected, ' actual=', actual);
    Inc(FailCount);
  end;
end;

procedure CheckEqHex(const name: string; expected, actual: LongWord);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name);
    Inc(PassCount);
  end
  else
  begin
    Writeln(Format('  FAIL  %s  expected=$%x actual=$%x', [name, expected, actual]));
    Inc(FailCount);
  end;
end;

{ ── Kit_Rng ── }

procedure TestRngSequence;
begin
  Writeln('--- TestRngSequence ---');
  { xorshift32 from seed 1: pinned reference sequence. A regression
    here breaks every recorded game replay — this is the determinism
    contract, not an implementation detail. }
  RngSeed(1);
  CheckEqHex('seed 1 value 1', $00042021, RngNext);
  CheckEqHex('seed 1 value 2', $04080601, RngNext);
  CheckEqHex('seed 1 value 3', $9DCCA8C5, RngNext);
  CheckEqHex('seed 1 value 4', $1255994F, RngNext);
  CheckEqHex('seed 1 value 5', $8EF917D1, RngNext);

  { Reseeding restarts the sequence exactly. }
  RngSeed(1);
  CheckEqHex('reseed restarts', $00042021, RngNext);

  { Zero seed is remapped, not a fixed point. }
  RngSeed(0);
  if RngNext = 0 then
  begin
    Writeln('  FAIL  zero seed produced zero');
    Inc(FailCount);
  end
  else
  begin
    Writeln('  PASS  zero seed remapped');
    Inc(PassCount);
  end;
end;

procedure TestRngRange;
var
  i: Integer;
  v: LongWord;
  ok: Boolean;
begin
  Writeln('--- TestRngRange ---');
  RngSeed(12345);
  ok := True;
  for i := 1 to 1000 do
  begin
    v := RngRange(10);
    if v > 9 then ok := False;
  end;
  if ok then begin Writeln('  PASS  RngRange(10) bounded over 1000 draws'); Inc(PassCount); end
        else begin Writeln('  FAIL  RngRange(10) out of bounds');           Inc(FailCount); end;
  CheckEq('RngRange(0) = 0', 0, Int64(RngRange(0)));
  CheckEq('RngRange(1) = 0', 0, Int64(RngRange(1)));
end;

{ ── Kit_Fixed ── }

procedure TestFixed;
var
  zero: TFixed;
begin
  Writeln('--- TestFixed ---');
  zero := 0;   { defeat constant folding — the compile-time path would
                 reject the literal division below outright }
  CheckEq('FromInt/ToInt roundtrip', 42, FixToInt(FixFromInt(42)));
  CheckEq('negative roundtrip', -7, FixToInt(FixFromInt(-7)));
  CheckEq('one * one', FIX_ONE, FixMul(FIX_ONE, FIX_ONE));
  CheckEq('3 * 1.5 = 4.5', FIX_ONE * 4 + FIX_HALF,
          FixMul(FixFromInt(3), FIX_ONE + FIX_HALF));
  CheckEq('neg mul', -FIX_ONE * 6, FixMul(FixFromInt(-4), FIX_ONE + FIX_HALF));
  CheckEq('div identity', FIX_ONE + FIX_HALF,
          FixDiv(FixFromInt(3), FixFromInt(2)));
  CheckEq('div by zero = 0', 0, FixDiv(FixFromInt(3), zero));
  CheckEq('frac of 1.5', 128, FixFrac(FIX_ONE + FIX_HALF));
  CheckEq('ToInt floors toward -inf', -2, FixToInt(-FIX_ONE - FIX_HALF));
end;

{ ── Kit_Scene ── }

var
  initA, updA, initB, updB: Integer;
  framesSeenAtBInit: LongWord;

procedure SceneAInit;  begin Inc(initA); end;
procedure SceneAUpd;   begin Inc(updA);  end;
procedure SceneBInit;  begin Inc(initB); framesSeenAtBInit := SceneFrames; end;
procedure SceneBUpd;   begin Inc(updB);  end;

procedure TestScene;
begin
  Writeln('--- TestScene ---');
  initA := 0; updA := 0; initB := 0; updB := 0;

  CheckEq('no scene before first switch', -1, SceneCurrent);
  SceneTick;   { no-op without a scene }
  CheckEq('tick without scene is safe', -1, SceneCurrent);

  SceneRegister(0, @SceneAInit, @SceneAUpd);
  SceneRegister(1, @SceneBInit, @SceneBUpd);

  SceneSwitch(0);
  CheckEq('switch latches, not applies', -1, SceneCurrent);
  SceneTick;
  CheckEq('current after tick', 0, SceneCurrent);
  CheckEq('init ran once', 1, initA);
  CheckEq('update ran same tick', 1, updA);
  CheckEq('frames 0 on switch-in tick', 0, Int64(SceneFrames));

  SceneTick;
  SceneTick;
  CheckEq('frames advance', 2, Int64(SceneFrames));
  CheckEq('init not re-run', 1, initA);
  CheckEq('update per tick', 3, updA);

  SceneSwitch(1);
  SceneTick;
  CheckEq('switched to B', 1, SceneCurrent);
  CheckEq('B init once', 1, initB);
  CheckEq('frames reset for B init', 0, Int64(framesSeenAtBInit));
  CheckEq('A untouched by B ticks', 3, updA);

  { Invalid switches are ignored. }
  SceneSwitch(31);            { registered? no }
  SceneSwitch(-1);
  SceneSwitch(MAX_SCENES);
  SceneTick;
  CheckEq('invalid switches ignored', 1, SceneCurrent);
end;

{ ── Kit_Save (pure part) ── }

procedure TestChecksum;
var
  buf: array[0..7] of Byte;
  i: Integer;
begin
  Writeln('--- TestChecksum ---');
  for i := 0 to 7 do buf[i] := i;
  { 0 xor 1 xor ... xor 7 = 0 }
  CheckEq('xor 0..7 = 0', 0, KitXorChecksum(@buf[0], 8));
  buf[3] := $FF;
  CheckEq('xor with $FF at [3]', $FF xor 3, KitXorChecksum(@buf[0], 8));
  CheckEq('empty checksum = 0', 0, KitXorChecksum(@buf[0], 0));
end;

begin
  TestRngSequence;
  TestRngRange;
  TestFixed;
  TestScene;
  TestChecksum;

  Writeln('==========================================');
  Writeln(Format('Result: %d pass, %d fail', [PassCount, FailCount]));
  if FailCount > 0 then Halt(1);
end.
