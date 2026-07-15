unit Save;
{
  GBA cartridge save backends — SRAM, Flash 64 KB / 128 KB, EEPROM.

  ── Detection ──

  Save type is autodetected by `cart.pas` via substring scan of the ROM
  image. This unit consumes a TSaveType + a base file path and installs
  the appropriate memory hooks for the cart save region ($0E000000+).

  ── Region map ──

    $0E000000-$0E00FFFF   Flash 64 KB / Flash 128 KB (bank 0) / SRAM
    $0E010000-$0E01FFFF   Flash 128 KB (bank 1) — visible in bank-1 mode
    $0EFFFFFF-$0E000000   mirrored every $10000

  ── SRAM ──

  32 KB persistent storage at $0E000000-$0E007FFF (mirrored). Reads and
  writes pass through unchanged; the save buffer IS the SRAM contents.
  No command protocol. Persist on flush.

  ── Flash 64 KB (Atmel AT29LV512 / single-chip) ──

  Reads return the current data byte (or a chip-ID byte in chip-ID
  mode). Writes go through a command-sequence state machine, NOT
  directly to the buffer.

  Command sequence prefix (all sequences start with this):
    1. write $AA at $0E005555
    2. write $55 at $0E002AAA

  Then a command byte at $0E005555:
    $90 → enter chip-ID mode. Reads at $0E000000 = manufacturer ID
          ($1F = Atmel), $0E000001 = device ID ($3D = AT29LV512).
    $F0 → exit chip-ID mode.
    $80 → erase prefix; expect another full prefix + command:
          - $10 at $0E005555 → chip-erase (whole 64 KB → $FF)
          - $30 at sector-base → sector-erase (one 4 KB sector → $FF)
    $A0 → program-byte mode; the NEXT write to any address in
          $0E000000-$0E00FFFF stores that byte (AND'd with existing —
          Flash can only flip 1→0; sector erase is the only path to
          0→1).
    $B0 → bank-switch (128 KB chips only); next write to $0E000000
          sets the bank index (0 or 1).

  After each command, the state machine returns to Idle.

  ── Flash 128 KB (Macronix MX29L010 / two-bank) ──

  Same protocol as Flash 64 except:
    - Manufacturer ID = $C2 (Macronix), device ID = $09 (or $4E)
    - 16 KB of address space ($0E000000-$0E00FFFF) shows ONE 64 KB
      bank at a time; bank switching via $B0 command swaps which 64 KB
      is mapped.

  Total store: 128 KB (2 × 64 KB). Both banks persist to disk.

  ── EEPROM ──

  Deferred. EEPROM is accessed via DMA3 with a serial bit-shift
  protocol — the CPU sends commands one bit per DMA3 cycle. Significant
  scaffolding required; neither of the commercial Flash-64 titles in
  the test fleet uses it. Add when a commercial EEPROM-using cart
  joins the fleet.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes, Memory, Cart;

const
  SAVE_SIZE_SRAM    = 32 * 1024;        { 32 KB }
  SAVE_SIZE_FLASH64 = 64 * 1024;        { 64 KB }
  SAVE_SIZE_FLASH128 = 128 * 1024;      { 128 KB — 2 banks }

  { Atmel AT29LV512 (Flash 64 KB) chip-ID. }
  FLASH64_MFG_ID  = $1F;
  FLASH64_DEV_ID  = $3D;

  { Macronix MX29L010 (Flash 128 KB) chip-ID. }
  FLASH128_MFG_ID = $C2;
  FLASH128_DEV_ID = $09;

type
  TFlashState = (
    fsIdle,             { default — no command in progress }
    fsSeenAA,           { received $AA at $5555 }
    fsSeenAA55,         { received $AA at $5555 then $55 at $2AAA }
    fsEraseAA,          { $80 issued; expect $AA at $5555 to begin erase }
    fsEraseAA55,        { erase prefix received; expect $55 at $2AAA }
    fsErase,            { erase prefix complete; expect $30 at sector or $10 at $5555 }
    fsProgramByte,      { $A0 issued; next write stores its byte }
    fsBankSwitch,       { $B0 issued; next write to $0E000000 sets bank }
    fsChipIdRead        { in chip-ID read mode (separate from command sequence) }
  );

  TGbaSave = class
  private
    FMem:      TGbaMemory;
    FType:     TSaveType;
    FPath:     string;
    FBuf:      array of TByte;        { dynamic — 32K/64K/128K }
    FBufSize:  Integer;

    { Flash state machine. }
    FFlashState:    TFlashState;
    FFlashChipId:   Boolean;          { distinct latch — chip-ID mode persists across
                                        command boundaries until $F0 exits }
    FFlashBank:     Integer;          { 0 or 1; only used by Flash 128 }
    FFlashMfgId:    TByte;
    FFlashDevId:    TByte;

    FDirty:     Boolean;              { writes occurred since last flush }

    function  IsFlash: Boolean; inline;
    function  BufOffsetForFlash(addr: TWord): Integer; inline;
    procedure FlashCommandStep(addr: TWord; v: TByte);

  public
    constructor Create(mem: TGbaMemory; info: TCartInfo; const basePath: string);
    destructor  Destroy; override;

    { Memory hooks — install via mem.SetSaveReadHook + SetSaveWriteHook.
      Called for any access to addresses in the $0E000000+ region. The
      address is the raw guest address; mirroring/banking handled here. }
    function  ReadByte(addr: TWord): TByte;
    procedure WriteByte(addr: TWord; v: TByte);

    { Read .sav file from disk into the save buffer. Best-effort: a
      missing file leaves the buffer at its default (zero for SRAM,
      $FF for Flash — Flash erased state). }
    procedure LoadFromDisk;

    { Write the save buffer to disk. Idempotent if not dirty. Called
      explicitly by the harness at intervals or on shutdown. }
    procedure Flush;

    property SaveType: TSaveType    read FType;
    property Path:     string       read FPath;
    property Size:     Integer      read FBufSize;
    property Dirty:    Boolean      read FDirty;
  end;

implementation

constructor TGbaSave.Create(mem: TGbaMemory; info: TCartInfo; const basePath: string);
var
  i: Integer;
begin
  inherited Create;
  FMem  := mem;
  FType := info.SaveType;
  FPath := basePath;

  case FType of
    stSRAM:     FBufSize := SAVE_SIZE_SRAM;
    stFlash64:  FBufSize := SAVE_SIZE_FLASH64;
    stFlash128: FBufSize := SAVE_SIZE_FLASH128;
    stEEPROM,
    stUnknown:  FBufSize := SAVE_SIZE_SRAM;     { fallback: 32 KB SRAM-style }
  else
    FBufSize := SAVE_SIZE_SRAM;
  end;

  SetLength(FBuf, FBufSize);

  { Flash erased state is $FF (all 1s). SRAM is zeroed. }
  if IsFlash then
    for i := 0 to FBufSize - 1 do FBuf[i] := $FF
  else
    FillChar(FBuf[0], FBufSize, 0);

  FFlashState  := fsIdle;
  FFlashChipId := False;
  FFlashBank   := 0;

  case FType of
    stFlash64:  begin FFlashMfgId := FLASH64_MFG_ID;  FFlashDevId := FLASH64_DEV_ID; end;
    stFlash128: begin FFlashMfgId := FLASH128_MFG_ID; FFlashDevId := FLASH128_DEV_ID; end;
  else
    FFlashMfgId := 0;  FFlashDevId := 0;
  end;

  FDirty := False;
end;

destructor TGbaSave.Destroy;
begin
  Flush;
  SetLength(FBuf, 0);
  inherited Destroy;
end;

function TGbaSave.IsFlash: Boolean;
begin
  Result := (FType = stFlash64) or (FType = stFlash128);
end;

function TGbaSave.BufOffsetForFlash(addr: TWord): Integer;
{ Map a guest address in $0E000000-$0EFFFFFF to a buffer offset. Flash
  64 KB: low 16 bits of address index the 64 KB buffer directly. Flash
  128 KB: bank * 64 KB + (addr and $FFFF). }
begin
  Result := addr and $FFFF;
  if FType = stFlash128 then
    Result := Result + (FFlashBank * SAVE_SIZE_FLASH64);
  if Result >= FBufSize then Result := Result and (FBufSize - 1);
end;

function TGbaSave.ReadByte(addr: TWord): TByte;
begin
  case FType of
    stSRAM:
      Result := FBuf[addr and (SAVE_SIZE_SRAM - 1)];

    stFlash64, stFlash128:
      begin
        if FFlashChipId then
        begin
          { Chip-ID mode: $0E000000 returns manufacturer ID, $0E000001
            returns device ID. Other addresses also return ID bytes on
            real hardware (cycling) but $0/$1 is the canonical case. }
          case addr and $FFFF of
            $0000: Result := FFlashMfgId;
            $0001: Result := FFlashDevId;
          else
            Result := FBuf[BufOffsetForFlash(addr)];
          end;
        end
        else
          Result := FBuf[BufOffsetForFlash(addr)];
      end;

    stEEPROM:
      { EEPROM access is via DMA3 serial protocol, not byte reads. A
        plain byte read of the EEPROM region returns $1 ("ready") on
        most carts. Stub. }
      Result := $01;

  else
    Result := FBuf[addr and (FBufSize - 1)];
  end;
end;

procedure TGbaSave.WriteByte(addr: TWord; v: TByte);
begin
  case FType of
    stSRAM:
      begin
        FBuf[addr and (SAVE_SIZE_SRAM - 1)] := v;
        FDirty := True;
      end;

    stFlash64, stFlash128:
      FlashCommandStep(addr, v);

    stEEPROM:
      { EEPROM writes are DMA3-only on real hardware. Direct byte
        writes are no-ops on most carts. }
      ;
  else
    begin
      FBuf[addr and (FBufSize - 1)] := v;
      FDirty := True;
    end;
  end;
end;

procedure TGbaSave.FlashCommandStep(addr: TWord; v: TByte);
{ Flash command-sequence state machine. The full canonical sequence:

    write $AA at $0E005555
    write $55 at $0E002AAA
    write CMD at $0E005555

  CMD = $90 (chip-ID), $F0 (exit), $80 (erase prefix), $A0 (program),
        $B0 (bank, 128K only).

  After a command, additional bytes may follow depending on the
  command (e.g., erase needs another full prefix + $30 at sector addr;
  program writes one byte to any address).

  Any sequence mismatch resets the state machine to Idle. }
var
  lowAddr: TWord;
  offs:    Integer;
begin
  lowAddr := addr and $FFFF;

  case FFlashState of
    fsIdle:
      if (lowAddr = $5555) and (v = $AA) then
        FFlashState := fsSeenAA;

    fsSeenAA:
      if (lowAddr = $2AAA) and (v = $55) then
        FFlashState := fsSeenAA55
      else
        FFlashState := fsIdle;

    fsSeenAA55:
      begin
        if lowAddr = $5555 then
        begin
          case v of
            $90: begin FFlashChipId := True;  FFlashState := fsIdle; end;
            $F0: begin FFlashChipId := False; FFlashState := fsIdle; end;
            $80: FFlashState := fsEraseAA;
            $A0: FFlashState := fsProgramByte;
            $B0:
              begin
                if FType = stFlash128 then
                  FFlashState := fsBankSwitch
                else
                  FFlashState := fsIdle;
              end;
          else
            FFlashState := fsIdle;
          end;
        end
        else
          FFlashState := fsIdle;
      end;

    fsEraseAA:
      if (lowAddr = $5555) and (v = $AA) then
        FFlashState := fsEraseAA55
      else
        FFlashState := fsIdle;

    fsEraseAA55:
      if (lowAddr = $2AAA) and (v = $55) then
        FFlashState := fsErase
      else
        FFlashState := fsIdle;

    fsErase:
      begin
        if (lowAddr = $5555) and (v = $10) then
        begin
          { Chip-erase: whole 64 KB bank (or both banks for Flash 128). }
          if FType = stFlash128 then
            FillChar(FBuf[0], SAVE_SIZE_FLASH128, $FF)
          else
            FillChar(FBuf[0], SAVE_SIZE_FLASH64, $FF);
          FDirty := True;
        end
        else if v = $30 then
        begin
          { Sector erase: 4 KB sector starting at sector-aligned address. }
          offs := BufOffsetForFlash(addr) and not Integer($FFF);
          if (offs >= 0) and (offs + $1000 <= FBufSize) then
            FillChar(FBuf[offs], $1000, $FF);
          FDirty := True;
        end;
        FFlashState := fsIdle;
      end;

    fsProgramByte:
      begin
        offs := BufOffsetForFlash(addr);
        { Flash can only flip 1→0 — AND the new value with existing. }
        FBuf[offs] := FBuf[offs] and v;
        FDirty := True;
        FFlashState := fsIdle;
      end;

    fsBankSwitch:
      begin
        if lowAddr = $0000 then
          FFlashBank := v and 1;
        FFlashState := fsIdle;
      end;

    fsChipIdRead:
      FFlashState := fsIdle;
  end;
end;

procedure TGbaSave.LoadFromDisk;
var
  f: file of Byte;
  diskSize: Int64;
  bytesRead: Integer;
begin
  if FPath = '' then Exit;
  if not FileExists(FPath) then Exit;

  AssignFile(f, FPath);
  try
    Reset(f);
    diskSize := FileSize(f);

    if diskSize > FBufSize then bytesRead := FBufSize
                           else bytesRead := Integer(diskSize);

    if bytesRead > 0 then
      BlockRead(f, FBuf[0], bytesRead);

    { Pad remainder with the erased-state byte (Flash) or zero (SRAM). }
    if bytesRead < FBufSize then
    begin
      if IsFlash then
        FillChar(FBuf[bytesRead], FBufSize - bytesRead, $FF)
      else
        FillChar(FBuf[bytesRead], FBufSize - bytesRead, 0);
    end;
  finally
    CloseFile(f);
  end;

  FDirty := False;
end;

procedure TGbaSave.Flush;
var
  f: file of Byte;
begin
  if FPath = '' then Exit;
  if not FDirty then Exit;
  if FBufSize <= 0 then Exit;

  AssignFile(f, FPath);
  try
    Rewrite(f);
    BlockWrite(f, FBuf[0], FBufSize);
  finally
    CloseFile(f);
  end;

  FDirty := False;
end;

end.
