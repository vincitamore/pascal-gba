unit Replay;
{
  Scripted input replay + recording for the headless/dev harness.

  ── Why this exists ──

  Headless mode without input replay can only capture pre-input game
  states (BIOS splash, attract-mode loops). Anything past a "Press
  Start to begin" prompt requires scripted key events. With replay,
  the agent loop becomes:

    1. Write a small text script (frame numbers + button events).
    2. Run `gbarun --headless --replay script.txt --screenshot ...`.
    3. Inspect the PNG.

  No human-in-the-loop for repeatable visual regression tests.

  ── Script format ──

  Plain text, one event per line:

    # comments start with '#'
    # blank lines OK

    0    press    START      # start holding Start at frame 0
    1    release  START      # release at frame 1 (tap)
    60   tap      A          # convenience: press+release at frame 60
    120  press    DOWN       # hold Down from frame 120
    180  release  DOWN       # release at frame 180

  Buttons (case-insensitive): A, B, START, SELECT, UP, DOWN, LEFT,
  RIGHT, L, R.

  Actions (input):
    press <btn>    → start holding the button (KEYINPUT bit clears)
    release <btn>  → stop holding (bit sets)
    tap <btn>      → press at this frame, release at next frame

  Actions (capture — side effects queued for the host to drain):
    screenshot <path>  → write framebuffer PNG at this frame
    dump-state <path>  → write full DumpDebugState (CPU regs, IRQ/timer/
                         DMA regs, OAM, mp2k state, DbgLog tail, ...) to
                         the explicit path. Mirror of the F12 keypress
                         capture, but addressable from a replay script
                         at named frames.
    dump-game <path>   → write a human-readable text dump of the cart-
                         side TGameSnapshot mirror struct at fixed
                         address $0203F000. Decodes game-level fields
                         (cursor, state, units, per-tile map state).
                         Snapshot region is owned by the cart-side
                         snapshot writer; the dump action just reads +
                         formats. Returns a "schema mismatch" stub if
                         the cart hasn't written a valid header.

  Frame numbers must be non-decreasing; the parser sorts on load
  anyway so out-of-order scripts work but are normalised.

  ── Wiring ──

  Construct with a TGbaInput; call `LoadScript` to populate; call
  `Tick(frame)` once per frame BEFORE the scanline loop. Tick applies
  any events scheduled for that frame and writes the current KEYINPUT
  mask via `input.OverrideKeyState` — every frame while the script is
  active, so scripted holds survive kbd.Update's per-frame all-released
  baseline (not just on event frames).

  Records are the inverse: when Recording=True, Tick samples the
  current KEYINPUT state and diffs against the previous sample to
  emit press/release events. Call `FlushRecording` to write the
  script to disk before destruction.

  ── Integration with kbd.Update ──

  In a windowed run, `kbd.Update` writes the window's live key state
  to KEYINPUT every frame. Replay's Tick runs AFTER kbd.Update and
  overrides — meaning live key presses are ignored while a
  replay script is loaded. Stop the script (or run without --replay)
  to restore manual input.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, GbaTypes, Memory, Input;

type
  TReplayAction = (raPress, raRelease, raTap, raScreenshot, raDumpState, raDumpGame);

  TReplayEvent = record
    Frame:  Int64;
    Action: TReplayAction;
    Button: Integer;        { used by raPress/raRelease/raTap; ignored otherwise }
    Path:   string;         { used by raScreenshot for the output PNG path }
  end;

  { Side effects accumulated during Tick that the caller must service after
    Tick returns. The replay engine itself has no access to PPU/CPU/etc; it
    queues the request and the host (gba_runner) drains. }
  TReplaySideEffectKind = (sekScreenshot, sekDumpState, sekDumpGame);
  TReplaySideEffect = record
    Kind: TReplaySideEffectKind;
    Path: string;
  end;

  TReplayEngine = class
  private
    FInput:        TGbaInput;
    FMem:          TGbaMemory;            { for live KEYINPUT sampling in record mode }
    FEvents:       array of TReplayEvent;
    FEventCount:   Integer;
    FNextIdx:      Integer;
    FState:        TWord;                  { current KEYINPUT mask, $03FF = released }
    FFinished:     Boolean;
    FLoadedPath:   string;

    { Record-mode state. }
    FRecording:    Boolean;
    FRecordPath:   string;
    FRecordEvents: array of TReplayEvent;
    FRecordCount:  Integer;
    FPrevSample:   TWord;
    FPrevSampled:  Boolean;

    { Side-effect queue. Populated by ApplyEvent for non-input actions
      (raScreenshot). Drained by the host via the public methods below
      AFTER calling Tick. Cleared automatically at the start of every
      Tick so events only surface for one frame. }
    FSideEffects:  array of TReplaySideEffect;
    FSideCount:    Integer;

    procedure QueueSideEffect(const fx: TReplaySideEffect);

    function ParseButton(const s: string): Integer;
    function ButtonName(buttonIdx: Integer): string;
    procedure ApplyEvent(const ev: TReplayEvent);
    procedure SortEvents;

  public
    constructor Create(input: TGbaInput; mem: TGbaMemory);
    destructor  Destroy; override;

    { Load a replay script. Returns True on clean parse; False if the
      file doesn't exist or any line fails to parse. Errors are
      surfaced via SafeLogErr; the engine is left empty on failure. }
    function LoadScript(const path: string): Boolean;

    { Begin recording to `path`. Each Tick samples KEYINPUT and emits
      press/release events for any bit that changed since the last
      sample. Call FlushRecording before destruction to write the
      file. }
    procedure StartRecording(const path: string);

    { Write recorded events to FRecordPath. Returns True on success. }
    function  FlushRecording: Boolean;

    { Apply any events scheduled for `frame` and push the resulting
      KEYINPUT mask to the input layer via OverrideKeyState. In
      recording mode, also samples KEYINPUT after the events apply
      (capturing both scripted + live input). }
    procedure Tick(frame: Int64);

    { True after every scripted event has fired. Useful for the
      runner: once Finished, replay no longer overrides input —
      live keys (windowed mode) take effect again. }
    property Finished:    Boolean read FFinished;
    property EventCount:  Integer read FEventCount;
    property LoadedPath:  string  read FLoadedPath;
    property RecordCount: Integer read FRecordCount;

    { After Tick, iterate accumulated side effects (e.g. screenshot
      requests) and execute them. Cleared at the start of the next Tick. }
    function  SideEffectCount: Integer;
    function  SideEffect(idx: Integer): TReplaySideEffect;
  end;

implementation

const
  KEYINPUT_RELEASED = $03FF;

constructor TReplayEngine.Create(input: TGbaInput; mem: TGbaMemory);
begin
  inherited Create;
  FInput        := input;
  FMem          := mem;
  FEventCount   := 0;
  FNextIdx      := 0;
  FState        := KEYINPUT_RELEASED;
  FFinished     := False;
  FRecording    := False;
  FRecordCount  := 0;
  FPrevSampled  := False;
  FPrevSample   := KEYINPUT_RELEASED;
  FSideCount    := 0;
end;

destructor TReplayEngine.Destroy;
begin
  if FRecording then FlushRecording;
  inherited Destroy;
end;

function TReplayEngine.ParseButton(const s: string): Integer;
{ Case-insensitive name → KEY_* index. Returns -1 for unknown. }
var
  u: string;
begin
  u := UpperCase(Trim(s));
  if      u = 'A'      then Result := KEY_A
  else if u = 'B'      then Result := KEY_B
  else if u = 'START'  then Result := KEY_START
  else if u = 'SELECT' then Result := KEY_SELECT
  else if u = 'UP'     then Result := KEY_UP
  else if u = 'DOWN'   then Result := KEY_DOWN
  else if u = 'LEFT'   then Result := KEY_LEFT
  else if u = 'RIGHT'  then Result := KEY_RIGHT
  else if u = 'L'      then Result := KEY_L
  else if u = 'R'      then Result := KEY_R
  else                      Result := -1;
end;

function TReplayEngine.ButtonName(buttonIdx: Integer): string;
begin
  case buttonIdx of
    KEY_A:      Result := 'A';
    KEY_B:      Result := 'B';
    KEY_START:  Result := 'START';
    KEY_SELECT: Result := 'SELECT';
    KEY_UP:     Result := 'UP';
    KEY_DOWN:   Result := 'DOWN';
    KEY_LEFT:   Result := 'LEFT';
    KEY_RIGHT:  Result := 'RIGHT';
    KEY_L:      Result := 'L';
    KEY_R:      Result := 'R';
  else
    Result := '?';
  end;
end;

procedure TReplayEngine.SortEvents;
{ Insertion sort by frame (events lists are typically small and
  near-sorted; insertion sort is O(n) on already-sorted input). }
var
  i, j: Integer;
  tmp:  TReplayEvent;
begin
  for i := 1 to FEventCount - 1 do
  begin
    tmp := FEvents[i];
    j := i;
    while (j > 0) and (FEvents[j - 1].Frame > tmp.Frame) do
    begin
      FEvents[j] := FEvents[j - 1];
      Dec(j);
    end;
    FEvents[j] := tmp;
  end;
end;

function TReplayEngine.LoadScript(const path: string): Boolean;
var
  lines:   TStringList;
  i, j, lineNum: Integer;
  line, tok: string;
  ev:      TReplayEvent;
  actionStr: string;
  frameVal: Int64;
  parseErr: Boolean;
  inputBuf, partsBuf: string;
  partsTmp: TStringList;
begin
  Result := False;
  FEventCount := 0;
  FNextIdx := 0;
  FState := KEYINPUT_RELEASED;
  FFinished := False;
  SetLength(FEvents, 0);

  if not FileExists(path) then
  begin
    SafeLogErr(Format('replay: script not found at "%s"', [path]));
    Exit;
  end;

  lines := TStringList.Create;
  partsTmp := TStringList.Create;
  try
    lines.LoadFromFile(path);
    parseErr := False;

    for lineNum := 0 to lines.Count - 1 do
    begin
      { Strip comments and trim whitespace. }
      line := Trim(lines[lineNum]);
      j := Pos('#', line);
      if j > 0 then line := Trim(Copy(line, 1, j - 1));
      if line = '' then Continue;

      { Split on whitespace — TStringList with Delimiter=' ' collapses
        consecutive spaces only with DelimitedText quoting, so do it
        by hand. }
      partsTmp.Clear;
      i := 1;
      tok := '';
      while i <= Length(line) do
      begin
        if (line[i] = ' ') or (line[i] = #9) then
        begin
          if tok <> '' then begin partsTmp.Add(tok); tok := ''; end;
        end
        else
          tok := tok + line[i];
        Inc(i);
      end;
      if tok <> '' then partsTmp.Add(tok);

      if partsTmp.Count < 3 then
      begin
        SafeLogErr(Format('replay: line %d: expected "<frame> <action> <button>", got "%s"',
          [lineNum + 1, line]));
        parseErr := True;
        Continue;
      end;

      frameVal := StrToInt64Def(partsTmp[0], -1);
      if frameVal < 0 then
      begin
        SafeLogErr(Format('replay: line %d: invalid frame "%s"',
          [lineNum + 1, partsTmp[0]]));
        parseErr := True;
        Continue;
      end;

      actionStr := LowerCase(partsTmp[1]);
      ev.Frame  := frameVal;
      ev.Button := -1;
      ev.Path   := '';

      { Side-effect actions take a PATH as third token instead of a button.
        Press/release/tap take a BUTTON. Parse accordingly. The path-shaped
        actions live in a single branch so adding the next one (dump-audio,
        dump-vram, ...) is a one-line extension. }
      if (actionStr = 'screenshot') or (actionStr = 'dump-state') or (actionStr = 'dump-game') then
      begin
        if      actionStr = 'screenshot' then ev.Action := raScreenshot
        else if actionStr = 'dump-state' then ev.Action := raDumpState
        else                                  ev.Action := raDumpGame;
        ev.Path := partsTmp[2];
      end
      else
      begin
        ev.Button := ParseButton(partsTmp[2]);
        if ev.Button < 0 then
        begin
          SafeLogErr(Format('replay: line %d: unknown button "%s"',
            [lineNum + 1, partsTmp[2]]));
          parseErr := True;
          Continue;
        end;

        if      actionStr = 'press'   then ev.Action := raPress
        else if actionStr = 'release' then ev.Action := raRelease
        else if actionStr = 'tap'     then ev.Action := raTap
        else
        begin
          SafeLogErr(Format('replay: line %d: unknown action "%s" (expected press/release/tap/screenshot/dump-state/dump-game)',
            [lineNum + 1, partsTmp[1]]));
          parseErr := True;
          Continue;
        end;
      end;

      { Append. tap expands into press@frame + release@frame+1 so
        the engine doesn't need a special-case path at runtime. }
      if ev.Action = raTap then
      begin
        SetLength(FEvents, FEventCount + 2);
        FEvents[FEventCount] := ev;
        FEvents[FEventCount].Action := raPress;
        Inc(FEventCount);
        FEvents[FEventCount] := ev;
        FEvents[FEventCount].Action := raRelease;
        FEvents[FEventCount].Frame  := ev.Frame + 1;
        Inc(FEventCount);
      end
      else
      begin
        SetLength(FEvents, FEventCount + 1);
        FEvents[FEventCount] := ev;
        Inc(FEventCount);
      end;
    end;

    if parseErr then
    begin
      FEventCount := 0;
      SetLength(FEvents, 0);
      Exit;
    end;

    SortEvents;
    FLoadedPath := path;
    Result := True;
    SafeLog(Format('replay: loaded %d events from %s',
      [FEventCount, path]));
  finally
    inputBuf := '';  if inputBuf = '' then ;   { silence unused var hint }
    partsBuf := '';  if partsBuf = '' then ;
    partsTmp.Free;
    lines.Free;
  end;
end;

procedure TReplayEngine.QueueSideEffect(const fx: TReplaySideEffect);
begin
  if FSideCount >= Length(FSideEffects) then
    SetLength(FSideEffects, FSideCount + 4);
  FSideEffects[FSideCount] := fx;
  Inc(FSideCount);
end;

function TReplayEngine.SideEffectCount: Integer;
begin
  Result := FSideCount;
end;

function TReplayEngine.SideEffect(idx: Integer): TReplaySideEffect;
begin
  if (idx < 0) or (idx >= FSideCount) then
  begin
    Result.Kind := sekScreenshot;
    Result.Path := '';
    Exit;
  end;
  Result := FSideEffects[idx];
end;

procedure TReplayEngine.ApplyEvent(const ev: TReplayEvent);
{ Mutate FState for press/release; queue side effects for screenshot/etc.
  raTap was already expanded into press+release in LoadScript. }
var
  fx: TReplaySideEffect;
begin
  case ev.Action of
    raPress:      FState := FState and not (TWord(1) shl ev.Button);
    raRelease:    FState := FState or       (TWord(1) shl ev.Button);
    raTap:        { unreachable -- expanded at load time };
    raScreenshot:
      begin
        fx.Kind := sekScreenshot;
        fx.Path := ev.Path;
        QueueSideEffect(fx);
      end;
    raDumpState:
      begin
        fx.Kind := sekDumpState;
        fx.Path := ev.Path;
        QueueSideEffect(fx);
      end;
    raDumpGame:
      begin
        fx.Kind := sekDumpGame;
        fx.Path := ev.Path;
        QueueSideEffect(fx);
      end;
  end;
end;

procedure TReplayEngine.Tick(frame: Int64);
var
  changed: Boolean;
  curMask, diff, mask: TWord;
  bit: Integer;
  ev:  TReplayEvent;
begin
  { Drain previous frame's side effects -- host is expected to have
    serviced them during/after the previous Tick call. }
  FSideCount := 0;

  { Apply any scheduled events at this frame. May fire several
    consecutive events (e.g. tap-expanded press at frame N + a
    separately-scheduled release at frame N). }
  changed := False;
  while (FNextIdx < FEventCount) and (FEvents[FNextIdx].Frame <= frame) do
  begin
    ApplyEvent(FEvents[FNextIdx]);
    Inc(FNextIdx);
    changed := True;
  end;

  if FNextIdx >= FEventCount then FFinished := True;

  { Push the mask EVERY frame while the script is active, not only on
    event frames. kbd.Update asserts the all-released baseline each
    frame before Tick runs, so a one-shot override on the event frame
    would let a scripted hold evaporate after a single frame (headless
    runs have no live keyboard to reassert it — a `press`/`release`
    pair would act as a 1-frame tap). While unfinished the script owns
    KEYINPUT; `changed` keeps the final event's own frame covered, then
    live input resumes. }
  if (FInput <> nil) and ((not FFinished) or changed) then
    FInput.OverrideKeyState(FState);

  { Recording — sample the LIVE KEYINPUT register and emit diff events
    for every bit that changed since the last sample. Sampling the live
    MMIO (rather than the engine's internal FState) captures both
    scripted input AND live key presses from kbd.Update: in --record
    mode without --replay (manual play, capturing the script for later
    replay) the engine has no FState updates of its own, so this is the
    only sane sampling point. }
  if FRecording and (FMem <> nil) then
  begin
    curMask := FMem.ReadHalf($04000130) and $03FF;
    if not FPrevSampled then
    begin
      FPrevSample  := KEYINPUT_RELEASED;
      FPrevSampled := True;
    end;
    diff := curMask xor FPrevSample;
    if diff <> 0 then
    begin
      for bit := 0 to 9 do
      begin
        mask := TWord(1) shl bit;
        if (diff and mask) <> 0 then
        begin
          SetLength(FRecordEvents, FRecordCount + 1);
          ev.Frame := frame;
          ev.Button := bit;
          if (curMask and mask) = 0 then ev.Action := raPress
                                    else ev.Action := raRelease;
          FRecordEvents[FRecordCount] := ev;
          Inc(FRecordCount);
        end;
      end;
      FPrevSample := curMask;
    end;
  end;
end;

procedure TReplayEngine.StartRecording(const path: string);
begin
  FRecording   := True;
  FRecordPath  := path;
  FRecordCount := 0;
  FPrevSampled := False;
  SetLength(FRecordEvents, 0);
  SafeLog(Format('replay: recording to %s', [path]));
end;

function TReplayEngine.FlushRecording: Boolean;
var
  f: Text;
  i: Integer;
  actionStr: string;
begin
  Result := False;
  if not FRecording then Exit;
  if FRecordPath = '' then Exit;

  AssignFile(f, FRecordPath);
  try
    Rewrite(f);
    Writeln(f, '# Pascal-GBA input replay script — recorded session');
    Writeln(f, '# Format: <frame> <press|release> <button>');
    Writeln(f);
    for i := 0 to FRecordCount - 1 do
    begin
      case FRecordEvents[i].Action of
        raPress:   actionStr := 'press';
        raRelease: actionStr := 'release';
      else         actionStr := '?';
      end;
      Writeln(f, Format('%d %s %s',
        [FRecordEvents[i].Frame, actionStr,
         ButtonName(FRecordEvents[i].Button)]));
    end;
    CloseFile(f);
    Result := True;
    SafeLog(Format('replay: wrote %d events to %s',
      [FRecordCount, FRecordPath]));
  except
    on E: Exception do
      SafeLogErr(Format('replay: failed to write %s — %s',
        [FRecordPath, E.Message]));
  end;
end;

end.
