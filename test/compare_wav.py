#!/usr/bin/env python3
"""
Reference-diff audio comparator. Compares an emulator audio dump against a
ground-truth reference recording of the same content (another emulator's
output or a hardware capture) and reports per-metric deltas with pass/fail
verdicts against stated tolerances.

Handles the practical mismatches between the two captures:
  - different sample rates (both are resampled to a common analysis rate)
  - different lead-in/boot lengths (aligned by amplitude-envelope
    cross-correlation, not absolute time)
  - different master volumes (band energies are compared as fractions of
    total in-band energy, and levels as ratios, not absolutes)

Usage:
    python compare_wav.py <test.wav> <reference.wav> [--offset-max SECONDS]

Exit code 0 if all verdicts pass, 1 otherwise.
"""

import sys
import wave
from pathlib import Path

import numpy as np
from scipy import signal as sps

ANALYSIS_RATE = 48000
# Comparison ceiling: stay below both captures' Nyquist and below host
# resampler rolloff so neither side is penalized for content the other
# cannot represent.
BAND_EDGES = [0, 200, 500, 1000, 2000, 4000, 6000, 8000, 11000, 14000]
HF_SPLIT = 6000  # the harshness headline: fraction of energy above this
ENVELOPE_HOP_MS = 25

# Tolerances (the stated spectral tolerance for acceptance):
TOL_BAND_DB = 3.0        # per-band energy-fraction ratio, 200 Hz - 8 kHz
TOL_BAND_DB_HF = 4.0     # relaxed for 8-14 kHz (capture-chain rolloff)
TOL_HF_RATIO = 1.5       # test HF fraction within x1.5 of reference
TOL_ENV_CORR = 0.60      # aligned envelope correlation minimum


def load_wav(path):
    with wave.open(str(path), "rb") as w:
        rate = w.getframerate()
        n = w.getnframes()
        ch = w.getnchannels()
        raw = w.readframes(n)
    data = np.frombuffer(raw, dtype=np.int16).astype(np.float64)
    if ch == 2:
        data = data.reshape(-1, 2).mean(axis=1)
    return data / 32768.0, rate


