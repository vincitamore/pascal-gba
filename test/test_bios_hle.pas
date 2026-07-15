program test_bios_hle;
{
  Unit tests for BIOS HLE — verifies LZ77 and RLE decompression
  against hand-crafted compressed streams with known outputs.

  Approach: construct compressed data in EWRAM, set R0/R1 to point at
  source/dest, invoke the SWI handler directly, then read back the
  destination and assert.
}

{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, Memory, ArmCore, Bios_Hle;

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

procedure CheckEq(const name: string; expected, actual: TWord);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name, '  (= $', IntToHex(actual, 8), ')');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  ', name, '  expected $', IntToHex(expected, 8),
                              ', got $',     IntToHex(actual, 8));
    Inc(FailCount);
  end;
end;

procedure CheckByte(const name: string; expected, actual: TByte);
begin
  if expected = actual then
  begin
    Writeln('  PASS  ', name, '  (= $', IntToHex(actual, 2), ')');
    Inc(PassCount);
  end
  else
  begin
    Writeln('  FAIL  ', name, '  expected $', IntToHex(expected, 2),
                              ', got $',     IntToHex(actual, 2));
    Inc(FailCount);
  end;
end;

{ ───── LZ77 tests ───────────────────────────────────────────────── }

procedure TestLz77AllLiterals;
{ Decompress 4 bytes "ABCD" encoded as all-literal.

  Encoding:
    Header: bits 7:4 = $1 (LZ77 type), bits 31:8 = $4 (size).
            header word = $00000410. Little-endian bytes: $10 $04 $00 $00.
    Flag byte: $00 (all 8 flag-bits are 0 = literal).
    Bytes 1..4: $41 $42 $43 $44 ('A' 'B' 'C' 'D').
    (Flag bits 5..8 unused — we stop when bytesWritten = size.) }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  bios: TGbaBios;
const
  CompressedAt = $02001000;
  DestAt       = $02002000;
  Comp: array[0..8] of TByte = (
    $10, $04, $00, $00,    { header: type=1, size=4 }
    $00,                    { flag byte: all 8 literals }
    $41, $42, $43, $44      { 'A','B','C','D' }
  );
var
  i: Integer;
