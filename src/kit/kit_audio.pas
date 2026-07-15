unit Kit_Audio;
{
  PSG audio driver for cart code: sound effects + a vblank-stepped
  two-track music sequencer.

  Channel plan (no contention by construction):

    ch1 (square + sweep)  sound effects — the sweep unit gives zips
                          and boings for free
    ch2 (square)          music lead
    ch4 (noise)           music percussion

  ch3 (wave) is left untouched for future use.

  Frame shape: call AudioInit once at boot, MusicTick once per frame
  (with InputUpdate/SceneTick). SFX are one-shot — each call retriggers
  ch1 immediately; the hardware envelope decays it, so no per-frame SFX
  upkeep exists.

  Music notes are "plucky": each note retriggers ch2 with a decaying
  envelope, rests simply let it ring out. That keeps song data down to
  (note, duration) pairs — no explicit note-off events. Percussion
  hits retrigger ch4 the same way.

  Song data comes from tools/song.py (text score -> Pascal include);
  see docs/kit.md. Hand-written arrays work identically.

  All registers are written with 16-bit stores. Nothing here touches
  the direct-sound FIFOs or timers.
}

{$mode objfpc}{$H+}

interface

type
  { One sequencer event: note index into NoteFreq (0 = rest; for the
    noise track any nonzero value is a hit), then duration in frames. }
  TSongEvent = packed record
    note: Byte;
    dur:  Byte;
  end;
  PSongEvent = ^TSongEvent;

const
  { Note indices for hand-written song data: 1 = C3 ... 48 = B6,
    chromatic. tools/song.py emits these from note names. }
  NOTE_REST = 0;

procedure AudioInit;

{ ── Sound effects (ch1) ── }

{ Raw voice: sweep/env/freq are the three ch1 register values
  (SOUND1CNT_L / _H / _X payloads; the trigger bit is added here). }
procedure SfxPlay(sweep, env, freq: Word);

{ Canned vocabulary — shared across games so sounds transfer like the
  control verbs do. Voiced for a bright, soft register: no buzzers. }
procedure SfxTap;       { neutral confirm blip }
procedure SfxGrab;      { rising zip — pick something up }
procedure SfxDrop;      { falling zip — put something down }
procedure SfxPop;       { short high pop }
procedure SfxBoing;     { comedic soft-fail bounce }
procedure SfxSparkle;   { high shimmer — reward tick }
procedure SfxCrunch;    { two-stage noise bite — eating, impacts. Rides
                          ch4 (second stage fires via MusicTick), so it
                          replaces one percussion tick when music plays }
procedure SfxSizzle;    { soft long frying hiss on ch4 }

{ ── Music sequencer (ch2 lead + ch4 noise) ── }

procedure MusicPlay(lead: PSongEvent; leadCount: Integer;
                    noise: PSongEvent; noiseCount: Integer;
                    doLoop: Boolean);
procedure MusicStop;
procedure MusicTick;                 { once per frame }
function  MusicPlaying: Boolean;

implementation

const
  REG_SOUNDCNT_L  = $04000080;
  REG_SOUNDCNT_H  = $04000082;
  REG_SOUNDCNT_X  = $04000084;

  REG_SOUND1CNT_L = $04000060;
  REG_SOUND1CNT_H = $04000062;
  REG_SOUND1CNT_X = $04000064;

  REG_SOUND2CNT_L = $04000068;
  REG_SOUND2CNT_H = $0400006C;

  REG_SOUND4CNT_L = $04000078;
  REG_SOUND4CNT_H = $0400007C;

  { Square frequency register values, chromatic C3..B6 (index 1..48).
    n = 2048 - 131072/f, equal temperament, A4 = 440. }
  NoteFreq: array[1..48] of Word = (
    1046, 1102, 1155, 1205, 1253, 1297,
    1339, 1379, 1417, 1452, 1486, 1517,
    1547, 1575, 1602, 1627, 1650, 1673,
    1694, 1714, 1732, 1750, 1767, 1783,
    1798, 1812, 1825, 1837, 1849, 1860,
    1871, 1881, 1890, 1899, 1907, 1915,
    1923, 1930, 1936, 1943, 1949, 1954,
    1959, 1964, 1969, 1974, 1978, 1982
  );

  { Lead voice: initial volume 12, decreasing, step 3 (~0.56 s ring),
    50% duty — bright but soft. }
  LEAD_ENV = $C380;

  { Noise hit: volume 10, decreasing, step 1 (short), divider tuned
    for a hat-ish tick. }
  NOISE_ENV = $A100;
  NOISE_POLY = $8034;

var
  mLead:       PSongEvent = nil;
  mLeadCount:  Integer = 0;
  mNoise:      PSongEvent = nil;
  mNoiseCount: Integer = 0;
  mLoop:       Boolean = False;
  mPlaying:    Boolean = False;
  crunchDelay: Integer = 0;

  mLeadIdx, mNoiseIdx:     Integer;
  mLeadWait, mNoiseWait:   Integer;

procedure AudioInit;
begin
  PWord(REG_SOUNDCNT_X)^ := $0080;   { master enable }
  { Route ch1 + ch2 + ch4 to both sides, master volume 7/7. }
  PWord(REG_SOUNDCNT_L)^ := $BB77;
  PWord(REG_SOUNDCNT_H)^ := $0002;   { PSG mix 100% }
end;

{ ── SFX ── }

procedure SfxPlay(sweep, env, freq: Word);
begin
  PWord(REG_SOUND1CNT_L)^ := sweep;
  PWord(REG_SOUND1CNT_H)^ := env;
  PWord(REG_SOUND1CNT_X)^ := $8000 or (freq and $07FF);
