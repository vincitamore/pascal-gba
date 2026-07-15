program test_save;
{
  Tests for save.pas — SRAM + Flash 64 KB + Flash 128 KB.

  Build: fpc -Mobjfpc -Sh -Fusrc -FEbin -FUbin test/test_save.pas
  Run:   ./test_save

  Covers:
    - SRAM byte read/write round-trip
    - SRAM halfword write routes low byte through hook
    - Flash 64 chip-ID protocol ($AA/$55/$90 sequence; reads at $0/$1
      return manufacturer/device ID; $F0 exits)
    - Flash 64 program-byte ($AA/$55/$A0 prefix, then byte to addr;
      Flash AND-semantics — only 1→0 transitions stick)
    - Flash 64 sector erase ($AA/$55/$80, $AA/$55/$30 at sector addr;
      4 KB sector becomes $FF)
    - Flash 64 chip erase ($AA/$55/$80, $AA/$55/$10; whole 64 KB → $FF)
    - Flash 128 bank switch ($AA/$55/$B0, bank value at $0E000000)
    - Flash 128 second bank addressable after switch
    - LoadFromDisk + Flush round-trip (write, flush, reload, verify)
    - Sequence-mismatch resets the state machine to Idle
}

{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, Memory, Cart, Save;

var
  TotalTests:   Integer = 0;
  PassedTests:  Integer = 0;
  Assertions:   Integer = 0;

procedure StartTest(const name: string);
begin
  Inc(TotalTests);
  Write(Format('  [%2d] %-50s ', [TotalTests, name]));
end;

procedure FinishTest;
begin
  Inc(PassedTests);
  Writeln('OK');
end;

procedure FailTest(const reason: string);
begin
  Writeln(Format('FAIL  (%s)', [reason]));
end;

procedure Expect(cond: Boolean; const reason: string);
begin
  Inc(Assertions);
  if not cond then
  begin
    Writeln;
    Writeln(Format('     ! ASSERTION FAILED: %s', [reason]));
    Halt(1);
  end;
end;

function MakeSave(stype: TSaveType; const path: string;
                  out mem: TGbaMemory; out save: TGbaSave): Boolean;
var
  info: TCartInfo;
begin
  Result := False;
  mem := TGbaMemory.Create;
  FillChar(info, SizeOf(info), 0);
  info.SaveType := stype;
  save := TGbaSave.Create(mem, info, path);
  mem.SetSaveReadHook(@save.ReadByte);
  mem.SetSaveWriteHook(@save.WriteByte);
  Result := True;
end;

procedure TeardownSave(mem: TGbaMemory; save: TGbaSave);
begin
  save.Free;
  mem.Free;
end;

procedure TestSramByteRoundTrip;
var
  mem:  TGbaMemory;
  save: TGbaSave;
  i:    Integer;
begin
  StartTest('SRAM byte read/write round-trip');
  MakeSave(stSRAM, '', mem, save);
  try
    for i := 0 to 31 do
      mem.WriteByte(TWord($0E000000 + i), TByte((i * 3 + 7) and $FF));

    for i := 0 to 31 do
      Expect(mem.ReadByte(TWord($0E000000 + i)) = TByte((i * 3 + 7) and $FF),
             Format('SRAM byte at +%d', [i]));
  finally
    TeardownSave(mem, save);
  end;
  FinishTest;
end;

procedure TestSramHalfwordWritesLowByte;
var
  mem:  TGbaMemory;
  save: TGbaSave;
begin
  StartTest('SRAM halfword write routes low byte');
  MakeSave(stSRAM, '', mem, save);
  try
    { Halfword $1234 at $0E000100 should write $34 to that address. }
    mem.WriteHalf(TWord($0E000100), $1234);
    Expect(mem.ReadByte($0E000100) = $34, 'low byte of halfword stored');
  finally
    TeardownSave(mem, save);
  end;
  FinishTest;
end;

procedure FlashCmd(mem: TGbaMemory; addr: TWord; v: TByte);
begin
  mem.WriteByte(addr, v);
end;

procedure FlashEnterChipId(mem: TGbaMemory);
begin
  FlashCmd(mem, $0E005555, $AA);
  FlashCmd(mem, $0E002AAA, $55);
  FlashCmd(mem, $0E005555, $90);
end;

procedure FlashExitChipId(mem: TGbaMemory);
begin
  FlashCmd(mem, $0E005555, $AA);
  FlashCmd(mem, $0E002AAA, $55);
  FlashCmd(mem, $0E005555, $F0);
end;

procedure TestFlash64ChipId;
var
  mem:  TGbaMemory;
  save: TGbaSave;
begin
  StartTest('Flash 64 chip-ID protocol ($AA/$55/$90, exit $F0)');
  MakeSave(stFlash64, '', mem, save);
  try
    { Before entering chip-ID mode, reads return data ($FF on fresh Flash). }
    Expect(mem.ReadByte($0E000000) = $FF, 'fresh Flash reads as $FF');
    Expect(mem.ReadByte($0E000001) = $FF, 'fresh Flash byte 1 = $FF');

    FlashEnterChipId(mem);
    Expect(mem.ReadByte($0E000000) = $1F, 'manufacturer ID = $1F (Atmel)');
    Expect(mem.ReadByte($0E000001) = $3D, 'device ID = $3D (AT29LV512)');

    FlashExitChipId(mem);
    Expect(mem.ReadByte($0E000000) = $FF, 'after exit, reads return data');
    Expect(mem.ReadByte($0E000001) = $FF, 'byte 1 also returns data');
  finally
    TeardownSave(mem, save);
  end;
  FinishTest;
end;

procedure FlashProgramByte(mem: TGbaMemory; addr: TWord; v: TByte);
begin
  FlashCmd(mem, $0E005555, $AA);
  FlashCmd(mem, $0E002AAA, $55);
  FlashCmd(mem, $0E005555, $A0);
  FlashCmd(mem, addr, v);
end;

procedure TestFlash64ProgramByte;
var
  mem:  TGbaMemory;
  save: TGbaSave;
begin
  StartTest('Flash 64 program byte ($A0; only 1->0 sticks)');
  MakeSave(stFlash64, '', mem, save);
  try
    { Program $42 at $0E000010. Should appear at next read. }
    FlashProgramByte(mem, $0E000010, $42);
    Expect(mem.ReadByte($0E000010) = $42, 'first program byte stored');

    { Program $0F at $0E000010 again. Flash can only 1->0, so result is
      $42 AND $0F = $02. }
    FlashProgramByte(mem, $0E000010, $0F);
    Expect(mem.ReadByte($0E000010) = $02, 'AND-semantics: $42 AND $0F = $02');

    { Program $FF at the same address — no change ($02 AND $FF = $02). }
    FlashProgramByte(mem, $0E000010, $FF);
    Expect(mem.ReadByte($0E000010) = $02, '$FF write is no-op');

    { Program a fresh byte. }
    FlashProgramByte(mem, $0E000020, $A5);
    Expect(mem.ReadByte($0E000020) = $A5, 'fresh byte programmed');

    { Direct write WITHOUT command prefix is ignored. }
    mem.WriteByte($0E000030, $77);
    Expect(mem.ReadByte($0E000030) = $FF, 'plain write ignored on Flash');
  finally
    TeardownSave(mem, save);
  end;
  FinishTest;
end;

procedure FlashSectorErase(mem: TGbaMemory; sectorAddr: TWord);
begin
  FlashCmd(mem, $0E005555, $AA);
  FlashCmd(mem, $0E002AAA, $55);
  FlashCmd(mem, $0E005555, $80);
  FlashCmd(mem, $0E005555, $AA);
  FlashCmd(mem, $0E002AAA, $55);
  FlashCmd(mem, sectorAddr, $30);
end;

procedure TestFlash64SectorErase;
var
  mem:  TGbaMemory;
  save: TGbaSave;
  i:    Integer;
begin
  StartTest('Flash 64 sector erase ($30; 4 KB sector -> $FF)');
  MakeSave(stFlash64, '', mem, save);
  try
    { Program some bytes spread across two sectors. }
    FlashProgramByte(mem, $0E000010, $00);
    FlashProgramByte(mem, $0E000820, $01);   { still in sector 0 (0x0000-0x0FFF) }
    FlashProgramByte(mem, $0E001010, $02);   { sector 1 (0x1000-0x1FFF) }

    Expect(mem.ReadByte($0E000010) = $00, 'sector 0 byte before erase');
    Expect(mem.ReadByte($0E001010) = $02, 'sector 1 byte before erase');

    { Erase sector 0 (4 KB starting at $0E000000). }
    FlashSectorErase(mem, $0E000000);

    Expect(mem.ReadByte($0E000010) = $FF, 'sector 0 byte erased');
    Expect(mem.ReadByte($0E000820) = $FF, 'sector 0 byte erased (high offs)');
    Expect(mem.ReadByte($0E001010) = $02, 'sector 1 byte UNTOUCHED');

    { Spot-check every byte in sector 0. }
    for i := 0 to 4095 do
      Expect(mem.ReadByte(TWord($0E000000 + i)) = $FF,
             Format('sector 0 byte @+%x', [i]));
  finally
    TeardownSave(mem, save);
  end;
  FinishTest;
end;

procedure TestFlash64ChipErase;
var
  mem:  TGbaMemory;
  save: TGbaSave;
begin
  StartTest('Flash 64 chip erase ($10; full 64 KB -> $FF)');
  MakeSave(stFlash64, '', mem, save);
  try
    FlashProgramByte(mem, $0E000010, $33);
    FlashProgramByte(mem, $0E00F000, $44);
    Expect(mem.ReadByte($0E000010) = $33, 'byte set before erase');
    Expect(mem.ReadByte($0E00F000) = $44, 'high byte set before erase');

    { Chip erase: prefix + prefix + $10 at $5555. }
    FlashCmd(mem, $0E005555, $AA);
    FlashCmd(mem, $0E002AAA, $55);
    FlashCmd(mem, $0E005555, $80);
    FlashCmd(mem, $0E005555, $AA);
    FlashCmd(mem, $0E002AAA, $55);
    FlashCmd(mem, $0E005555, $10);

    Expect(mem.ReadByte($0E000010) = $FF, 'low byte erased');
    Expect(mem.ReadByte($0E00F000) = $FF, 'high byte erased');
  finally
    TeardownSave(mem, save);
  end;
  FinishTest;
end;

procedure TestFlash128BankSwitch;
var
  mem:  TGbaMemory;
  save: TGbaSave;
begin
  StartTest('Flash 128 bank switch ($B0; second bank addressable)');
  MakeSave(stFlash128, '', mem, save);
  try
    { Write to bank 0. }
    FlashProgramByte(mem, $0E000010, $A0);

    { Switch to bank 1. }
    FlashCmd(mem, $0E005555, $AA);
    FlashCmd(mem, $0E002AAA, $55);
    FlashCmd(mem, $0E005555, $B0);
    FlashCmd(mem, $0E000000, $01);

    { Same address $0E000010 should now read bank-1 (which is fresh $FF). }
    Expect(mem.ReadByte($0E000010) = $FF, 'bank 1 byte 10 fresh');

    { Write to bank 1. }
    FlashProgramByte(mem, $0E000010, $B1);
    Expect(mem.ReadByte($0E000010) = $B1, 'bank 1 byte programmed');

    { Switch back to bank 0. }
    FlashCmd(mem, $0E005555, $AA);
    FlashCmd(mem, $0E002AAA, $55);
    FlashCmd(mem, $0E005555, $B0);
    FlashCmd(mem, $0E000000, $00);

    { Bank 0 byte should be the original $A0. }
    Expect(mem.ReadByte($0E000010) = $A0, 'bank 0 byte preserved');
  finally
    TeardownSave(mem, save);
  end;
  FinishTest;
end;

procedure TestSequenceMismatchResetsState;
var
  mem:  TGbaMemory;
  save: TGbaSave;
begin
  StartTest('Flash sequence mismatch resets state machine');
  MakeSave(stFlash64, '', mem, save);
  try
    { Send $AA at $5555 (correct), then garbage. State should reset. }
    FlashCmd(mem, $0E005555, $AA);
    FlashCmd(mem, $0E001111, $55);   { wrong address — should reset }
    FlashCmd(mem, $0E005555, $90);   { would be chip-ID; should NOT take effect }

    { Reads should still show data, NOT chip-ID. }
    Expect(mem.ReadByte($0E000000) = $FF, 'no chip-ID mode after mismatch');

    { Now do a CORRECT sequence to confirm machine works. }
    FlashEnterChipId(mem);
    Expect(mem.ReadByte($0E000000) = $1F, 'correct sequence after mismatch works');
  finally
    TeardownSave(mem, save);
  end;
  FinishTest;
end;

procedure TestFlushAndLoad;
var
  mem:  TGbaMemory;
  save: TGbaSave;
  testPath: string;
  v: TByte;
begin
  StartTest('Flash 64 flush + load round-trip preserves state');
  testPath := GetTempDir(False) + 'test_save_roundtrip.sav';
  if FileExists(testPath) then DeleteFile(testPath);

  MakeSave(stFlash64, testPath, mem, save);
  try
    FlashProgramByte(mem, $0E000100, $5A);
    FlashProgramByte(mem, $0E000200, $A5);
    FlashProgramByte(mem, $0E00F000, $C3);
    save.Flush;
    Expect(FileExists(testPath), '.sav file created on flush');
  finally
    TeardownSave(mem, save);
  end;

  { Reload into a fresh instance — should see same bytes. }
  MakeSave(stFlash64, testPath, mem, save);
  try
    save.LoadFromDisk;
    Expect(mem.ReadByte($0E000100) = $5A, 'byte at $100 survives reload');
    Expect(mem.ReadByte($0E000200) = $A5, 'byte at $200 survives reload');
    Expect(mem.ReadByte($0E00F000) = $C3, 'high byte survives reload');
    v := mem.ReadByte($0E000300);
    Expect(v = $FF, 'unwritten byte is erased ($FF)');
  finally
    TeardownSave(mem, save);
  end;
  DeleteFile(testPath);
  FinishTest;
end;

procedure TestSramFlushAndLoad;
var
  mem:  TGbaMemory;
  save: TGbaSave;
  testPath: string;
begin
  StartTest('SRAM flush + load round-trip preserves state');
  testPath := GetTempDir(False) + 'test_save_sram_roundtrip.sav';
  if FileExists(testPath) then DeleteFile(testPath);

  MakeSave(stSRAM, testPath, mem, save);
  try
    mem.WriteByte($0E000000, $11);
    mem.WriteByte($0E000001, $22);
    mem.WriteByte($0E007FFF, $FE);     { last byte of 32 KB }
    save.Flush;
    Expect(FileExists(testPath), '.sav file created on flush');
  finally
    TeardownSave(mem, save);
  end;

  MakeSave(stSRAM, testPath, mem, save);
  try
    save.LoadFromDisk;
    Expect(mem.ReadByte($0E000000) = $11, 'byte 0 survives');
    Expect(mem.ReadByte($0E000001) = $22, 'byte 1 survives');
    Expect(mem.ReadByte($0E007FFF) = $FE, 'last SRAM byte survives');
  finally
    TeardownSave(mem, save);
  end;
  DeleteFile(testPath);
  FinishTest;
end;

begin
  Writeln('test_save: SRAM + Flash 64/128 save backends');
  Writeln;

  TestSramByteRoundTrip;
  TestSramHalfwordWritesLowByte;
  TestFlash64ChipId;
  TestFlash64ProgramByte;
  TestFlash64SectorErase;
  TestFlash64ChipErase;
  TestFlash128BankSwitch;
  TestSequenceMismatchResetsState;
  TestFlushAndLoad;
  TestSramFlushAndLoad;

  Writeln;
  Writeln(Format('Results: %d/%d tests passed, %d assertions',
                 [PassedTests, TotalTests, Assertions]));

  if PassedTests = TotalTests then Halt(0) else Halt(1);
end.
