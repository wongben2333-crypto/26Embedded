"""Karplus-Strong plucked-string synthesis.

Classic algorithm: a circular delay line of length ~ round(sr/freq) is excited
with noise (or a single impulse) and, on each sample, the feedback path applies
a first-order lowpass (0.5*(current + previous)) plus a ``decay`` damping factor.
The resulting tone has a pitch set by the loop length and an envelope that
decays monotonically.
"""
from __future__ import annotations

import numpy as np


def karplus_strong(freq_hz: float, n: int, sr: int, decay: float = 0.996,
                   excitation: str = "noise", seed: int = 0) -> np.ndarray:
    """Classic Karplus-Strong pluck, float64 [-1, 1] per sample."""
    delay = int(round(sr / freq_hz))
    if delay < 1:
        delay = 1

    rng = np.random.RandomState(seed)
    if excitation == "impulse":
        buf = np.zeros(delay, dtype=np.float64)
        buf[0] = 1.0
    else:  # noise
        buf = rng.uniform(-1.0, 1.0, delay).astype(np.float64)

    out = np.empty(n, dtype=np.float64)
    idx = 0
    prev = 0.0
    for i in range(n):
        s = buf[idx]
        out[i] = s
        # first-order lowpass + decay in the feedback loop
        buf[idx] = decay * 0.5 * (s + prev)
        prev = s
        idx += 1
        if idx >= delay:
            idx = 0

    peak = float(np.max(np.abs(out)))
    if peak > 1.0:
        out = out / peak
    return out


if __name__ == "__main__":
    sr = 48000
    n = sr
    freq = 220.0

    print("=== karplus self-test ===")
    x = karplus_strong(freq, n, sr)

    # pitch via autocorrelation (fundamental lag -> frequency)
    corr = np.correlate(x, x, mode="full")
    corr = corr[len(corr) // 2:]  # lags 0..n-1
    min_lag = int(sr / (freq * 2.0))
    max_lag = int(sr / (freq * 0.5)) + 1
    max_lag = min(max_lag, len(corr))
    seg = corr[min_lag:max_lag]
    lag = int(np.argmax(seg)) + min_lag
    measured = sr / lag
    err_pct = 100.0 * abs(measured - freq) / freq
    print("pitch: target={:.1f} Hz measured={:.2f} Hz error={:.2f}%"
          .format(freq, measured, err_pct))

    # envelope monotonic decay: block RMS (coarse blocks spanning many periods
    # so the note-frequency oscillation averages out) must be non-increasing
    block = max(1, sr // 16)
    nblocks = n // block
    rms = np.sqrt(np.mean(x[:nblocks * block].reshape(nblocks, block) ** 2, axis=1))
    monotonic = bool(np.all(np.diff(rms) <= 1e-6))
    print("envelope monotonic decay: {}  (block RMS first={:.4f} last={:.6f})"
          .format(monotonic, float(rms[0]), float(rms[-1])))

    print("peak = {:.4f}  rms = {:.4f}".format(
        float(np.max(np.abs(x))), float(np.sqrt(np.mean(x ** 2)))))
    print("karplus OK")