end;

procedure SfxTap;
begin
  { A5, quick decay, no sweep. }
  SfxPlay($0000, $A180, 1899);
end;

procedure SfxGrab;
begin
  { Rising zip from E4. Upward sweeps need a gentle step: the sweep
    unit adds X>>shift to the frequency value each tick and DISABLES
    the channel the moment it would pass 2047 — an aggressive shift
    kills the voice in a few milliseconds. time 3, up, shift 6. }
  SfxPlay($0036, $A380, 1650);
end;

procedure SfxDrop;
begin
  { Sweep down from G5: time 2, decrease, shift 3. }
  SfxPlay($002B, $A280, 1881);
end;

procedure SfxPop;
begin
  { E6, quick. }
  SfxPlay($0000, $A180, 1949);
end;

procedure SfxBoing;
begin
  { Sweep down from C4, slower — a soft comedic drop. }
  SfxPlay($0035, $B380, 1547);
end;

procedure SfxSparkle;
begin
  { B6 ping — no sweep (any upward step overflows this close to the
    register ceiling and mutes the channel, see SfxGrab). }
  SfxPlay($0000, $9280, 1982);
end;

procedure SfxCrunch;
begin
  { Two-stage bite on ch4: a deep 15-bit "cr-" burst now, and MusicTick
    fires the snappier 7-bit "-unch" a few frames later. One register
    poke alone reads as a hat tick, not eating. }
  PWord(REG_SOUND4CNT_L)^ := $C200;            { vol 12, decay step 2 }
  PWord(REG_SOUND4CNT_H)^ := $8054;            { shift 5, 15-bit, ratio 4 }
  crunchDelay := 5;
end;

procedure SfxSizzle;
begin
  { Gentle high hiss with a long decay: 15-bit width, fast clock,
    modest volume — reads as frying, not percussion. }
  PWord(REG_SOUND4CNT_L)^ := $7400;            { vol 7, decay step 4 }
  PWord(REG_SOUND4CNT_H)^ := $8010;            { shift 1, 15-bit }
end;

{ ── Music ── }

procedure TriggerLead(note: Byte);
begin
  if (note = NOTE_REST) or (note > 48) then Exit;
  PWord(REG_SOUND2CNT_L)^ := LEAD_ENV;
  PWord(REG_SOUND2CNT_H)^ := $8000 or NoteFreq[note];
end;

procedure TriggerNoise(note: Byte);
begin
  if note = NOTE_REST then Exit;
  PWord(REG_SOUND4CNT_L)^ := NOISE_ENV;
  PWord(REG_SOUND4CNT_H)^ := NOISE_POLY;
end;

procedure MusicPlay(lead: PSongEvent; leadCount: Integer;
                    noise: PSongEvent; noiseCount: Integer;
                    doLoop: Boolean);
begin
  mLead       := lead;
  mLeadCount  := leadCount;
  mNoise      := noise;
  mNoiseCount := noiseCount;
  mLoop       := doLoop;
  mLeadIdx    := -1;
  mNoiseIdx   := -1;
  mLeadWait   := 0;
  mNoiseWait  := 0;
  mPlaying    := (leadCount > 0) or (noiseCount > 0);
end;

procedure MusicStop;
begin
  mPlaying := False;
  { Let current notes decay naturally — no hard cut. }
end;

function MusicPlaying: Boolean;
begin
  Result := mPlaying;
end;

procedure MusicTick;
var
  ev: PSongEvent;
  trackDone: Boolean;
begin
  { Crunch second stage runs with or without music. }
  if crunchDelay > 0 then
  begin
    Dec(crunchDelay);
    if crunchDelay = 0 then
    begin
      PWord(REG_SOUND4CNT_L)^ := $9100;        { vol 9, faster decay }
      PWord(REG_SOUND4CNT_H)^ := $803C;        { shift 3, 7-bit: the snap }
    end;
  end;

  if not mPlaying then Exit;
  trackDone := False;

  { Lead track. }
  if (mLead <> nil) and (mLeadCount > 0) then
  begin
    Dec(mLeadWait);
    if mLeadWait <= 0 then
    begin
      Inc(mLeadIdx);
      if mLeadIdx >= mLeadCount then
      begin
        if mLoop then mLeadIdx := 0 else trackDone := True;
      end;
      if not trackDone then
      begin
        ev := mLead;
        Inc(ev, mLeadIdx);
        TriggerLead(ev^.note);
        mLeadWait := ev^.dur;
        if mLeadWait < 1 then mLeadWait := 1;
      end;
    end;
  end;

  { Noise track. }
  if (mNoise <> nil) and (mNoiseCount > 0) and not trackDone then
  begin
    Dec(mNoiseWait);
    if mNoiseWait <= 0 then
    begin
      Inc(mNoiseIdx);
      if mNoiseIdx >= mNoiseCount then
      begin
        if mLoop then mNoiseIdx := 0
        else
        begin
          mNoiseIdx := mNoiseCount;   { park at end }
          mNoiseWait := 30000;
        end;
      end;
      if mNoiseIdx < mNoiseCount then
      begin
        ev := mNoise;
        Inc(ev, mNoiseIdx);
        TriggerNoise(ev^.note);
        mNoiseWait := ev^.dur;
        if mNoiseWait < 1 then mNoiseWait := 1;
      end;
    end;
  end;

  if trackDone then
    mPlaying := False;
end;

end.
