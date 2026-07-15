program dbg_smoke;
{
  Game-side DbgLog end-to-end smoke: 10 static-string messages + 2
  level-tagged messages. Avoids FPC's broken numeric-formatting RTL
  paths (Str / IntToStr / Format all crash on -Tgba; even SetLength +
  manual char-write produces truncated ansistrings on this target).

  Build:  .\build-gba.ps1 test\dbg_smoke
  Run:    .\bin\gbarun.exe --rom test\dbg_smoke.gba --headless --frames 600
}

{$mode objfpc}{$H+}

uses
  Gba_Dbg;

begin
  DbgLogStr('dbg_smoke msg  1 of 10');  DbgLogWaitConsumed;
  DbgLogStr('dbg_smoke msg  2 of 10');  DbgLogWaitConsumed;
  DbgLogStr('dbg_smoke msg  3 of 10');  DbgLogWaitConsumed;
  DbgLogStr('dbg_smoke msg  4 of 10');  DbgLogWaitConsumed;
  DbgLogStr('dbg_smoke msg  5 of 10');  DbgLogWaitConsumed;
  DbgLogStr('dbg_smoke msg  6 of 10');  DbgLogWaitConsumed;
  DbgLogStr('dbg_smoke msg  7 of 10');  DbgLogWaitConsumed;
  DbgLogStr('dbg_smoke msg  8 of 10');  DbgLogWaitConsumed;
  DbgLogStr('dbg_smoke msg  9 of 10');  DbgLogWaitConsumed;
  DbgLogStr('dbg_smoke msg 10 of 10');  DbgLogWaitConsumed;

  DbgLogLevel(DBG_WARN,  'dbg_smoke: warn-level marker', []);
  DbgLogWaitConsumed;
  DbgLogLevel(DBG_ERROR, 'dbg_smoke: error-level marker', []);
  DbgLogWaitConsumed;

  while True do ;
end.
