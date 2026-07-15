unit game_snapshot;
{
  Emulator-side reader for the cart-side game-state mirror struct
  written by the cart-side snapshot writer.

  Pure data types + decoder helpers only -- the side-effecting
  DumpGameSnapshot procedure lives in gba_runner.pas where SafeLog
  is in scope.

  Wire contract:
    Address: $0203F000 (EWRAM, well above the FPC linker's heap end
             and disjoint from the DbgLog region at $0203FF80).
    Magic:   $5350474D (header validation; cart writes this every
             frame to prove a valid snapshot is present).
    Version: 1 (bump on any breaking layout change; reader rejects
             mismatched versions instead of decoding garbage).

  Why this lives in src/: the dump-game replay action needs to fire
  from the emulator. Coupling cost: this unit carries the cart schema
  (faction/archetype/terrain name tables). Version field + magic
  validation isolate drift.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  SNAPSHOT_ADDR    = $0203F000;
  SNAPSHOT_MAGIC   = $5350474D;
  SNAPSHOT_VERSION = 1;
  MAX_UNITS        = 6;
  MAP_W            = 15;
  MAP_H            = 10;

type
  TGameSnapshotHeader = packed record
    Magic: LongWord;
    Version: Word;
    StructSize: Word;
    UnitCount: Byte;
    MapWidth: Byte;
    MapHeight: Byte;
    Reserved: Byte;
    HeaderPad: array[0..3] of Byte;
  end;

  TGameSnapshotCore = packed record
    Frame: LongWord;
    State: Byte;
    CurrentFaction: Byte;
    TurnNumber: Word;
    SelectedUnit: SmallInt;
    CursorTileX: ShortInt;
    CursorTileY: ShortInt;
    Victor: Byte;
    CorePad: array[0..2] of Byte;
  end;

  TUnitSnapshot = packed record
    Alive: Byte;
    Faction: Byte;
    Archetype: Byte;
    HP: Byte;
    TileX: Byte;
    TileY: Byte;
    Px: SmallInt;
    Py: SmallInt;
    MovedThisTurn: Byte;
    UnitPad: Byte;
  end;

  TMapTileSnapshot = packed record
    TerrainKind: Byte;
    OwnerFaction: Byte;
    CaptureProgress: Byte;
    TilePad: Byte;
  end;

  TGameSnapshot = packed record
    Header: TGameSnapshotHeader;
    Core: TGameSnapshotCore;
    Units: array[0..MAX_UNITS - 1] of TUnitSnapshot;
    MapTiles: array[0..MAP_H * MAP_W - 1] of TMapTileSnapshot;
  end;

function FactionName(f: Byte): string;
function FactionLetter(f: Byte): string;
function ArchetypeName(a: Byte): string;
function StateName(s: Byte): string;
function TerrainName(t: Byte): string;
function TerrainGlyph(t: Byte): Char;
function IsCapturableTerrain(t: Byte): Boolean;

implementation

function FactionName(f: Byte): string;
begin
  case f of
    0: Result := 'neutral';
    1: Result := 'alpha';
    2: Result := 'beta';
  else  Result := Format('???(%d)', [f]);
  end;
end;

function FactionLetter(f: Byte): string;
begin
  case f of
    0: Result := '-';
    1: Result := 'A';
    2: Result := 'B';
  else  Result := '?';
  end;
end;

function ArchetypeName(a: Byte): string;
begin
  case a of
    0: Result := 'typeA';
    1: Result := 'typeB';
    2: Result := 'typeC';
  else  Result := Format('???(%d)', [a]);
  end;
end;

function StateName(s: Byte): string;
begin
  case s of
    0: Result := 'Idle';
    1: Result := 'Selected';
    2: Result := 'Moving';
    3: Result := 'Battle';
    4: Result := 'Victory';
  else  Result := Format('???(%d)', [s]);
  end;
end;

function TerrainName(t: Byte): string;
begin
  case t of
    0: Result := 'terrain0';
    1: Result := 'terrain1';
    2: Result := 'terrain2';
    3: Result := 'terrain3';
    4: Result := 'terrain4';
    5: Result := 'terrain5';
    6: Result := 'terrain6';
  else  Result := Format('???(%d)', [t]);
  end;
end;

function TerrainGlyph(t: Byte): Char;
begin
  case t of
    0: Result := '0';
    1: Result := '1';
    2: Result := '2';
    3: Result := '3';
    4: Result := '4';
    5: Result := '5';
    6: Result := '6';
  else  Result := '?';
  end;
end;

function IsCapturableTerrain(t: Byte): Boolean;
begin
  Result := (t = 4) or (t = 5);
end;

end.
