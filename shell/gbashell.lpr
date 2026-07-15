program gbashell;
{
  Pascal GBA emulator launcher. Lazarus + LCL shell that pops a ROM
  picker and drives the shared `Gba_Runner` unit - run any ROM without
  touching the command line.

  Build (requires Lazarus; lazbuild ships with it):
    lazbuild shell\gbashell.lpi
  Or from this directory:
    lazbuild gbashell.lpi

  Run: shell\gbashell.exe (from the repository root, so the bundled
  BIOS at bios\gba_bios.bin resolves; the launcher also probes
  relative to its own directory).
}

{$mode objfpc}{$H+}

uses
  Interfaces,
  Forms,
  MainForm,
  Gba_Runner;

{$R *.res}

begin
  Application.Title := 'Pascal GBA';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TGbaShellForm, GbaShellForm);
  Application.Run;
end.
