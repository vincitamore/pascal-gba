#!/usr/bin/env python3
"""Text score -> Kit_Audio song data (Pascal include).

Score format (one directive per line, '#' comments):

    song  demo            # identifier stem for the generated arrays
    tempo 140             # quarter-note BPM
    loop  on              # on|off
    lead:  c4:2 e4:2 g4:2 c5:4 r:2 ...
    noise: x:4 r:4 x:4 r:4 ...

Notes are name+octave (c, cs/c#, d, ds/d#, e, f, fs/f#, g, gs/g#, a,
as/a#, b; octaves 3-6), 'r' is a rest. Noise-track hits: 'h' soft hat,
'x' normal (legacy default), 'X'/'!' accent kick. Durations are
sixteenth notes. Multiple lead:/noise: lines concatenate.

Durations are converted to frames (60 fps) with cumulative rounding,
so long songs do not drift from the stated tempo even when a sixteenth
is a non-integer frame count. Events longer than 255 frames are split
(rest continuation).

Usage:
    python tools/song.py score.song [-o out.inc]

The output is a Pascal include: Song<Name>Lead / Song<Name>Noise
TSongEvent arrays plus Song<Name>Loop, ready for Kit_Audio.MusicPlay.
"""

import argparse
import sys
from pathlib import Path

SEMITONE = {'c': 0, 'd': 2, 'e': 4, 'f': 5, 'g': 7, 'a': 9, 'b': 11}
FRAMES_PER_MINUTE = 3600.0  # 60 fps


def parse_note(tok: str, track: str, lineno: int) -> int:
    """Return the Kit_Audio note index (0 = rest; noise accent 1..3)."""
    if tok == 'r':
        return 0
    if tok in ('x', 'X', '!', 'h'):
        if track != 'noise':
            raise SystemExit(f"line {lineno}: '{tok}' is only valid on the noise track")
        # 1=soft, 2=normal (legacy 'x'), 3=accent — Kit_Audio volume ladder
        return {'x': 2, 'X': 3, '!': 3, 'h': 1}[tok]
    if track == 'noise':
        raise SystemExit(
            f"line {lineno}: noise track only takes x/X/!/h and r, got '{tok}'"
        )

    name = tok[:-1]
    octave = tok[-1]
    if not octave.isdigit():
        raise SystemExit(f"line {lineno}: bad note '{tok}' (missing octave)")
    octave = int(octave)
    name = name.replace('#', 's')
    sharp = name.endswith('s') and len(name) > 1
    letter = name[0]
    if letter not in SEMITONE or (len(name) > 1 and not sharp):
        raise SystemExit(f"line {lineno}: bad note '{tok}'")
    semi = SEMITONE[letter] + (1 if sharp else 0)
    index = (octave - 3) * 12 + semi + 1
    if not 1 <= index <= 48:
        raise SystemExit(f"line {lineno}: '{tok}' outside C3..B6")
    return index


def parse_score(path: Path):
    name = None
    tempo = 120.0
    loop = False
    tracks = {'lead': [], 'noise': []}  # list of (note_index, sixteenths, lineno)

    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        if line.startswith('song'):
            name = line.split(None, 1)[1].strip()
        elif line.startswith('tempo'):
            tempo = float(line.split(None, 1)[1])
        elif line.startswith('loop'):
            loop = line.split(None, 1)[1].strip().lower() == 'on'
        elif line.startswith(('lead:', 'noise:')):
            track, body = line.split(':', 1)
            for tok in body.split():
                if ':' not in tok:
                    raise SystemExit(f"line {lineno}: '{tok}' needs note:duration")
                note_s, dur_s = tok.rsplit(':', 1)
                # preserve case for noise accents (x/X/!); lead notes lowercased
                note_key = note_s if track == 'noise' else note_s.lower()
                note = parse_note(note_key, track, lineno)
                dur = int(dur_s)
                if dur < 1:
                    raise SystemExit(f"line {lineno}: duration must be >= 1")
                tracks[track].append((note, dur))
        else:
            raise SystemExit(f"line {lineno}: unrecognized directive '{line}'")

    if not name:
        raise SystemExit("score has no 'song <name>' directive")
    if not name.isidentifier():
        raise SystemExit(f"song name '{name}' is not a valid identifier stem")
    return name, tempo, loop, tracks


def to_frames(events, tempo):
    """(note, sixteenths) -> (note, frames) with cumulative rounding."""
    frames_per_16th = FRAMES_PER_MINUTE / tempo / 4.0
    out = []
    cum = 0.0
    edge = 0
    for note, dur in events:
        cum += dur * frames_per_16th
        frames = round(cum) - edge
        edge = round(cum)
        if frames < 1:
            frames = 1
            edge += 1  # keep the running edge honest
        # split anything past the byte range into rest continuations
        first = True
        while frames > 0:
            chunk = min(frames, 255)
            out.append((note if first else 0, chunk))
            frames -= chunk
            first = False
    return out


def emit_track(name, track_name, events):
    ident = f"Song{name.capitalize()}{track_name.capitalize()}"
    if not events:
        return f"  {ident}Count = 0;\n"
    lines = [f"  {ident}: array[0..{len(events) - 1}] of TSongEvent = ("]
    for i, (note, dur) in enumerate(events):
        sep = ',' if i < len(events) - 1 else ''
        lines.append(f"    (note: {note}; dur: {dur}){sep}")
    lines.append("  );")
    lines.append(f"  {ident}Count = {len(events)};")
    return '\n'.join(lines) + '\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('score', type=Path)
    ap.add_argument('-o', '--out', type=Path, default=None)
    args = ap.parse_args()

    name, tempo, loop, tracks = parse_score(args.score)
    lead = to_frames(tracks['lead'], tempo)
    noise = to_frames(tracks['noise'], tempo)

    out_path = args.out or args.score.with_suffix('.inc')
    cap = name.capitalize()
    parts = [
        f"{{ Generated by tools/song.py from {args.score.name} - regenerate, do not hand-edit. }}\n",
        "const\n",
        emit_track(name, 'lead', lead),
        emit_track(name, 'noise', noise),
        f"  Song{cap}Loop = {'True' if loop else 'False'};\n",
    ]
    out_path.write_text(''.join(parts), newline='\n')
    total_frames = sum(d for _, d in lead)
    print(f"OK: {out_path} lead={len(lead)} noise={len(noise)} "
          f"events, {total_frames} frames/loop (~{total_frames / 60:.1f} s)")


if __name__ == '__main__':
    main()
