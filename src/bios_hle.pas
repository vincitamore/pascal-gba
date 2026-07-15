unit Bios_Hle;
{
  Minimal GBA BIOS High-Level Emulation.

  Real GBA games invoke BIOS routines via SWI (Software Interrupt).
  Each SWI gets dispatched by the BIOS to a specific routine —
  CpuSet, CpuFastSet, Div, Sqrt, LZ77UnComp, etc. Without a real BIOS
  image, the routines never run and games that depend on them
  (essentially all commercial games) fail in observable ways.

  HLE catches the SWI in Pascal and performs the requested operation
  directly, manipulating CPU registers and memory through the CPU's
  public surface and a TGbaMemory reference. Faster than emulating
  the BIOS in interpreted ARM, and avoids requiring a real BIOS image.

  ── Coverage (Handle dispatcher) ──

    $00  SoftReset             stub: return (approx cart re-entry)
    $01  RegisterRamReset      stub: no-op (power-on RAM clear)
    $02  Halt                  stub: no-op (no power management)
    $03  Stop                  stub: no-op
    $04  IntrWait              stub: no-op
    $05  VBlankIntrWait        stub: no-op (V-blank IRQ still fires)
    $06  Div                   real: R0 = R0/R1, R1 = R0%R1, R3 = |R0/R1|
    $0B  CpuSet                real: memory copy/fill, 16 or 32-bit
    $0C  CpuFastSet            real: fast 32-bit copy/fill in 8-word chunks
    $11  LZ77UnCompWram        real: LZ77 decompress, 8-bit writes
    $12  LZ77UnCompVram        real: LZ77 decompress, 16-bit writes
    $14  RLUnCompWram          real: RLE decompress, 8-bit writes
    $15  RLUnCompVram          real: RLE decompress, 16-bit writes

  Other SWIs return False from Handle() — the CPU will fall through to
  the normal $08 exception entry, which (with our stub at $08) returns
  immediately. Most missing SWIs are tolerable as no-ops for boot.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes, Memory, ArmCore;

type
  TGbaBios = class
  private
    FMem: TGbaMemory;
    FCpu: TArmCore;

    function DoCpuSet: Boolean;
    function DoCpuFastSet: Boolean;
    function DoDiv: Boolean;
    function DoLz77UnComp(writeAs16bit: Boolean): Boolean;
    function DoRLUnComp(writeAs16bit: Boolean): Boolean;

  public
    { Telemetry — count of each SWI number seen, for diagnostics. }
    SwiCount: array[0..255] of Int64;

    constructor Create(cpu: TArmCore; mem: TGbaMemory);

    { SWI dispatcher — called by ArmCore via SetSwiHook. Returns True if
      handled, False if the SWI should fall through to the $08 vector. }
    function Handle(swiNum: TByte): Boolean;
  end;

implementation

constructor TGbaBios.Create(cpu: TArmCore; mem: TGbaMemory);
begin
  inherited Create;
  FCpu := cpu;
  FMem := mem;
  FillChar(SwiCount, SizeOf(SwiCount), 0);
end;

function TGbaBios.DoCpuSet: Boolean;
{ SWI $0B — CpuSet. Memory copy / fill.

    R0 = source address
    R1 = destination address
    R2 = control:
      bits 20:0 = count (in units of the access size)
      bit 24    = fill mode (0 = copy, 1 = fill — repeat *R0)
      bit 26    = data size (0 = 16-bit, 1 = 32-bit)

  Copies in either direction. We use the CPU's public Read*/Write*
  through memory hooks (not the CPU's hooks — we have direct mem access). }
var
  src, dst, ctl: TWord;
  count: TWord;
  fillMode, word32: Boolean;
  v32: TWord;
  v16: THalf;
  i: TWord;
begin
  src := FCpu.GetReg(0);
  dst := FCpu.GetReg(1);
  ctl := FCpu.GetReg(2);
  count := ctl and $001FFFFF;
  fillMode := (ctl and $01000000) <> 0;
  word32 := (ctl and $04000000) <> 0;

  if word32 then
  begin
    if fillMode then
    begin
      v32 := FMem.ReadWord(src);
      for i := 0 to count - 1 do
        FMem.WriteWord(dst + i * 4, v32);
    end
    else
    begin
      for i := 0 to count - 1 do
        FMem.WriteWord(dst + i * 4, FMem.ReadWord(src + i * 4));
    end;
  end
  else
  begin
    if fillMode then
    begin
      v16 := FMem.ReadHalf(src);
      for i := 0 to count - 1 do
        FMem.WriteHalf(dst + i * 2, v16);
    end
    else
    begin
      for i := 0 to count - 1 do
        FMem.WriteHalf(dst + i * 2, FMem.ReadHalf(src + i * 2));
    end;
  end;

  Result := True;
end;

function TGbaBios.DoCpuFastSet: Boolean;
{ SWI $0C — CpuFastSet. Always 32-bit, transfers in chunks of 8 words.
  Count is forced to round UP to a multiple of 8.

    R0 = source ; R1 = dest ; R2 = control:
      bits 20:0 = count in 32-bit words
      bit 24    = fill mode }
var
  src, dst, ctl: TWord;
  count: TWord;
  fillMode: Boolean;
  v: TWord;
  i: TWord;
begin
  src := FCpu.GetReg(0);
  dst := FCpu.GetReg(1);
  ctl := FCpu.GetReg(2);
  count := ctl and $001FFFFF;
  fillMode := (ctl and $01000000) <> 0;

  { Round count up to multiple of 8. }
  if (count and 7) <> 0 then count := (count + 7) and not TWord(7);

  if fillMode then
  begin
    v := FMem.ReadWord(src);
    for i := 0 to count - 1 do
      FMem.WriteWord(dst + i * 4, v);
  end
  else
  begin
    for i := 0 to count - 1 do
      FMem.WriteWord(dst + i * 4, FMem.ReadWord(src + i * 4));
  end;

  Result := True;
end;

function TGbaBios.DoDiv: Boolean;
{ SWI $06 — Div. Signed integer divide.
    R0 = numerator (signed 32-bit)
    R1 = denominator (signed 32-bit)
  Returns:
    R0 = quotient  (numerator / denominator)
    R1 = remainder (numerator mod denominator)
    R3 = absolute value of quotient }
var
  num, denom: Int32;
  q, r: Int32;
  absq: TWord;
begin
  num := Int32(FCpu.GetReg(0));
  denom := Int32(FCpu.GetReg(1));
  if denom = 0 then
  begin
    { Real BIOS hangs on div-by-zero. We return all-ones to be observably
      wrong without crashing. }
    FCpu.SetReg(0, $FFFFFFFF);
    FCpu.SetReg(1, $FFFFFFFF);
    FCpu.SetReg(3, $FFFFFFFF);
    Exit(True);
  end;
  q := num div denom;
  r := num mod denom;
  if q < 0 then absq := TWord(-q) else absq := TWord(q);
  FCpu.SetReg(0, TWord(q));
  FCpu.SetReg(1, TWord(r));
  FCpu.SetReg(3, absq);
  Result := True;
end;

function TGbaBios.DoLz77UnComp(writeAs16bit: Boolean): Boolean;
{ SWI $11 (Write8bit, for normal RAM) and SWI $12 (Write16bit, for VRAM).

  Source format (per GBATEK):
    32-bit header: bits 3:0 = reserved ($0), bits 7:4 = type ($1 = LZ77),
                   bits 31:8 = decompressed size (in bytes)
    Repeats:
      Flag byte: 8 type-flag bits, MSB first, telling whether each of
        the next 8 blocks is uncompressed (0) or compressed (1).
      Per block:
        Type 0 (uncompressed): 1 byte copied verbatim
        Type 1 (compressed): 2 bytes encoding:
          byte0[7:4] = N - 3  (run length, 3..18)
          byte0[3:0] = Disp[11:8]
          byte1[7:0] = Disp[7:0]
          Copy N+3 bytes starting from (dest - Disp - 1). Bytes can
          OVERLAP the current write position (creating repeats).

  For Write16bit (SWI $12), the output buffer is read/written via 16-bit
  halfword accesses — we accumulate two bytes and emit a halfword when
  the destination crosses an even-byte boundary. This is needed for VRAM
  (no byte writes). We implement Write8bit and approximate Write16bit
  by collecting bytes in an internal buffer and flushing halfwords. }
var
  src, dst: TWord;
  header: TWord;
  decompressedSize: TWord;
  bytesWritten: TWord;
  flagByte: TByte;
  flagBit: Integer;
  byte0, byte1, b: TByte;
  n, disp, copyAddr: TWord;
  k: Integer;
  pendingHalf: THalf;
  pendingByteCount: Integer;
begin
  src := FCpu.GetReg(0);
  dst := FCpu.GetReg(1);
  header := FMem.ReadWord(src);
  decompressedSize := header shr 8;
  Inc(src, 4);
  bytesWritten := 0;
  pendingHalf := 0;
  pendingByteCount := 0;

  while bytesWritten < decompressedSize do
  begin
    flagByte := FMem.ReadByte(src);
    Inc(src);
    for flagBit := 7 downto 0 do
    begin
      if bytesWritten >= decompressedSize then Break;
      if (flagByte and (1 shl flagBit)) <> 0 then
      begin
        { Compressed block. }
        byte0 := FMem.ReadByte(src);
        byte1 := FMem.ReadByte(src + 1);
        Inc(src, 2);
        n := ((byte0 shr 4) and $F) + 3;
        disp := (TWord(byte0 and $F) shl 8) or TWord(byte1);
        copyAddr := dst + bytesWritten - disp - 1;
        for k := 0 to Integer(n) - 1 do
        begin
          b := FMem.ReadByte(copyAddr + TWord(k));
          if writeAs16bit then
          begin
            { Buffer one byte; emit halfword on second. }
            if (pendingByteCount and 1) = 0 then
              pendingHalf := THalf(b)
            else
            begin
              pendingHalf := pendingHalf or (THalf(b) shl 8);
              FMem.WriteHalf(dst + (bytesWritten and not TWord(1)), pendingHalf);
            end;
            Inc(pendingByteCount);
          end
          else
            FMem.WriteByte(dst + bytesWritten, b);
          Inc(bytesWritten);
          if bytesWritten >= decompressedSize then Break;
        end;
      end
      else
      begin
        { Uncompressed: one literal byte. }
        b := FMem.ReadByte(src);
        Inc(src);
        if writeAs16bit then
        begin
          if (pendingByteCount and 1) = 0 then
            pendingHalf := THalf(b)
          else
          begin
            pendingHalf := pendingHalf or (THalf(b) shl 8);
            FMem.WriteHalf(dst + (bytesWritten and not TWord(1)), pendingHalf);
          end;
          Inc(pendingByteCount);
        end
        else
          FMem.WriteByte(dst + bytesWritten, b);
        Inc(bytesWritten);
      end;
    end;
  end;

  { Flush trailing odd byte if any. }
  if writeAs16bit and ((pendingByteCount and 1) = 1) then
    FMem.WriteHalf(dst + (bytesWritten and not TWord(1)), pendingHalf);

  Result := True;
end;

function TGbaBios.DoRLUnComp(writeAs16bit: Boolean): Boolean;
{ SWI $14/$15 — RLE decompression.

  Source format:
    32-bit header: bits 3:0 reserved, bits 7:4 = type ($3 = RLE),
                   bits 31:8 = decompressed size.
    Repeats:
      Flag byte: bit 7 = run flag, bits 6:0 = length-1 (run) or length-1 (literal)
        if run flag = 1: run of length+3 bytes (length = bits 6:0)
        if run flag = 0: literal copy of length+1 bytes

  Write8bit / Write16bit variant follows the same byte→halfword
  accumulator pattern as LZ77. }
var
  src, dst: TWord;
  header: TWord;
  decompressedSize: TWord;
  bytesWritten: TWord;
  flagByte: TByte;
  runLen: Integer;
  isRun: Boolean;
  runByte: TByte;
  pendingHalf: THalf;
  pendingByteCount: Integer;
  k: Integer;

  procedure EmitByte(b: TByte);
  begin
    if writeAs16bit then
    begin
      if (pendingByteCount and 1) = 0 then
        pendingHalf := THalf(b)
      else
      begin
        pendingHalf := pendingHalf or (THalf(b) shl 8);
        FMem.WriteHalf(dst + (bytesWritten and not TWord(1)), pendingHalf);
      end;
      Inc(pendingByteCount);
    end
    else
      FMem.WriteByte(dst + bytesWritten, b);
    Inc(bytesWritten);
  end;

begin
  src := FCpu.GetReg(0);
  dst := FCpu.GetReg(1);
  header := FMem.ReadWord(src);
  decompressedSize := header shr 8;
  Inc(src, 4);
  bytesWritten := 0;
  pendingHalf := 0;
  pendingByteCount := 0;

  while bytesWritten < decompressedSize do
  begin
    flagByte := FMem.ReadByte(src);
    Inc(src);
    isRun := (flagByte and $80) <> 0;
    if isRun then
      runLen := (flagByte and $7F) + 3
    else
      runLen := (flagByte and $7F) + 1;

    if isRun then
    begin
      runByte := FMem.ReadByte(src);
      Inc(src);
      for k := 0 to runLen - 1 do
      begin
        if bytesWritten >= decompressedSize then Break;
        EmitByte(runByte);
      end;
    end
    else
    begin
      for k := 0 to runLen - 1 do
      begin
        if bytesWritten >= decompressedSize then Break;
        EmitByte(FMem.ReadByte(src));
        Inc(src);
      end;
    end;
  end;

  if writeAs16bit and ((pendingByteCount and 1) = 1) then
    FMem.WriteHalf(dst + (bytesWritten and not TWord(1)), pendingHalf);

  Result := True;
end;

function TGbaBios.Handle(swiNum: TByte): Boolean;
begin
  Inc(SwiCount[swiNum]);
  case swiNum of
    $00:  { SoftReset — reset to cart entry. Approximate: just return.
            Real impl would clear IWRAM and reset stacks. }
      Result := True;
    $01:  { RegisterRamReset — clear various RAM regions per R0 mask.
            For boot, treating as no-op is usually fine. }
      Result := True;
    $02:  { Halt — wait for any IRQ. We don't model power; just no-op.
            On real hardware this resumes after any IRQ; our caller will
            see "we resumed" and proceed. }
      Result := True;
    $03:  { Stop — deeper sleep. Same treatment. }
      Result := True;
    $04:  { IntrWait — wait for specified IRQ. No-op suffices for boot. }
      Result := True;
    $05:  { VBlankIntrWait — wait for V-blank. Game expects to resume when
            V-blank IRQ fires. No-op: the game's IRQ handler will fire
            independently via our V-blank IRQ. }
      Result := True;
    $06:  Result := DoDiv;
    $0B:  Result := DoCpuSet;
    $0C:  Result := DoCpuFastSet;
    $11:  Result := DoLz77UnComp(False);   { Write8bit — for normal RAM }
    $12:  Result := DoLz77UnComp(True);    { Write16bit — for VRAM }
    $14:  Result := DoRLUnComp(False);
    $15:  Result := DoRLUnComp(True);
  else
    Result := False;   { Unknown SWI — fall through to $08 vector }
  end;
end;

end.
