#!/usr/bin/env python3
"""
Audio diagnostic analyzer for Pascal-GBA APU output. Reads a stereo
S16 WAV and produces:

  - Basic stats (peak, RMS, DC offset, clip count)
  - Per-channel L/R analysis
  - Time-windowed (per-second) stats so we can see how audio evolves
  - Spectral content (top frequencies via FFT)
  - Aliasing diagnostics (HF energy beyond expected band)
  - Discontinuity detection (sign-flip / overflow artifacts)
  - L/R cross-correlation (are channels stereo or mono-mixed)
  - Spectrogram visualization (saved as PNG if matplotlib available,
    else text-art summary)

Usage:
    python analyze_wav.py <path-to-wav>

Output is printed to stdout; structured so an agent (or a human) can
read and reason about it without needing to visually inspect waveforms.
"""

import sys
import wave
import numpy as np
from scipy import signal as scipy_signal
from scipy.fft import rfft, rfftfreq
from pathlib import Path


def load_wav(path):
    """Load a stereo S16 WAV. Returns (sample_rate, samples_int16_shape_NxC)."""
    with wave.open(str(path), 'rb') as w:
        sr = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        nframes = w.getnframes()
        raw = w.readframes(nframes)
    assert sw == 2, f"expected 16-bit, got {sw*8}-bit"
    samples = np.frombuffer(raw, dtype=np.int16).reshape(-1, ch)
    return sr, samples


def basic_stats(samples, label=""):
    """Per-channel stats: peak, RMS, DC offset, clip count, distinct values."""
    out = {}
    chans = samples.shape[1]
    for i in range(chans):
        s = samples[:, i].astype(np.float64)
        ch_name = ['L', 'R'][i] if chans == 2 else f'C{i}'
        out[ch_name] = {
            'peak_pos': int(s.max()),
            'peak_neg': int(s.min()),
            'rms': float(np.sqrt(np.mean(s * s))),
            'mean': float(np.mean(s)),      # DC offset
            'clip_count_pos': int(np.sum(s >= 32767)),
            'clip_count_neg': int(np.sum(s <= -32768)),
            'distinct_values': int(len(np.unique(samples[:, i]))),
            'silence_pct': float(np.mean(s == 0) * 100),
        }
    return out


