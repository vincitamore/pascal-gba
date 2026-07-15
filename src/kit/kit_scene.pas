unit Kit_Scene;
{
  Scene machine + registry: the cart's top-level state switcher.

  A scene is a pair of parameterless procedures (Init, Update)
  registered under a small integer id. The id table IS the mini-game
  registry: a hub cart registers hub/title/system screens and one scene
  per mini-game, then keeps its own game-side metadata tables (icon,
  unlock price, star thresholds) indexed by the same id — the kit
  stays out of game-data opinions.

  Per-frame shape:

    while True do
    begin
      WaitVBlank;
      InputUpdate;
      SceneTick;      // runs pending switch, then current Update
    end;

  Switch semantics: SceneSwitch only latches a request; the switch
  happens at the START of the next SceneTick — Init runs once, then
  Update runs in that same tick with SceneFrames = 0. Requesting a
  switch from inside Update is therefore always safe: the current
  frame finishes on the old scene.

  Pure Pascal, no MMIO — the machine itself compiles and tests
  host-side.
}

{$mode objfpc}{$H+}

interface

const
  MAX_SCENES = 32;

type
  TSceneProc = procedure;

{ Register procs under an id (0..MAX_SCENES-1). Either proc may be nil.
  Re-registering an id replaces it. Out-of-range ids are ignored. }
procedure SceneRegister(id: Integer; init, update: TSceneProc);

{ Request a switch; latched until the next SceneTick. Out-of-range or
  unregistered ids are ignored. }
procedure SceneSwitch(id: Integer);

{ Run one frame: apply a pending switch (Init), then call Update. }
procedure SceneTick;

function SceneCurrent: Integer;   { -1 before the first switch lands }
function SceneFrames: LongWord;   { frames since switch-in (0 during the
                                    first Update after Init) }

implementation

type
  TScene = record
    Init:       TSceneProc;
    Update:     TSceneProc;
    Registered: Boolean;
  end;

var
  scenes:  array[0..MAX_SCENES - 1] of TScene;
  current: Integer = -1;
  pending: Integer = -1;
  frames:  LongWord = 0;

procedure SceneRegister(id: Integer; init, update: TSceneProc);
begin
  if (id < 0) or (id >= MAX_SCENES) then Exit;
  scenes[id].Init       := init;
  scenes[id].Update     := update;
  scenes[id].Registered := True;
end;

procedure SceneSwitch(id: Integer);
begin
  if (id < 0) or (id >= MAX_SCENES) then Exit;
  if not scenes[id].Registered then Exit;
  pending := id;
end;

procedure SceneTick;
begin
  if pending >= 0 then
  begin
    current := pending;
    pending := -1;
    frames  := 0;
    if scenes[current].Init <> nil then
      scenes[current].Init();
  end
  else if current >= 0 then
    Inc(frames);

  if (current >= 0) and (scenes[current].Update <> nil) then
    scenes[current].Update();
end;

function SceneCurrent: Integer;
begin
  Result := current;
end;

function SceneFrames: LongWord;
begin
  Result := frames;
end;

end.
