unit Input;
{
  GBA input bridge — translates host keyboard state into the KEYINPUT
  register at $04000130.

  ── KEYINPUT semantics ──

  10-bit register, ACTIVE-LOW: each bit is 0 when the corresponding
  button is pressed and 1 when released. Default state (no buttons
  pressed) = $03FF.

    bit 0  A         bit 5  D-pad LEFT
    bit 1  B         bit 6  D-pad UP
    bit 2  SELECT    bit 7  D-pad DOWN
    bit 3  START     bit 8  R shoulder
    bit 4  D-pad RIGHT  bit 9  L shoulder

  ── Default key map (per task file) ──

    Z       → A
    X       → B
    Enter   → START
    BkSpc   → SELECT
    ↑↓←→    → D-pad
    Q       → L shoulder
    W       → R shoulder

  Mapping is configurable at construction; defaults baked in for the
  common case.

  ── Wiring ──

  TGbaInput holds a reference to TGbaMemory and an OPTIONAL TGbaDisplay.
  When a display is attached, each call to `Update` walks the mapping
  table, reads each Win32 key state from the display, and builds the
  10-bit KEYINPUT value. When display is nil (headless / replay-driven
  runs), Update keeps KEYINPUT at the most-recently-set state —
  `OverrideKeyState` sits on top of this for scripted input. Call
  Update once per frame (or once per vblank, same thing).
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Windows, GbaTypes, Memory, Display;

const
  REG_KEYINPUT = $130;   { offset within $04000000 }
  KEYINPUT_ADDR = $04000130;

  { Button bit indices in KEYINPUT. }
  KEY_A      = 0;
  KEY_B      = 1;
  KEY_SELECT = 2;
  KEY_START  = 3;
  KEY_RIGHT  = 4;
  KEY_LEFT   = 5;
  KEY_UP     = 6;
  KEY_DOWN   = 7;
  KEY_R      = 8;
  KEY_L      = 9;

type
  TKeyMapping = record
    Vk:    Integer;     { Win32 VK code (e.g. Ord('Z'), VK_LEFT) }
    Button: Integer;    { KEY_* constant above }
  end;

  TGbaInput = class
  private
    FMem:     TGbaMemory;
    FDisplay: TGbaDisplay;
    FMap:     array of TKeyMapping;
  public
    constructor Create(mem: TGbaMemory; display: TGbaDisplay);
    procedure AddMapping(vk, button: Integer);
    procedure UseDefaultMapping;
    procedure Update;

    { Set the KEYINPUT register directly, bypassing the
      display→keymap path. Use for replay scripts in headless runs. }
    procedure OverrideKeyState(state: TWord);
  end;

implementation

constructor TGbaInput.Create(mem: TGbaMemory; display: TGbaDisplay);
begin
  inherited Create;
  FMem := mem;
  FDisplay := display;
  SetLength(FMap, 0);

  { Seed KEYINPUT to "nothing pressed" so code that reads it before the
    first Update sees a sane value. }
  FMem.WriteHalf(KEYINPUT_ADDR, $03FF);
end;

procedure TGbaInput.AddMapping(vk, button: Integer);
var
  n: Integer;
begin
  n := Length(FMap);
  SetLength(FMap, n + 1);
  FMap[n].Vk := vk;
  FMap[n].Button := button;
end;

procedure TGbaInput.UseDefaultMapping;
begin
  SetLength(FMap, 0);
  AddMapping(Ord('Z'),     KEY_A);
  AddMapping(Ord('X'),     KEY_B);
  AddMapping(VK_RETURN,    KEY_START);
  AddMapping(VK_BACK,      KEY_SELECT);
  AddMapping(VK_UP,        KEY_UP);
  AddMapping(VK_DOWN,      KEY_DOWN);
  AddMapping(VK_LEFT,      KEY_LEFT);
  AddMapping(VK_RIGHT,     KEY_RIGHT);
  AddMapping(Ord('Q'),     KEY_L);
  AddMapping(Ord('W'),     KEY_R);
end;

procedure TGbaInput.Update;
var
  i: Integer;
  state: TWord;
begin
  state := $03FF;   { all buttons released — the baseline we always assert }

  if FDisplay <> nil then
  begin
    for i := 0 to High(FMap) do
    begin
      if FDisplay.KeyPressed(FMap[i].Vk) then
        state := state and not (TWord(1) shl FMap[i].Button);
    end;
  end;

  { Always write KEYINPUT — even in headless mode. The host's job is
    to assert keypad state every frame; nothing about lacking a
    keyboard makes the register's value uncertain. The early-return
    introduced for headless mode (when FDisplay is nil) opened a window
    where stray cart-side CPU writes to KEYINPUT could stick, which
    wedged a commercial title's save-walk polling loop.

    The deeper fix lives in `memory.pas`'s `CpuWriteHalf` — it drops
    CPU writes to KEYINPUT entirely (matches real hardware semantics).
    This per-frame re-assert is the input-layer half of the defense:
    KEYINPUT explicitly reflects what the host (window keys or replay
    script) is asserting, not whatever the bus saw last. }
  FMem.WriteHalf(KEYINPUT_ADDR, THalf(state));
end;

procedure TGbaInput.OverrideKeyState(state: TWord);
begin
  FMem.WriteHalf(KEYINPUT_ADDR, THalf(state));
end;

end.
