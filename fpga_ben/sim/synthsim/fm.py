"""Frequency-modulation (FM) synthesis: 2-operator and serial N-operator chains.

FM is phase modulation: the modulator output (a sine at mod_ratio*freq) drives
the carrier phase with a deviation of ``mod_index`` radians.  ``fm_stack``
cascades operators serially (each operator's output modulates the next), the
standard DX-style serial algorithm; the final operator's output is the voice.
"""
from __future__ import annotations

from typing import Sequence

import numpy as np


def fm(freq_hz: float, n: int, sr: int, mod_ratio: float = 1.0,
       mod_index: float = 1.0, carrier_harmonic: float = 1.0) -> np.ndarray:
    """2-operator FM, float64 [-1, 1] per sample.

    modulator phase = mod_ratio * freq_hz; carrier phase deviation = mod_index.
    """
    t = np.arange(n, dtype=np.float64) / float(sr)
    mod = np.sin(2.0 * np.pi * mod_ratio * freq_hz * t)
    carrier_phase = 2.0 * np.pi * carrier_harmonic * freq_hz * t + mod_index * mod
    return np.sin(carrier_phase)


def fm_stack(freq_hz: float, n: int, sr: int,
             ratios: Sequence[float], indices: Sequence[float]) -> np.ndarray:
    """Serial multi-operator FM chain (len(ratios) == len(indices) == #operators).

    Operator i oscillates at ratios[i]*freq_hz with phase deviation
    indices[i]*modulation_from_previous_operator; output is the last operator.
    """
    ratios = list(ratios)
    indices = list(indices)
    if not ratios:
        return np.zeros(n, dtype=np.float64)

    t = np.arange(n, dtype=np.float64) / float(sr)
    mod_sig = np.zeros(n, dtype=np.float64)
    for i in range(len(ratios)):
        idx = indices[i] if i < len(indices) else 0.0
        ang = 2.0 * np.pi * ratios[i] * freq_hz * t + idx * mod_sig
        mod_sig = np.sin(ang)
    return mod_sig


if __name__ == "__main__":
    from scipy.signal import find_peaks

    sr = 48000
    n = sr
    freq = 440.0

    print("=== fm self-test ===")
    for mi in (0.0, 3.0):
        x = fm(freq, n, sr, mod_ratio=1.0, mod_index=mi)
        X = np.abs(np.fft.rfft(x))
        freqs = np.fft.rfftfreq(n, 1.0 / sr)
        centroid = float(np.sum(freqs * X) / np.sum(X))
        thr = 0.01 * float(np.max(X))
        peaks, _ = find_peaks(X, height=thr, distance=10)
        print("mod_index={:.1f}: sideband_peaks={:2d} spectral_centroid={:8.2f} Hz"
              .format(mi, len(peaks), centroid))

    # serial 2-op chain should match 2-op fm(index at second operator)
    x_stack = fm_stack(freq, n, sr, ratios=[1.0, 1.0], indices=[0.0, 3.0])
    x_fm = fm(freq, n, sr, mod_ratio=1.0, mod_index=3.0, carrier_harmonic=1.0)
    corr = float(np.corrcoef(x_stack, x_fm)[0, 1])
    print("fm_stack(2-op) vs fm() correlation = {:.6f}".format(corr))

    # 3-op serial chain
    x3 = fm_stack(freq, n, sr, ratios=[1.0, 2.0, 1.0], indices=[0.0, 1.5, 2.0])
    print("fm_stack(3-op) rms = {:.4f} peak = {:.4f}".format(
        float(np.sqrt(np.mean(x3 ** 2))), float(np.max(np.abs(x3)))))
    print("fm OK")
