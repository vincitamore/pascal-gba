unit Audio;
{
  Win32 waveOut wrapper for the GBA emulator's audio output.

  ── Pipeline ──

  The APU produces TStereoSample (S16 L/R) at 32.768 kHz (GBA native
  internal mixing rate). We accumulate one frame's worth (~546 samples,
  60 fps) and submit to waveOut via a rotating set of NUM_BUFFERS
  prepared headers. waveOut signals completion through WHDR_DONE plus
  a CALLBACK_EVENT; Submit blocks on the event until the target slot
  frees, which makes the audio device the master clock of the whole
  windowed main loop. Windows handles resampling to the device rate
  via WASAPI shared-mode polyphase filter.

  ── Latency budget ──

  NUM_BUFFERS * (SAMPLES_PER_FRAME / 32768) = 4 * 16.7 ms = ~67 ms.
  That's the worst-case audio latency. For commercial GBA-emulator
  feel, anything under 100 ms is acceptable.

  ── Single-threaded by design ──

  All submission happens from the main thread between frames; the
  completion event is the only kernel object involved. No locks, no
  callbacks-from-other-thread. The main game loop owns audio
  submission cadence.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Windows, MMSystem, GbaTypes, Apu;

const
  { GBA native internal mixing rate. Windows WASAPI resamples to device
    rate with high-quality polyphase filtering — exactly how mGBA + NBA
    handle output via SDL/Qt audio sinks. }
  AUDIO_SAMPLE_RATE = 32768;
  AUDIO_CHANNELS    = 2;
  NUM_BUFFERS       = 4;
  BUFFER_SAMPLES    = AUDIO_SAMPLE_RATE div 60;     { 546 stereo samples per buffer }

type
  TGbaAudio = class
  private
    FHWave: HWAVEOUT;
    FDoneEvent: THandle;   { CALLBACK_EVENT: signaled per buffer completion }
    FWaveHeaders: array[0 .. NUM_BUFFERS - 1] of TWaveHdr;
    FBuffers:     array[0 .. NUM_BUFFERS - 1] of array of TStereoSample;
    FCurrent: Integer;
    FOpened: Boolean;

  public
    constructor Create;
    destructor  Destroy; override;

    { Submit a buffer of stereo samples. Blocks briefly if the next
      slot hasn't drained yet. Pass the same TSampleBuffer returned
      from TGbaApu.GenerateSamples. }
    procedure Submit(const samples: TSampleBuffer; count: Integer);

    function  IsOpen: Boolean;
  public
    { End-of-run diagnostics (reported by the runner): submit count,
      wait iterations inside Submit, wedge-skips. }
    SubmitCount, SubmitWaitCount, SubmitWedgeCount: Int64;
  end;

implementation

constructor TGbaAudio.Create;
var
  fmt: TWaveFormatEx;
  res: MMRESULT;
  i: Integer;
begin
  inherited Create;
  FOpened := False;
  FCurrent := 0;

  FillChar(fmt, SizeOf(fmt), 0);
  fmt.wFormatTag      := WAVE_FORMAT_PCM;
  fmt.nChannels       := AUDIO_CHANNELS;
  fmt.nSamplesPerSec  := AUDIO_SAMPLE_RATE;
  fmt.wBitsPerSample  := 16;
  fmt.nBlockAlign     := AUDIO_CHANNELS * 2;
  fmt.nAvgBytesPerSec := AUDIO_SAMPLE_RATE * AUDIO_CHANNELS * 2;
  fmt.cbSize          := 0;

  { Event-driven completion: the poll-with-Sleep(1) wait this replaces
    detected buffer completion 1-2 ms late every frame, which gated the
    whole (audio-clocked) main loop at ~54-58 FPS instead of 60 -
    audible as a tempo drag. }
  FDoneEvent := CreateEvent(nil, False, False, nil);
  res := waveOutOpen(@FHWave, WAVE_MAPPER, @fmt, FDoneEvent, 0, CALLBACK_EVENT);
  if res <> MMSYSERR_NOERROR then
  begin
    SafeLogErr(Format('Audio: waveOutOpen failed with code %d — emulator will run silently.', [res]));
    Exit;
  end;
  FOpened := True;

  for i := 0 to NUM_BUFFERS - 1 do
  begin
    SetLength(FBuffers[i], BUFFER_SAMPLES);
    FillChar(FBuffers[i][0], BUFFER_SAMPLES * SizeOf(TStereoSample), 0);
    FillChar(FWaveHeaders[i], SizeOf(TWaveHdr), 0);
    FWaveHeaders[i].lpData          := PChar(@FBuffers[i][0]);
    FWaveHeaders[i].dwBufferLength  := BUFFER_SAMPLES * SizeOf(TStereoSample);
    FWaveHeaders[i].dwFlags         := 0;
    waveOutPrepareHeader(FHWave, @FWaveHeaders[i], SizeOf(TWaveHdr));
    { Mark as already-completed so the first Submit can populate them. }
    FWaveHeaders[i].dwFlags := FWaveHeaders[i].dwFlags or WHDR_DONE;
  end;
