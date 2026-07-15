unit Kit_Save;
{
  SRAM persistence for cart game state.

  The GBA cart save region at $0E000000 is a byte-wide bus: every
  access in this unit is 8-bit, including the block helpers. 32 KB
  usable ($0000..$7FFF), mirrored above.

  This unit embeds the "SRAM_V113" save-type marker: emulators and
  flashcarts scan the ROM image for it to decide the save hardware to
  map, so any cart that links Kit_Save gets 32 KB SRAM detection for
  free. SramInit references the marker so smart-linking can never drop
  it, and widens the SRAM wait state to 8 cycles for maximum cart-
  hardware tolerance.

  Layout/schema policy lives game-side; this unit provides primitives
  only: byte/block access, verified writes, and an XOR checksum. The
  recommended pattern (primary copy + backup copy + version byte) is
  documented in docs/kit.md.

  KitXorChecksum is pure and host-testable; everything Sram* touches
  the cart bus and is exercised through the demo cart.
}

{$mode objfpc}{$H+}

interface

const
  SRAM_SIZE = 32 * 1024;

{ One-time setup: reference the detection marker, widen SRAM wait
  state. Call once at boot before any other Sram* use. }
procedure SramInit;

function  SramReadByte(off: LongWord): Byte;
procedure SramWriteByte(off: LongWord; v: Byte);

procedure SramReadBlock(off: LongWord; dst: PByte; len: LongWord);
procedure SramWriteBlock(off: LongWord; src: PByte; len: LongWord);

{ Byte-compare an SRAM range against a host buffer. }
function SramVerifyBlock(off: LongWord; src: PByte; len: LongWord): Boolean;

{ Write + read-back verify in one call. }
function SramWriteVerified(off: LongWord; src: PByte; len: LongWord): Boolean;

{ XOR checksum over a host buffer (pure — host-testable). }
function KitXorChecksum(p: PByte; len: LongWord): Byte;

{ XOR checksum over an SRAM range. }
function SramChecksum(off, len: LongWord): Byte;

implementation

const
  SRAM_BASE   = $0E000000;
  REG_WAITCNT = $04000204;

  { Save-type autodetection marker — must survive into the ROM image. }
  SaveTypeMarker: array[0..9] of Char = ('S','R','A','M','_','V','1','1','3',#0);

procedure SramInit;
begin
  { Touch the marker so no link-time pass can discard it. }
  if SaveTypeMarker[0] = #0 then Exit;
  PWord(REG_WAITCNT)^ := PWord(REG_WAITCNT)^ or $0003;
end;

function SramReadByte(off: LongWord): Byte;
begin
  Result := PByte(SRAM_BASE + off)^;
end;

procedure SramWriteByte(off: LongWord; v: Byte);
begin
  PByte(SRAM_BASE + off)^ := v;
end;

procedure SramReadBlock(off: LongWord; dst: PByte; len: LongWord);
var
  i: LongWord;
begin
  if len = 0 then Exit;
  for i := 0 to len - 1 do
  begin
    dst^ := PByte(SRAM_BASE + off + i)^;
    Inc(dst);
  end;
end;

procedure SramWriteBlock(off: LongWord; src: PByte; len: LongWord);
var
  i: LongWord;
begin
  if len = 0 then Exit;
  for i := 0 to len - 1 do
  begin
    PByte(SRAM_BASE + off + i)^ := src^;
    Inc(src);
  end;
end;

function SramVerifyBlock(off: LongWord; src: PByte; len: LongWord): Boolean;
var
  i: LongWord;
begin
  Result := True;
  if len = 0 then Exit;
  for i := 0 to len - 1 do
  begin
    if PByte(SRAM_BASE + off + i)^ <> src^ then Exit(False);
    Inc(src);
  end;
end;

function SramWriteVerified(off: LongWord; src: PByte; len: LongWord): Boolean;
begin
  SramWriteBlock(off, src, len);
  Result := SramVerifyBlock(off, src, len);
end;

function KitXorChecksum(p: PByte; len: LongWord): Byte;
var
  i: LongWord;
begin
  Result := 0;
  if len = 0 then Exit;
  for i := 0 to len - 1 do
  begin
    Result := Result xor p^;
    Inc(p);
  end;
end;

function SramChecksum(off, len: LongWord): Byte;
var
  i: LongWord;
begin
  Result := 0;
  if len = 0 then Exit;
  for i := 0 to len - 1 do
    Result := Result xor PByte(SRAM_BASE + off + i)^;
end;

end.
