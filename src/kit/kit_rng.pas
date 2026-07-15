unit Kit_Rng;
{
  Seeded deterministic PRNG for cart game logic — xorshift32.

  Determinism is the contract: the same seed always produces the same
  sequence, on host and on the GBA, which is what makes input-replay
  regression of game logic possible. Never mix wall-clock or hardware
  entropy into game state through this unit; derive the seed from fixed
  data (or from player input timing captured INTO the replay).

  Pure Pascal, no MMIO — compiles and tests host-side.
}

{$mode objfpc}{$H+}

interface

{ Seed the generator. Zero is remapped to a fixed nonzero constant
  (xorshift32 has a fixed point at zero). }
procedure RngSeed(seed: LongWord);

{ Next raw 32-bit value. Never returns zero. }
function RngNext: LongWord;

{ Uniform-ish value in 0..n-1. n = 0 returns 0. Modulo bias is
  negligible for game-feel use (n is always tiny against 2^32). }
function RngRange(n: LongWord): LongWord;

implementation

var
  state: LongWord = 1;

procedure RngSeed(seed: LongWord);
begin
  if seed = 0 then seed := $9E3779B9;
  state := seed;
end;

function RngNext: LongWord;
begin
  state := state xor (state shl 13);
  state := state xor (state shr 17);
  state := state xor (state shl 5);
  Result := state;
end;

function RngRange(n: LongWord): LongWord;
begin
  if n = 0 then Exit(0);
  Result := RngNext mod n;
end;

end.
