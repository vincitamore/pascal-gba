#!/usr/bin/env python3
"""
Inspect specific time windows of a WAV file at sample-level detail.
Print raw S16 values, look for patterns the summary stats miss:
- Stuck values (same sample repeated)
- Step patterns (zero-order-hold artifacts)
- Sample-and-hold jumps
- Wrap-around discontinuities
- Frequency content of small windows

Usage:
    python sample_inspect.py <wav> [start_sec] [duration_sec]

Default: inspect 0.1 sec starting at second 5 (where the test tone is active).
"""

import sys
import wave
import numpy as np
from scipy.fft import rfft, rfftfreq


def load(path):
    with wave.open(path, 'rb') as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        raw = w.readframes(w.getnframes())
    samples = np.frombuffer(raw, dtype=np.int16).reshape(-1, ch)
    return sr, samples


def main():
    path = sys.argv[1]
    start_sec = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
    dur_sec = float(sys.argv[3]) if len(sys.argv) > 3 else 0.1
    sr, samples = load(path)
    n_start = int(start_sec * sr)
    n_end = min(samples.shape[0], n_start + int(dur_sec * sr))
    win = samples[n_start:n_end]
    print(f"=== {path} @ {start_sec}s-{start_sec+dur_sec}s ({n_end-n_start} samples) ===")
    print()

    # First 60 samples L+R
    print("First 60 samples (L, R):")
    for i in range(min(60, win.shape[0])):
        print(f"  [{i:3d}] L={win[i,0]:+7d}  R={win[i,1]:+7d}")
    print()

    # Run-length analysis: how often does the SAME sample repeat?
    L = win[:, 0]
    R = win[:, 1]
    diffs_L = np.diff(L)
    print("Adjacent-sample diffs (L), first 30:")
    print(" ", diffs_L[:30].tolist())
    print()

    # Histogram of adjacent-diff magnitudes
    abs_diffs = np.abs(diffs_L)
    print("L abs(diff) distribution:")
    for q in [0, 25, 50, 75, 90, 95, 99, 100]:
        v = np.percentile(abs_diffs, q)
        print(f"  p{q:3d}: {v:.0f}")
    print()

    # FFT of this window
    if len(L) > 256:
        # Hann-windowed FFT
        m = L.astype(np.float64)
        w = np.hanning(len(m))
        spec = np.abs(rfft(m * w))
        freqs = rfftfreq(len(m), 1/sr)
        idx = np.argsort(spec)[::-1][:12]
        print(f"Top 12 frequencies in this window:")
        for i in sorted(idx, key=lambda x: freqs[x]):
            print(f"  {freqs[i]:7.1f} Hz   mag {spec[i]:8.0f}")
        print()

    # Detect "stuck same value" runs of length > 20
    run_starts = []
    run_lens = []
    cur_start = 0
    cur_val = L[0]
    for i in range(1, len(L)):
        if L[i] != cur_val:
            run_len = i - cur_start
            if run_len > 20:
                run_starts.append(cur_start)
                run_lens.append(run_len)
            cur_start = i
            cur_val = L[i]
    # Final run
    if len(L) - cur_start > 20:
        run_starts.append(cur_start)
        run_lens.append(len(L) - cur_start)
    print(f"L same-value runs > 20 samples ({(0.45 * sr / 1000):.2f} ms): {len(run_lens)} runs")
    for s, l in list(zip(run_starts, run_lens))[:8]:
        print(f"  sample {s}: value {L[s]:+7d} held for {l} samples ({l*1000/sr:.2f} ms)")


if __name__ == '__main__':
    main()
