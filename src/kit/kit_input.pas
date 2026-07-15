unit Kit_Input;
{
  Per-frame keypad state with edge detection.

  Call InputUpdate exactly once per frame (right after vblank sync),
  then read the three masks anywhere in that frame:

    InputUpdate;
    if (KeysPressed and KEY_A) <> 0 then Fire;   { new press this frame }
    if (KeysHeld    and KEY_LEFT) <> 0 then MoveLeft;

  Masks are ACTIVE-HIGH (bit set = held) — the raw register's
  active-low sense is converted here once, so game code never touches
  it. The edge computation uses the xor form, which needs no extra
  masking against FPC's word-width promotion of `not`.
}

{$mode objfpc}{$H+}

interface

const
  KEY_A      = $0001;
  KEY_B      = $0002;
  KEY_SELECT = $0004;
  KEY_START  = $0008;
  KEY_RIGHT  = $0010;
  KEY_LEFT   = $0020;
  KEY_UP     = $0040;
  KEY_DOWN   = $0080;
  KEY_R      = $0100;
  KEY_L      = $0200;
  KEY_ANY    = $03FF;

procedure InputUpdate;
function KeysHeld: Word;       { held this frame }
function KeysPressed: Word;    { newly down this frame }
function KeysReleased: Word;   { newly up this frame }

implementation

const
  REG_KEYINPUT = $04000130;

var
  held, prev: Word;

procedure InputUpdate;
begin
  prev := held;
  held := (PWord(REG_KEYINPUT)^ and KEY_ANY) xor KEY_ANY;
end;

function KeysHeld: Word;
begin
  Result := held;
end;

function KeysPressed: Word;
begin
  Result := held and (held xor prev);
end;

function KeysReleased: Word;
begin
  Result := prev and (held xor prev);
end;

end.
