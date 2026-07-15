unit Kit_Fixed;
{
  24.8 fixed-point arithmetic for cart game logic.

  The GBA has no FPU; floating point on -Tgba is software-emulated and
  slow. 24.8 gives 1/256-pixel positional resolution with a +/-8M
  integer range — comfortably past anything a 240x160 game needs, and
  multiplications fit the widening path below without overflow.

  Pure Pascal, no MMIO — compiles and tests host-side.
}

{$mode objfpc}{$H+}

interface

type
  TFixed = LongInt;   { 24.8: high 24 bits integer, low 8 bits fraction }

const
  FIX_ONE  = 256;
  FIX_HALF = 128;

function FixFromInt(v: LongInt): TFixed; inline;
function FixToInt(v: TFixed): LongInt; inline;      { truncates toward -inf }
function FixMul(a, b: TFixed): TFixed; inline;
function FixDiv(a, b: TFixed): TFixed; inline;      { b = 0 returns 0 }
function FixFrac(v: TFixed): LongInt; inline;       { fractional bits, 0..255 }

implementation

function FixFromInt(v: LongInt): TFixed;
begin
  Result := v shl 8;
end;

function FixToInt(v: TFixed): LongInt;
begin
  Result := SarLongint(v, 8);   { arithmetic shift keeps negatives sane }
end;

function FixMul(a, b: TFixed): TFixed;
begin
  Result := TFixed((Int64(a) * Int64(b)) div 256);
end;

function FixDiv(a, b: TFixed): TFixed;
begin
  if b = 0 then Exit(0);
  Result := TFixed((Int64(a) * 256) div b);
end;

function FixFrac(v: TFixed): LongInt;
begin
  Result := v and $FF;
end;

end.
