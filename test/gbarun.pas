program gbarun;
{
  Run a GBA ROM through the full pipeline. Thin wrapper around
  `gba_runner.pas`'s RunGba — body lives there so the Lazarus app
  shell can drive the same emulator without duplicating the harness.

  Usage:
    gbarun.exe [--rom <path>] [--bios <path>] [--frames N]
               [--dump-audio <path>] [--poke <hex addr> <hex val>]
               [--headless] [--scale N] [--screenshot <path>] [--screenshot-frame N]
               [--replay <path>] [--record <path>]

  Defaults:
    ROM    = test\dbg_smoke.gba                      (relative)
    BIOS   = bios\gba_bios.bin                       (relative)
    Frames = 600  (10 s @ 60 FPS — short bound so test scripts time-box)

  Path resolution: relative paths are tried CWD-relative first, then
  EXE-relative (walking up from bin/ to the project root if needed). So
  running from either project root or a subfolder Just Works without a
  `cd`.

  For interactive use (e.g. reproducing a runtime crash), pass
  `--frames 0` to disable the timeout and the window will stay open
  until you close it or it crashes.

  Headless dev-harness mode:
    --headless              suppress the Win32 window + waveOut output.
                            CPU/PPU/APU still run; audio samples still
                            generate so APU state stays accurate. Pairs
                            with --screenshot for agent-driven scenarios.
    --screenshot <path>     write the framebuffer as PNG when capture
                            triggers (default: end of run).
    --screenshot-frame <N>  capture at the END of frame N rather than
                            end of run. 1-indexed.
    --replay <path>         load a scripted input replay file (see
                            src/replay.pas docstring for format) and
                            drive KEYINPUT from it each frame. Fatal
                            on parse error (exit 1).
    --record <path>         capture all keypad state changes during
                            the run and write a replay script on exit.
                            Can combine with --replay (records the
                            scripted run too — useful for tee-and-diff).

  Exit codes:
    0  clean (MaxFrames hit, or window closed in windowed mode)
    1  ROM / BIOS path missing or load failed
    2  unmapped memory access flood (>10K reads+writes)
    3  CPU halted with no IRQ progress for 120 frames

  Esc closes the window (windowed mode only).
}

{$mode objfpc}{$H+}

uses
  SysUtils, GbaTypes, Gba_Runner;

function ResolvePath(const relPath: string): string;
{ Try CWD-relative first (matches old behavior + test scripts that cd
  to the project root before invoking). If that file doesn't exist, try
  EXE-relative. If EXE is in bin/, also try EXE-parent-relative — that
  catches the natural 'launch bin\gbarun.exe from project root' case
  AND the 'cd into bin/ and launch' case. Returns whatever path actually
  points at an existing file, or the CWD-relative form for the error path. }
var
  cwdRel, exeRel, exeParentRel: string;
begin
  cwdRel := relPath;
  if FileExists(cwdRel) then Exit(cwdRel);

  exeRel := ExtractFilePath(ParamStr(0)) + relPath;
  if FileExists(exeRel) then Exit(exeRel);

  exeParentRel := ExtractFilePath(ExcludeTrailingPathDelimiter(
                    ExtractFilePath(ParamStr(0)))) + relPath;
  if FileExists(exeParentRel) then Exit(exeParentRel);

  Result := cwdRel;  { caller will surface the not-found error }
end;

var
  opts: TGbaRunOptions;
  i: Integer;
begin
  opts := DefaultRunOptions;
  opts.RomPath      := ResolvePath('test\dbg_smoke.gba');
  opts.BiosPath     := ResolvePath('bios\gba_bios.bin');
  opts.WindowTitle  := 'Pascal GBA';
  opts.Verbose      := True;
  opts.PrintSummary := True;
  opts.MaxFrames    := 600;       { 10 s @ 60 FPS — matches prior boot acceptance bound }

  i := 1;
  while i <= ParamCount do
  begin
    if (ParamStr(i) = '--dump-audio') and (i < ParamCount) then
    begin
      opts.DumpAudioPath := ParamStr(i + 1);
      Inc(i, 2);
    end
    else if (ParamStr(i) = '--rom') and (i < ParamCount) then
    begin
      opts.RomPath := ResolvePath(ParamStr(i + 1));
      opts.WindowTitle := 'Pascal GBA - ' + ExtractFileName(opts.RomPath);
      Inc(i, 2);
    end
    else if (ParamStr(i) = '--bios') and (i < ParamCount) then
    begin
      opts.BiosPath := ResolvePath(ParamStr(i + 1));
      Inc(i, 2);
    end
    else if (ParamStr(i) = '--frames') and (i < ParamCount) then
    begin
      opts.MaxFrames := StrToIntDef(ParamStr(i + 1), 600);
      Inc(i, 2);
    end
    else if (ParamStr(i) = '--poke') and (i < ParamCount - 1) then
    begin
      opts.DebugPokeAddr := TWord(StrToIntDef('$' + ParamStr(i + 1), 0));
      opts.DebugPokeByte := TByte(StrToIntDef('$' + ParamStr(i + 2), 0));
      Inc(i, 3);
    end
    else if (ParamStr(i) = '--headless') then
    begin
      opts.Headless := True;
      Inc(i);
    end
    else if (ParamStr(i) = '--scale') and (i < ParamCount) then
    begin
      opts.WindowScale := StrToIntDef(ParamStr(i + 1), 3);
      if opts.WindowScale < 1 then opts.WindowScale := 1;
      if opts.WindowScale > 8 then opts.WindowScale := 8;
      Inc(i, 2);
    end
    else if (ParamStr(i) = '--screenshot') and (i < ParamCount) then
    begin
      opts.ScreenshotPath := ParamStr(i + 1);
      Inc(i, 2);
    end
    else if (ParamStr(i) = '--screenshot-frame') and (i < ParamCount) then
    begin
      opts.ScreenshotFrame := StrToIntDef(ParamStr(i + 1), 0);
      Inc(i, 2);
    end
    else if (ParamStr(i) = '--replay') and (i < ParamCount) then
    begin
      opts.ReplayPath := ResolvePath(ParamStr(i + 1));
      Inc(i, 2);
    end
    else if (ParamStr(i) = '--record') and (i < ParamCount) then
    begin
      opts.RecordPath := ParamStr(i + 1);   { record path doesn't need to exist yet }
      Inc(i, 2);
    end
    else if (ParamStr(i) = '--dbglog-out') and (i < ParamCount) then
    begin
      opts.DbglogOutPath := ParamStr(i + 1);
      Inc(i, 2);
    end
    else
      Inc(i);
  end;

  RunGba(opts);
end.
