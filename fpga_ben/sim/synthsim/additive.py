"""Additive synthesis: sum of harmonically-related sine partials.

This is the engine behind the 32-component extension path B.  Each partial is
a pure sine at (k+1)*freq_hz; the amplitude vector is auto-normalized so the
result never clips (peak <= 1.0), matching the float64 [-1, 1] convention.
"""
from __future__ import annotations

from typing import Optional, Sequence

import numpy as np


def additive(freq_hz: float, n: int, sr: int,
             amplitudes: Sequence[float],
             phases: Optional[Sequence[float]] = None) -> np.ndarray:
    """Sum len(amplitudes) sines; partial k has frequency (k+1)*freq_hz.

    Auto-normalized to keep the peak <= 1.0 (avoids clipping).
    """
    amps = list(amplitudes)
    n_partials = len(amps)
    if n_partials == 0:
        return np.zeros(n, dtype=np.float64)

    t = np.arange(n, dtype=np.float64) / float(sr)
    if phases is None:
        phases = [0.0] * n_partials
    phases = list(phases)

    out = np.zeros(n, dtype=np.float64)
    for k in range(n_partials):
        f = (k + 1) * freq_hz
        out += amps[k] * np.sin(2.0 * np.pi * f * t + phases[k])

    peak = float(np.max(np.abs(out)))
    if peak > 1.0:
        out = out / peak
    return out


def additive_voice_bank(freq_hz: float, n: int, sr: int,
                        n_partials: int = 32) -> np.ndarray:
    """32-partial additive voice with 1/k harmonic rolloff (saw-like spectrum)."""
    amplitudes = [1.0 / (k + 1) for k in range(n_partials)]
    return additive(freq_hz, n, sr, amplitudes)


if __name__ == "__main__":
    from scipy.signal import find_peaks

    sr = 48000
    n = sr
    freq = 200.0
    n_partials = 32

    print("=== additive self-test ===")
    x = additive_voice_bank(freq, n, sr, n_partials)

    X = np.abs(np.fft.rfft(x))
    bin_hz = sr / n
    thr = 0.01 * float(np.max(X))
    peaks, _ = find_peaks(X, height=thr, distance=20)

    expected = [(k + 1) * freq for k in range(n_partials)]
    peak_hz = peaks * bin_hz
    detected = 0
    for f in expected:
        if np.any(np.abs(peak_hz - f) < 2.0):
            detected += 1

    print("voice_bank: n_partials={} fft_peaks_found={} expected={} matched={}"
          .format(n_partials, len(peaks), len(expected), detected))
    print("peak amplitude = {:.4f}  rms = {:.4f}".format(
        float(np.max(np.abs(x))), float(np.sqrt(np.mean(x ** 2)))))

    # DC should be ~0 (sines only)
    print("DC = {:+.5f}".format(float(np.mean(x))))
    print("additive OK")