def resample_to(data, rate, target):
    if rate == target:
        return data
    from math import gcd
    g = gcd(rate, target)
    return sps.resample_poly(data, target // g, rate // g)


def envelope(data, rate, hop_ms=ENVELOPE_HOP_MS):
    hop = int(rate * hop_ms / 1000)
    n = len(data) // hop
    return np.sqrt(np.mean(data[: n * hop].reshape(n, hop) ** 2, axis=1))


def trim_silence(data, rate, thresh=0.005):
    env = envelope(data, rate)
    hop = int(rate * ENVELOPE_HOP_MS / 1000)
    active = np.where(env > thresh)[0]
    if len(active) == 0:
        return data, 0
    start = active[0] * hop
    end = (active[-1] + 1) * hop
    return data[start:end], start


def align(test, ref, rate, offset_max_s=15.0):
    """Return (test_aligned, ref_aligned) overlapping segments via envelope
    cross-correlation."""
    et, er = envelope(test, rate), envelope(ref, rate)
    hop = int(rate * ENVELOPE_HOP_MS / 1000)
    max_lag = int(offset_max_s * 1000 / ENVELOPE_HOP_MS)
    n = min(len(et), len(er))
    et_n = (et[:n] - et[:n].mean()) / (et[:n].std() + 1e-12)
    er_n = (er[:n] - er[:n].mean()) / (er[:n].std() + 1e-12)
    corr = sps.correlate(et_n, er_n, mode="full")
    lags = sps.correlation_lags(len(et_n), len(er_n), mode="full")
    mask = np.abs(lags) <= max_lag
    best_lag = lags[mask][np.argmax(corr[mask])]
    shift = best_lag * hop
    if shift >= 0:
        t, r = test[shift:], ref
    else:
        t, r = test, ref[-shift:]
    m = min(len(t), len(r))
    return t[:m], r[:m], shift / rate


def band_fractions(data, rate):
    f, psd = sps.welch(data, fs=rate, nperseg=8192)
    total_mask = (f >= BAND_EDGES[0]) & (f < BAND_EDGES[-1])
    total = np.trapezoid(psd[total_mask], f[total_mask]) + 1e-30
    fracs = []
    for lo, hi in zip(BAND_EDGES[:-1], BAND_EDGES[1:]):
        m = (f >= lo) & (f < hi)
        fracs.append(np.trapezoid(psd[m], f[m]) / total)
    hf_mask = (f >= HF_SPLIT) & (f < BAND_EDGES[-1])
    hf = np.trapezoid(psd[hf_mask], f[hf_mask]) / total
    return np.array(fracs), hf


def dominant_peaks(data, rate, n_peaks=8):
    f, psd = sps.welch(data, fs=rate, nperseg=16384)
    m = (f >= 60) & (f < 8000)
    f, psd = f[m], psd[m]
    idx, _ = sps.find_peaks(10 * np.log10(psd + 1e-30), distance=20,
                            prominence=6)
    order = np.argsort(psd[idx])[::-1][:n_peaks]
    return sorted(f[idx[order]])


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        return 2
    offset_max = 15.0
    if "--offset-max" in args:
        offset_max = float(args[args.index("--offset-max") + 1])

    test_path, ref_path = Path(args[0]), Path(args[1])
    test, tr = load_wav(test_path)
    ref, rr = load_wav(ref_path)
    print(f"test: {test_path.name}  rate={tr}  dur={len(test)/tr:.1f}s")
    print(f"ref:  {ref_path.name}  rate={rr}  dur={len(ref)/rr:.1f}s")

    # DC before any filtering (reported, not a verdict: capture chains may
    # remove DC that the raw dump preserves)
    print(f"\nDC (raw, full-scale ppm): test {test.mean()*1e6:+.0f}  "
          f"ref {ref.mean()*1e6:+.0f}")

    test = resample_to(test, tr, ANALYSIS_RATE)
    ref = resample_to(ref, rr, ANALYSIS_RATE)

    test, t_start = trim_silence(test, ANALYSIS_RATE)
    ref, r_start = trim_silence(ref, ANALYSIS_RATE)
    print(f"onset trim: test {t_start/ANALYSIS_RATE:.2f}s  "
          f"ref {r_start/ANALYSIS_RATE:.2f}s")

    test, ref, shift = align(test, ref, ANALYSIS_RATE, offset_max)
    overlap = len(test) / ANALYSIS_RATE
    print(f"alignment shift {shift:+.2f}s  overlap {overlap:.1f}s")
    if overlap < 10:
        print("VERDICT: FAIL (insufficient overlap after alignment)")
        return 1

    # remove DC for spectral work
    test = test - test.mean()
    ref = ref - ref.mean()

    et, er = envelope(test, ANALYSIS_RATE), envelope(ref, ANALYSIS_RATE)
    n = min(len(et), len(er))
    env_corr = float(np.corrcoef(et[:n], er[:n])[0, 1])

    tf, t_hf = band_fractions(test, ANALYSIS_RATE)
    rf, r_hf = band_fractions(ref, ANALYSIS_RATE)

    print(f"\n--- band energy fractions (of 0-{BAND_EDGES[-1]//1000}kHz "
          f"total) ---")
    print(f"{'band':>14} | {'test':>8} | {'ref':>8} | {'ratio dB':>8} | "
          f"tol | verdict")
    failures = []
    for i, (lo, hi) in enumerate(zip(BAND_EDGES[:-1], BAND_EDGES[1:])):
        ratio_db = 10 * np.log10((tf[i] + 1e-12) / (rf[i] + 1e-12))
        tol = TOL_BAND_DB if hi <= 8000 else TOL_BAND_DB_HF
        judged = lo >= 200  # sub-200 Hz excluded (capture-chain HP filters)
        ok = abs(ratio_db) <= tol if judged else True
        tag = ("PASS" if ok else "FAIL") if judged else "info"
        if judged and not ok:
            failures.append(f"band {lo}-{hi} Hz off by {ratio_db:+.1f} dB")
        print(f"{lo:>6}-{hi:<6} | {tf[i]*100:>7.2f}% | {rf[i]*100:>7.2f}% | "
              f"{ratio_db:>+8.1f} | {tol:.0f}  | {tag}")

    hf_ratio = (t_hf + 1e-12) / (r_hf + 1e-12)
    hf_ok = hf_ratio <= TOL_HF_RATIO
    if not hf_ok:
        failures.append(f"HF(>{HF_SPLIT/1000:.0f}k) fraction x{hf_ratio:.2f} "
                        f"of reference (tol x{TOL_HF_RATIO})")
    print(f"\nHF energy fraction >{HF_SPLIT/1000:.0f} kHz: "
          f"test {t_hf*100:.2f}%  ref {r_hf*100:.2f}%  "
          f"ratio x{hf_ratio:.2f}  [{'PASS' if hf_ok else 'FAIL'}]")

    env_ok = env_corr >= TOL_ENV_CORR
    if not env_ok:
        failures.append(f"envelope correlation {env_corr:.3f} < "
                        f"{TOL_ENV_CORR}")
    print(f"envelope correlation: {env_corr:.3f}  "
          f"[{'PASS' if env_ok else 'FAIL'}]")

    tp = dominant_peaks(test, ANALYSIS_RATE)
    rp = dominant_peaks(ref, ANALYSIS_RATE)
    print(f"\ndominant peaks test: {['%.0f' % p for p in tp]}")
    print(f"dominant peaks ref:  {['%.0f' % p for p in rp]}")

    print("\n=== VERDICT:", "PASS ===" if not failures else "FAIL ===")
    for fmsg in failures:
        print(f"  - {fmsg}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