end;

destructor TGbaAudio.Destroy;
var
  i: Integer;
begin
  if FOpened then
  begin
    { Wait for outstanding buffers to drain. }
    for i := 0 to NUM_BUFFERS - 1 do
      while (FWaveHeaders[i].dwFlags and WHDR_DONE) = 0 do
        WaitForSingleObject(FDoneEvent, 10);
    for i := 0 to NUM_BUFFERS - 1 do
      waveOutUnprepareHeader(FHWave, @FWaveHeaders[i], SizeOf(TWaveHdr));
    waveOutClose(FHWave);
    CloseHandle(FDoneEvent);
  end;
  inherited Destroy;
end;

procedure TGbaAudio.Submit(const samples: TSampleBuffer; count: Integer);
var
  toCopy, spinMs: Integer;
var
  i, queued: Integer;
begin
  if not FOpened then Exit;

  { Wait for the current buffer slot to free up (WHDR_DONE set means
    waveOut has finished playing it OR we marked it done initially). }
  Inc(SubmitCount);
  spinMs := 0;
  while (FWaveHeaders[FCurrent].dwFlags and WHDR_DONE) = 0 do
  begin
    WaitForSingleObject(FDoneEvent, 1);
    Inc(spinMs); Inc(SubmitWaitCount);
    if spinMs > 200 then begin Inc(SubmitWedgeCount); Exit; end;      { audio is wedged; skip frame to avoid hang }
  end;

  { Drained-queue guard. The producer is gated by this wait, so once a
    stall (a slow boot, a debug pause) drains the queue COMPLETELY it
    can never rebuild depth on its own, and the stopped stream then
    pays the device's start/stop penalty on every single buffer
    (measured on this machine as 16.7 -> 20.0 ms per frame - a 50 FPS
    lock with an audible tempo drop on one title whose boot stalls
    long enough to drain; another that never drains held 60). Only a
    TRUE drain (zero queued: the stream has stopped) gets re-primed
    with two silence buffers - a normally-shallow queue is the healthy
    steady state here and padding it just steals slots. }
  queued := 0;
  for i := 0 to NUM_BUFFERS - 1 do
    if (FWaveHeaders[i].dwFlags and WHDR_DONE) = 0 then Inc(queued);
  if queued = 0 then
    while queued < 2 do
    begin
      FillChar(FBuffers[FCurrent][0], BUFFER_SAMPLES * SizeOf(TStereoSample), 0);
      FWaveHeaders[FCurrent].dwFlags := FWaveHeaders[FCurrent].dwFlags and not WHDR_DONE;
      waveOutWrite(FHWave, @FWaveHeaders[FCurrent], SizeOf(TWaveHdr));
      FCurrent := (FCurrent + 1) mod NUM_BUFFERS;
      Inc(queued);
    end;

  { Copy samples into the buffer. Truncate or zero-pad to BUFFER_SAMPLES. }
  if count > BUFFER_SAMPLES then toCopy := BUFFER_SAMPLES else toCopy := count;
  if toCopy > 0 then
    Move(samples[0], FBuffers[FCurrent][0], toCopy * SizeOf(TStereoSample));
  if toCopy < BUFFER_SAMPLES then
    FillChar(FBuffers[FCurrent][toCopy], (BUFFER_SAMPLES - toCopy) * SizeOf(TStereoSample), 0);

  FWaveHeaders[FCurrent].dwFlags := FWaveHeaders[FCurrent].dwFlags and not WHDR_DONE;
  waveOutWrite(FHWave, @FWaveHeaders[FCurrent], SizeOf(TWaveHdr));

  FCurrent := (FCurrent + 1) mod NUM_BUFFERS;
end;

function TGbaAudio.IsOpen: Boolean;
begin
  Result := FOpened;
end;

end.