begin
  Writeln('--- TestLz77AllLiterals ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  bios := TGbaBios.Create(cpu, mem);
  try
    for i := 0 to High(Comp) do mem.WriteByte(CompressedAt + TWord(i), Comp[i]);
    cpu.SetReg(0, CompressedAt);
    cpu.SetReg(1, DestAt);
    bios.Handle($11);

    CheckByte('dest[0] = "A"', $41, mem.ReadByte(DestAt + 0));
    CheckByte('dest[1] = "B"', $42, mem.ReadByte(DestAt + 1));
    CheckByte('dest[2] = "C"', $43, mem.ReadByte(DestAt + 2));
    CheckByte('dest[3] = "D"', $44, mem.ReadByte(DestAt + 3));
  finally
    bios.Free; cpu.Free; mem.Free;
  end;
end;

procedure TestLz77BackReference;
{ Decompress "ABABABAB" (8 bytes) using a back-reference.

  After we write "AB" as literals, we can back-reference for the rest.
  Encoding:
    Header: size=8 → $00000810. Bytes: $10 $08 $00 $00.
    Flag byte: 0b00111111 = $3F (first 2 flag bits = 0 = literal,
                                  next 6 flag bits = 1 = compressed).
      Actually we only need 2 literals + back-references to fill 8 bytes.
      First back-ref n=3+3=6 bytes covers the rest. So:
        flag = 0b00100000 = $20 (bit 7=0 lit, bit 6=0 lit, bit 5=1 back-ref).
    Bytes:
      $41 $42                   (literal 'A', literal 'B')
      $30 $01                   (compressed: n=3+3=6, disp=1)
        byte0 = ($3 << 4) | $0 = $30 → n=3+3=6, disp_hi=0
        byte1 = $01             → disp=1 (back 2 bytes from current write pos)

      Wait: disp = (byte0 & $F) << 8 | byte1 = $01.
      copyAddr = dst + bytesWritten - disp - 1 = dst + 2 - 1 - 1 = dst + 0.
      So we copy 6 bytes starting from dst+0. With overlap: bytes at dst+0..dst+5.
      dst+0='A', dst+1='B', dst+2='A' (copy of dst+0), dst+3='B' (copy of dst+1),
      dst+4='A' (copy of dst+2 which is now 'A'), etc. → "ABABAB"
      Total output: "AB" + "ABABAB" = "ABABABAB". ✓ }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  bios: TGbaBios;
const
  CompressedAt = $02001000;
  DestAt       = $02002000;
  Comp: array[0..8] of TByte = (
    $10, $08, $00, $00,    { header: size=8 }
    $20,                    { flag: lit, lit, ref, ... }
    $41, $42,               { 'A','B' }
    $30, $01                { back-ref n=6, disp=1 }
  );
var
  i: Integer;
begin
  Writeln('--- TestLz77BackReference ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  bios := TGbaBios.Create(cpu, mem);
  try
    for i := 0 to High(Comp) do mem.WriteByte(CompressedAt + TWord(i), Comp[i]);
    cpu.SetReg(0, CompressedAt);
    cpu.SetReg(1, DestAt);
    bios.Handle($11);

    CheckByte('dest[0] = "A"', $41, mem.ReadByte(DestAt + 0));
    CheckByte('dest[1] = "B"', $42, mem.ReadByte(DestAt + 1));
    CheckByte('dest[2] = "A"', $41, mem.ReadByte(DestAt + 2));
    CheckByte('dest[3] = "B"', $42, mem.ReadByte(DestAt + 3));
    CheckByte('dest[4] = "A"', $41, mem.ReadByte(DestAt + 4));
    CheckByte('dest[5] = "B"', $42, mem.ReadByte(DestAt + 5));
    CheckByte('dest[6] = "A"', $41, mem.ReadByte(DestAt + 6));
    CheckByte('dest[7] = "B"', $42, mem.ReadByte(DestAt + 7));
  finally
    bios.Free; cpu.Free; mem.Free;
  end;
end;

procedure TestLz77Write16Bit;
{ Same data as TestLz77BackReference but using SWI #12 (Write16bit)
  to VRAM-style destination. Verifies the byte-pair → halfword
  accumulator logic. }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  bios: TGbaBios;
const
  CompressedAt = $02001000;
  DestAt       = $06000000;   { VRAM }
  Comp: array[0..8] of TByte = (
    $10, $08, $00, $00,
    $20,
    $41, $42,
    $30, $01
  );
var
  i: Integer;
begin
  Writeln('--- TestLz77Write16Bit ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  bios := TGbaBios.Create(cpu, mem);
  try
    for i := 0 to High(Comp) do mem.WriteByte(CompressedAt + TWord(i), Comp[i]);
    cpu.SetReg(0, CompressedAt);
    cpu.SetReg(1, DestAt);
    bios.Handle($12);

    { Reading bytes via ReadByte from VRAM region — should match. }
    CheckByte('dest[0] = "A"', $41, mem.ReadByte(DestAt + 0));
    CheckByte('dest[1] = "B"', $42, mem.ReadByte(DestAt + 1));
    CheckByte('dest[2] = "A"', $41, mem.ReadByte(DestAt + 2));
    CheckByte('dest[3] = "B"', $42, mem.ReadByte(DestAt + 3));
    CheckByte('dest[4] = "A"', $41, mem.ReadByte(DestAt + 4));
    CheckByte('dest[5] = "B"', $42, mem.ReadByte(DestAt + 5));
    CheckByte('dest[6] = "A"', $41, mem.ReadByte(DestAt + 6));
    CheckByte('dest[7] = "B"', $42, mem.ReadByte(DestAt + 7));
  finally
    bios.Free; cpu.Free; mem.Free;
  end;
end;

{ ───── RLE tests ────────────────────────────────────────────────── }

procedure TestRleLiteral;
{ Decompress 4 literal bytes via RLE.

  Encoding:
    Header: bits 7:4 = $3 (RLE), bits 31:8 = $4 (size).
            header = $00000430. Bytes: $30 $04 $00 $00.
    Flag byte: bit 7 = 0 = literal, bits 6:0 = length-1 = 3 → length=4
               flag = $03
    Bytes: $41 $42 $43 $44 }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  bios: TGbaBios;
const
  CompressedAt = $02001000;
  DestAt       = $02002000;
  Comp: array[0..8] of TByte = (
    $30, $04, $00, $00,
    $03,
    $41, $42, $43, $44
  );
var
  i: Integer;
begin
  Writeln('--- TestRleLiteral ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  bios := TGbaBios.Create(cpu, mem);
  try
    for i := 0 to High(Comp) do mem.WriteByte(CompressedAt + TWord(i), Comp[i]);
    cpu.SetReg(0, CompressedAt);
    cpu.SetReg(1, DestAt);
    bios.Handle($14);

    CheckByte('dest[0] = "A"', $41, mem.ReadByte(DestAt + 0));
    CheckByte('dest[1] = "B"', $42, mem.ReadByte(DestAt + 1));
    CheckByte('dest[2] = "C"', $43, mem.ReadByte(DestAt + 2));
    CheckByte('dest[3] = "D"', $44, mem.ReadByte(DestAt + 3));
  finally
    bios.Free; cpu.Free; mem.Free;
  end;
end;

procedure TestRleRun;
{ Decompress a run of 5 identical bytes.
    flag byte: bit 7 = 1, bits 6:0 = length-3 = 2 → length=5
               flag = $82
    Then 1 run byte: $55. Output: $55 $55 $55 $55 $55. }
var
  mem: TGbaMemory;
  cpu: TArmCore;
  bios: TGbaBios;
const
  CompressedAt = $02001000;
  DestAt       = $02002000;
  Comp: array[0..5] of TByte = (
    $30, $05, $00, $00,
    $82,
    $55
  );
var
  i: Integer;
begin
  Writeln('--- TestRleRun ---');
  mem := TGbaMemory.Create;
  cpu := TArmCore.Create;
  bios := TGbaBios.Create(cpu, mem);
  try
    for i := 0 to High(Comp) do mem.WriteByte(CompressedAt + TWord(i), Comp[i]);
    cpu.SetReg(0, CompressedAt);
    cpu.SetReg(1, DestAt);
    bios.Handle($14);

    CheckByte('dest[0]', $55, mem.ReadByte(DestAt + 0));
    CheckByte('dest[1]', $55, mem.ReadByte(DestAt + 1));
    CheckByte('dest[2]', $55, mem.ReadByte(DestAt + 2));
    CheckByte('dest[3]', $55, mem.ReadByte(DestAt + 3));
    CheckByte('dest[4]', $55, mem.ReadByte(DestAt + 4));
    { dest[5] should still be 0 (memory init) }
    CheckByte('dest[5] untouched', $00, mem.ReadByte(DestAt + 5));
  finally
    bios.Free; cpu.Free; mem.Free;
  end;
end;

begin
  Writeln('BIOS HLE acceptance tests');
  Writeln('==========================================');
  Writeln('');
  TestLz77AllLiterals;       Writeln('');
  TestLz77BackReference;     Writeln('');
  TestLz77Write16Bit;        Writeln('');
  TestRleLiteral;            Writeln('');
  TestRleRun;                Writeln('');
  Writeln('==========================================');
  Writeln(Format('Result: %d pass, %d fail', [PassCount, FailCount]));
  if FailCount > 0 then Halt(1);
end.