def per_second_stats(samples, sr, max_seconds=15):
    """Stats per 1-second window, so we can see how audio evolves."""
    n = samples.shape[0]
    sec_count = min(max_seconds, n // sr)
    rows = []
    for s in range(sec_count):
        chunk = samples[s*sr:(s+1)*sr]
        # mono-mix for unified stats
        m = chunk.astype(np.float64).mean(axis=1)
        rows.append({
            'sec': s,
            'peak': int(np.abs(m).max()),
            'rms': float(np.sqrt(np.mean(m * m))),
            'dc': float(np.mean(m)),
            'zcr': float(np.mean(np.abs(np.diff(np.sign(m))) > 0)),
        })
    return rows


def find_dominant_frequencies(samples, sr, max_freqs=10, start_sec=0, dur_sec=1):
    """FFT a window and return top N frequencies by magnitude."""
    n_start = int(start_sec * sr)
    n_end = min(samples.shape[0], n_start + int(dur_sec * sr))
    window = samples[n_start:n_end].astype(np.float64).mean(axis=1)
    if len(window) < 256:
        return []
    # Hann window to reduce spectral leakage
    win = window * np.hanning(len(window))
    spec = np.abs(rfft(win))
    freqs = rfftfreq(len(win), 1/sr)
    # Top peaks
    idx = np.argsort(spec)[::-1][:max_freqs]
    return [(float(freqs[i]), float(spec[i])) for i in sorted(idx, key=lambda x: freqs[x])]


def detect_aliasing(samples, sr, internal_rate_hint=32768):
    """Check spectral energy distribution. Energy above internal_rate_hint/2
    indicates aliasing (high-frequency artifacts from undersampling).
    Returns (frac_below_band, frac_above_band, energy_at_pop_rate)."""
    m = samples.astype(np.float64).mean(axis=1)
    spec = np.abs(rfft(m)) ** 2
    freqs = rfftfreq(len(m), 1/sr)
    nyquist_internal = internal_rate_hint / 2  # source max-fidelity band
    in_band = spec[freqs <= nyquist_internal].sum()
    out_band = spec[freqs > nyquist_internal].sum()
    total = in_band + out_band
    if total == 0:
        return (0.0, 0.0, 0.0)
    # Energy near typical pop-rate harmonics (13-15 kHz region)
    pop_band = spec[(freqs >= 12000) & (freqs <= 16000)].sum()
    return (in_band / total, out_band / total, pop_band / total)


def detect_discontinuities(samples, threshold=20000):
    """Count adjacent samples with abs diff > threshold (overflow / sign-flip artifacts)."""
    out = {}
    chans = samples.shape[1]
    for i in range(chans):
        ch_name = ['L', 'R'][i] if chans == 2 else f'C{i}'
        diffs = np.abs(np.diff(samples[:, i].astype(np.int32)))
        out[ch_name] = int(np.sum(diffs > threshold))
    return out


def lr_correlation(samples, sr):
    """Compute L/R correlation. 1.0 = identical (mono-mixed). 0.0 = independent stereo.
    Negative = inverted (rare)."""
    if samples.shape[1] != 2:
        return None
    L = samples[:, 0].astype(np.float64)
    R = samples[:, 1].astype(np.float64)
    if L.std() == 0 or R.std() == 0:
        return 0.0
    return float(np.corrcoef(L, R)[0, 1])


def spectrogram_summary(samples, sr, n_buckets=10, freq_buckets=8):
    """Produce a text-art spectrogram. Time on Y axis, frequency on X axis."""
    m = samples.astype(np.float64).mean(axis=1)
    f, t, Sxx = scipy_signal.spectrogram(m, fs=sr, nperseg=2048, noverlap=1024)
    # Power in dB
    Sdb = 10 * np.log10(Sxx + 1e-12)
    # Bin time into n_buckets, freq into freq_buckets up to Nyquist
    if Sdb.shape[1] == 0:
        return ["(no data)"]
    t_idx = np.linspace(0, Sdb.shape[1] - 1, n_buckets).astype(int)
    f_idx = np.linspace(0, Sdb.shape[0] - 1, freq_buckets + 1).astype(int)

    grid = np.zeros((len(t_idx), freq_buckets))
    for ti, tii in enumerate(t_idx):
        for fb in range(freq_buckets):
            grid[ti, fb] = Sdb[f_idx[fb]:f_idx[fb+1], tii].mean()

    # Normalize to dB-floor for visual
    g_norm = (grid - grid.min()) / (grid.max() - grid.min() + 1e-9)
    chars = ' .:-=+*#%@'
    lines = []
    freq_labels = []
    for fb in range(freq_buckets):
        fmin = f[f_idx[fb]]
        fmax = f[f_idx[fb+1]] if f_idx[fb+1] < len(f) else f[-1]
        freq_labels.append(f"{fmin/1000:.1f}-{fmax/1000:.1f}kHz")
    header = "  time->  " + "  ".join([f"t{i}" for i in range(n_buckets)])
    lines.append(header)
    for fb in reversed(range(freq_buckets)):  # high freq on top
        row = [chars[int(g_norm[ti, fb] * (len(chars)-1))] * 3 for ti in range(n_buckets)]
        lines.append(f"{freq_labels[fb]:14s} " + " ".join(row))
    return lines


def main():
    if len(sys.argv) < 2:
        print("Usage: analyze_wav.py <path-to-wav>")
        sys.exit(1)
    path = Path(sys.argv[1])
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        sys.exit(1)

    print(f"=== Analyzing {path} ===\n")
    sr, samples = load_wav(path)
    dur = samples.shape[0] / sr
    print(f"Sample rate: {sr} Hz")
    print(f"Channels:    {samples.shape[1]}")
    print(f"Duration:    {dur:.3f} s ({samples.shape[0]} frames)")
    print()

    print("--- Basic stats ---")
    stats = basic_stats(samples)
    for ch, s in stats.items():
        print(f"{ch}: peak [{s['peak_neg']}, {s['peak_pos']}]  "
              f"RMS {s['rms']:.1f}  DC {s['mean']:.1f}  "
              f"clip+ {s['clip_count_pos']}  clip- {s['clip_count_neg']}  "
              f"distinct {s['distinct_values']}  silence {s['silence_pct']:.1f}%")
    print()

    print("--- Per-second evolution ---")
    rows = per_second_stats(samples, sr)
    print(f"  sec | peak    | RMS     | DC      | zero-cross-rate")
    for r in rows:
        print(f"  {r['sec']:3d} | {r['peak']:7d} | {r['rms']:7.1f} | "
              f"{r['dc']:+7.1f} | {r['zcr']:.4f}")
    print()

    print("--- Dominant frequencies in first 1s ---")
    freqs = find_dominant_frequencies(samples, sr, max_freqs=8, start_sec=0, dur_sec=1)
    for fr, mag in freqs:
        print(f"  {fr:7.1f} Hz   (mag {mag:.0f})")
    print()

    print("--- Aliasing diagnostics ---")
    for hint in [16384, 32768, 65536]:
        in_b, out_b, pop_b = detect_aliasing(samples, sr, internal_rate_hint=hint)
        print(f"  internal rate hint {hint:6d} Hz: "
              f"in-band {in_b*100:5.1f}%  out-of-band {out_b*100:5.1f}%  "
              f"12-16kHz region {pop_b*100:5.1f}%")
    print()

    print("--- Discontinuities (|diff| > 20000) ---")
    disc = detect_discontinuities(samples, threshold=20000)
    for ch, n in disc.items():
        print(f"  {ch}: {n} discontinuity events")
    print()

    print("--- L/R correlation ---")
    corr = lr_correlation(samples, sr)
    if corr is None:
        print("  not stereo")
    elif corr > 0.99:
        print(f"  {corr:.4f} — channels essentially identical (mono-mixed)")
    elif corr > 0.5:
        print(f"  {corr:.4f} — channels mostly similar")
    elif corr > 0.0:
        print(f"  {corr:.4f} — channels weakly correlated (stereo with some shared content)")
    else:
        print(f"  {corr:.4f} — channels independent or anti-correlated")
    print()

    print("--- Spectrogram (text-art, intensity = dB power) ---")
    for line in spectrogram_summary(samples, sr):
        print("  " + line)
    print()


if __name__ == '__main__':
    main()
