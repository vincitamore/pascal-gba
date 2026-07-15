program fpsprobe;
{
  Shell-context FPS probe. Runs the emulator in-process inside an LCL
  application the way gbashell does, but self-terminating and console-
  hosted so the runner's end-of-run FPS line lands on stdout.

    fpsprobe <rom.gba> [--no-form]

  --no-form skips the launcher-like form, isolating LCL widgetset
  initialization from live-form message traffic (the emulator's message
  pump drains the whole thread queue, so a live form's messages pass
  through it). Compare against standalone gbarun on the same ROM to
  quantify any in-process penalty:

    .\bin\gbarun.exe --rom <rom> --frames 600          # baseline
    .\shell\fpsprobe.exe <rom>                         # LCL + form
    .\shell\fpsprobe.exe <rom> --no-form               # LCL only
}

{$mode objfpc}{$H+}

uses
  Interfaces, Forms, Controls, Classes, SysUtils, Gba_Runner;

var
  f: TForm;
  opts: TGbaRunOptions;
  withForm: Boolean;

begin
  if ParamCount < 1 then
  begin
    Writeln('usage: fpsprobe <rom.gba> [--no-form]');
    Halt(2);
  end;
  withForm := not ((ParamCount >= 2) and (ParamStr(2) = '--no-form'));

  Application.Initialize;
  f := nil;
  if withForm then
  begin
    f := TForm.CreateNew(nil);
    f.Width  := 540;
    f.Height := 670;
    f.Show;
    Application.ProcessMessages;
  end;

  opts := DefaultRunOptions;
  opts.RomPath      := ParamStr(1);
  opts.BiosPath     := 'bios\gba_bios.bin';
  opts.WindowTitle  := 'fpsprobe';
  opts.MaxFrames    := 600;
  opts.Verbose      := False;
  opts.PrintSummary := False;

  RunGba(opts);

  if f <> nil then f.Free;
end.
