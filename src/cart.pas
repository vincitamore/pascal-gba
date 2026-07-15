unit Cart;
{
  GBA cartridge metadata — header parser + save-type autodetect.

  ── Cart header (per GBATEK) ──

  Lives at $08000000..$080000BF (192 bytes). Important fields:

    offs $00..03  Entry-point branch (ARM `B start`)
    offs $04..9F  156-byte Nintendo logo bitmap (fixed pattern; BIOS checks
                  this against a hardcoded copy at boot — pass/fail gates
                  the "GAME BOY" splash and the actual game launch. We don't
                  enforce it; mGBA's BIOS replacement is permissive too.)
    offs $A0..AB  12-byte ASCII game title (NUL-padded)
    offs $AC..AF  4-byte ASCII game code (e.g. "AWRE" for a commercial title)
    offs $B0..B1  2-byte ASCII maker code ("01" = Nintendo)
    offs $B2      Fixed: $96
    offs $B3      Main unit code ($00 = GBA)
    offs $B4      Device type
    offs $B5..BB  Reserved (zeros)
    offs $BC      Software version
    offs $BD      Header checksum complement
    offs $BE..BF  Reserved
    offs $C0..C3  Multiboot entry point
    offs $C4      Boot mode
    offs $C5      Slave ID
    offs $C6..DF  Reserved / multiboot

  ── Save-type autodetect ──

  GBA carts contain library code that includes one of these ASCII strings
  somewhere in the ROM image (often near the entry point or in a save-
  routine literal pool):

    "EEPROM_V"     → EEPROM (512 B or 8 KB; size determined by access pattern)
    "SRAM_V"       → SRAM (32 KB)
    "FLASH_V"      → Flash 64 KB (Atmel — single chip)
    "FLASH512_V"   → Flash 64 KB (older naming)
    "FLASH1M_V"    → Flash 128 KB (Macronix/Sanyo — two banks)

  Scan the entire ROM for these. First match wins. If none found, default
  to SRAM (most permissive — won't break a no-save game).
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TSaveType = (
    stUnknown,
    stSRAM,        { 32 KB direct-mapped }
    stEEPROM,      { 512 B or 8 KB (size on first access) }
    stFlash64,     { 64 KB single chip }
    stFlash128     { 128 KB two-bank }
  );

  TCartInfo = record
    Title:     string[12];   { ASCII, NUL-stripped }
    GameCode:  string[4];
    MakerCode: string[2];
    SaveType:  TSaveType;
    Valid:     Boolean;      { header offset $B2 = $96 (fixed-byte sanity) }
  end;

{ Parse a ROM-image buffer (must be at least 192 bytes for header).
  Scans for the save-type string in the whole buffer. }
function ParseCartHeader(const rom: array of Byte; romLen: Integer): TCartInfo;

function SaveTypeName(s: TSaveType): string;

implementation

function SaveTypeName(s: TSaveType): string;
begin
  case s of
    stUnknown:  Result := 'unknown (defaulted to SRAM)';
    stSRAM:     Result := 'SRAM (32 KB)';
    stEEPROM:   Result := 'EEPROM (autodetect size on first access)';
    stFlash64:  Result := 'Flash 64 KB';
    stFlash128: Result := 'Flash 128 KB';
  else
    Result := '???';
  end;
end;

function ExtractAscii(const rom: array of Byte; offs, len: Integer): string;
var
  i: Integer;
  c: Byte;
begin
  Result := '';
  for i := 0 to len - 1 do
  begin
    if offs + i >= Length(rom) then Break;
    c := rom[offs + i];
    if c = 0 then Break;
    if (c >= 32) and (c < 127) then Result := Result + Chr(c);
  end;
end;

function ContainsSubstring(const rom: array of Byte; romLen: Integer;
                            const needle: string): Boolean;
var
  i, j: Integer;
  match: Boolean;
  nLen: Integer;
begin
  Result := False;
  nLen := Length(needle);
  if (nLen = 0) or (romLen < nLen) then Exit;
  for i := 0 to romLen - nLen do
  begin
    match := True;
    for j := 1 to nLen do
      if rom[i + j - 1] <> Byte(needle[j]) then
      begin
        match := False;
        Break;
      end;
    if match then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function DetectSaveType(const rom: array of Byte; romLen: Integer): TSaveType;
begin
  { Check Flash variants first because "FLASH_V" is a substring of
    "FLASH512_V" and "FLASH1M_V" — match the more specific first.
    EEPROM and SRAM strings don't overlap. }
  if ContainsSubstring(rom, romLen, 'FLASH1M_V')  then Exit(stFlash128);
  if ContainsSubstring(rom, romLen, 'FLASH512_V') then Exit(stFlash64);
  if ContainsSubstring(rom, romLen, 'FLASH_V')    then Exit(stFlash64);
  if ContainsSubstring(rom, romLen, 'EEPROM_V')   then Exit(stEEPROM);
  if ContainsSubstring(rom, romLen, 'SRAM_V')     then Exit(stSRAM);
  Result := stUnknown;
end;

function ParseCartHeader(const rom: array of Byte; romLen: Integer): TCartInfo;
begin
  FillChar(Result, SizeOf(Result), 0);
  if romLen < $C0 then
  begin
    Result.Valid := False;
    Exit;
  end;

  Result.Title     := ExtractAscii(rom, $A0, 12);
  Result.GameCode  := ExtractAscii(rom, $AC, 4);
  Result.MakerCode := ExtractAscii(rom, $B0, 2);
  Result.Valid     := rom[$B2] = $96;
  Result.SaveType  := DetectSaveType(rom, romLen);
end;

end.
