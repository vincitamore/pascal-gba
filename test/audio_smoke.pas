program audio_smoke;
{
  APU + audio smoke test. Programs PSG channel 1 to play a 440 Hz square
  wave for 2 seconds. Verifies the entire audio pipeline (APU register
  poll → channel state → mixer → waveOut buffer rotation) end-to-end
  without the rest of the emulator.

  Build: fpc -Mobjfpc -Sh -Fusrc -FEbin -FUbin test/audio_smoke.pas
  Run:   ./bin/audio_smoke   (should hear a 440 Hz tone for 2 seconds)
}

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, GbaTypes, Memory, Apu, Audio, Wav_Dump;

const
  TONE_FREQ_HZ = 440;
  DURATION_SEC = 2;

var
  mem: TGbaMemory;
  gapu: TGbaApu;
  aud: TGbaAudio;
  wav: TWavWriter;
  buf: TSampleBuffer;
  frame, i: Integer;
  freqDiv: TWord;
  wavPath: string;

begin
  Writeln('audio_smoke: programming PSG ch1 for ', TONE_FREQ_HZ, ' Hz square, ', DURATION_SEC, 's');

  { Optional --dump-audio <path> flag. }
  wavPath := '';
  i := 1;
  while i <= ParamCount do
  begin
    if (ParamStr(i) = '--dump-audio') and (i < ParamCount) then
    begin
      wavPath := ParamStr(i + 1);
      Inc(i, 2);
    end
    else
      Inc(i);
  end;
  if wavPath <> '' then Writeln(Format('  audio dump → %s', [wavPath]));

  mem := TGbaMemory.Create;
  gapu := TGbaApu.Create(mem);
  aud := TGbaAudio.Create;
  if wavPath <> '' then wav := TWavWriter.Create(wavPath, AUDIO_SAMPLE_RATE)
                   else wav := nil;
  try
    if not aud.IsOpen then
    begin
      Writeln(StdErr, 'Audio not opened — exiting.');
      Halt(1);
    end;

    { Master sound on. Bit 7 of SOUNDCNT_X = master enable. }
    mem.WriteHalf($04000084, $0080);

    { Per-PSG master volume + L/R enable. Volume L/R = 7 (max).
      Channel-enable bits 8..11 = ch1..ch4 left; 12..15 = right. Enable
      ch1 in both. }
    mem.WriteHalf($04000080, $1177);

    { No FIFO mixing — PSG-only. }
    mem.WriteHalf($04000082, $0000);

    { Channel 1 sweep off. }
    mem.WriteHalf($04000060, $0000);

    { Channel 1 duty/length/envelope:
        duty=50%   → bits 6:7 = 10
        envInit=15 → bits 12:15 = 1111
        envDir=0 (decrease)
        envPeriod=0 (no auto-decrease) }
    mem.WriteHalf($04000062, ($2 shl 6) or ($F shl 12));

    { Frequency: freqDiv = 2048 - 131072/TONE_FREQ_HZ }
    freqDiv := 2048 - (131072 div TONE_FREQ_HZ);
    Writeln('  freqDiv = ', freqDiv, ' ($', IntToHex(freqDiv, 4), ')');

    { Channel 1 freq + control: freqDiv low 11 bits, length-enable off,
      trigger bit 15. }
    mem.WriteHalf($04000064, freqDiv or $8000);

    SetLength(buf, SAMPLES_PER_FRAME);
    for frame := 0 to (DURATION_SEC * 60) - 1 do
    begin
      gapu.GenerateSamples(SAMPLES_PER_FRAME, buf);
      aud.Submit(buf, SAMPLES_PER_FRAME);
      if wav <> nil then wav.WriteSamples(buf, SAMPLES_PER_FRAME);
    end;

    Writeln('Done. Drained ', DURATION_SEC * 60, ' frames.');
  finally
    if wav <> nil then wav.Free;
    aud.Free; gapu.Free; mem.Free;
  end;
end.
