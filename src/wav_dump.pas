unit Wav_Dump;
{
  Tiny WAV writer for emulator-output validation. Writes stereo S16 PCM
  at a given sample rate. Header is patched at Close() once total size
  is known.

  Usage:
    var w: TWavWriter;
    w := TWavWriter.Create('out.wav', 44100);
    w.WriteSamples(@buf[0], 735);   { 735 stereo S16 samples }
    ...
    w.Free;

  Use case: dump APU output alongside live audio so we can inspect the
  waveform in Audacity, run spectrograms, compare against mGBA's
  recorded WAV.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, GbaTypes, Apu;

type
  TWavWriter = class
  private
    FStream:    TFileStream;
    FSampleRate: Integer;
    FFramesWritten: Int64;
    procedure WriteHeaderPlaceholder;
    procedure PatchHeader;
  public
    constructor Create(const path: string; sampleRate: Integer);
    destructor  Destroy; override;

    { Append `count` stereo S16 samples to the file. }
    procedure WriteSamples(const buf: TSampleBuffer; count: Integer);
  end;

implementation

constructor TWavWriter.Create(const path: string; sampleRate: Integer);
begin
  inherited Create;
  FStream := TFileStream.Create(path, fmCreate);
  FSampleRate := sampleRate;
  FFramesWritten := 0;
  WriteHeaderPlaceholder;
end;

destructor TWavWriter.Destroy;
begin
  if Assigned(FStream) then
  begin
    PatchHeader;
    FStream.Free;
  end;
  inherited Destroy;
end;

procedure TWavWriter.WriteHeaderPlaceholder;
{ 44-byte WAVE header (RIFF + fmt + data subchunk headers). Lengths
  are placeholders; PatchHeader fills them in once we know the total
  data size. }
var
  h: array[0..43] of Byte;
begin
  FillChar(h, SizeOf(h), 0);
  { "RIFF" }
  h[0] := Ord('R'); h[1] := Ord('I'); h[2] := Ord('F'); h[3] := Ord('F');
  { ChunkSize placeholder at 4..7 }
  { "WAVE" }
  h[8]  := Ord('W'); h[9]  := Ord('A'); h[10] := Ord('V'); h[11] := Ord('E');
  { "fmt " }
  h[12] := Ord('f'); h[13] := Ord('m'); h[14] := Ord('t'); h[15] := Ord(' ');
  { Subchunk1Size = 16 (PCM) }
  h[16] := 16;
  { AudioFormat = 1 (PCM) }
  h[20] := 1;
  { NumChannels = 2 }
  h[22] := 2;
  { SampleRate (little-endian) }
  h[24] := FSampleRate and $FF;
  h[25] := (FSampleRate shr 8) and $FF;
  h[26] := (FSampleRate shr 16) and $FF;
  h[27] := (FSampleRate shr 24) and $FF;
  { ByteRate = SampleRate * NumChannels * BitsPerSample/8 = SampleRate * 4 }
  h[28] := (FSampleRate * 4) and $FF;
  h[29] := ((FSampleRate * 4) shr 8) and $FF;
  h[30] := ((FSampleRate * 4) shr 16) and $FF;
  h[31] := ((FSampleRate * 4) shr 24) and $FF;
  { BlockAlign = 4 }
  h[32] := 4;
  { BitsPerSample = 16 }
  h[34] := 16;
  { "data" }
  h[36] := Ord('d'); h[37] := Ord('a'); h[38] := Ord('t'); h[39] := Ord('a');
  { Subchunk2Size placeholder at 40..43 }

  FStream.WriteBuffer(h, SizeOf(h));
end;

procedure TWavWriter.PatchHeader;
var
  dataSize, chunkSize: Int64;
  bytes: array[0..3] of Byte;
begin
  dataSize := FFramesWritten * 4;     { 4 bytes per stereo S16 frame }
  chunkSize := 36 + dataSize;

  { Patch ChunkSize at offset 4 }
  FStream.Position := 4;
  bytes[0] := chunkSize and $FF;
  bytes[1] := (chunkSize shr 8) and $FF;
  bytes[2] := (chunkSize shr 16) and $FF;
  bytes[3] := (chunkSize shr 24) and $FF;
  FStream.WriteBuffer(bytes, 4);

  { Patch Subchunk2Size at offset 40 }
  FStream.Position := 40;
  bytes[0] := dataSize and $FF;
  bytes[1] := (dataSize shr 8) and $FF;
  bytes[2] := (dataSize shr 16) and $FF;
  bytes[3] := (dataSize shr 24) and $FF;
  FStream.WriteBuffer(bytes, 4);

  FStream.Position := FStream.Size;
end;

procedure TWavWriter.WriteSamples(const buf: TSampleBuffer; count: Integer);
begin
  if count <= 0 then Exit;
  FStream.WriteBuffer(buf[0], count * SizeOf(TStereoSample));
  Inc(FFramesWritten, count);
end;

end.
