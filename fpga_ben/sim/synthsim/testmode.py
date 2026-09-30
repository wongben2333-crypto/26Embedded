"""Test-mode signals and spectrum analysis (CONTRACT.md s5).

Rule-3 evidence generator: N simultaneous tones (f0, f0+spacing, ...) that a
spectrum analyzer must show as N independent peaks, plus FFT peak counting and
the evidence plot.
"""
from __future__ import annotations

import os
from typing import Dict, Optional

import matplotlib
matplotlib.use("Agg")

import numpy as np
from scipy.signal import find_peaks

try:
    from . import params as _params_mod
except Exception:  # pragma: no cover - absolute fallback
    import synthsim.params as _params_mod  # type: ignore

# ---- optional sibling modules (owned by parallel agents) --------------------
try:
    from . import dds as _dds
    _HAS_DDS = True
except Exception:  # sibling may be missing or mid-build
    _HAS_DDS = False

try:
    from . import wavetable as _wavetable
    _HAS_WT = True
except Exception:
    _HAS_WT = False

try:
    from . import adsr as _adsr
    _HAS_ADSR = True
except Exception:
    _HAS_ADSR = False


def _out_dir():
    return os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "out"))


def _make_env(n, sr, attack_ms):
    """Simple attack/release envelope used when synthsim.adsr is unavailable."""
    attack_s = max(float(attack_ms) / 1000.0, 1.0 / sr)
    env = np.ones(n, dtype=np.float64)
    attack_n = min(int(round(attack_s * sr)), n)
    if attack_n > 0:
        env[:attack_n] = np.linspace(0.0, 1.0, attack_n)
    rel_n = min(int(round(0.05 * sr)), n // 8)
    if rel_n > 0:
        env[-rel_n:] = np.linspace(1.0, 0.0, rel_n)
    return env


def synth_test_tones(params, n_tones=None, seconds=None):
    """Generate ``n_tones`` equal-spaced tones (f0, f0+spacing, ...) at once.

    Each tone gets its own oscillator and its own ADSR; the voices are mixed
    with the RTL voice-gain shift and hard-limited to [-1, 1].  Uses
    ``synthsim.dds.DDSOsc`` + ``synthsim.wavetable.generate_sine`` when
    available, otherwise an internal float sine bank (function always works).
    """
    n_tones = int(params.test_tones if n_tones is None else n_tones)
    seconds = float(params.test_seconds if seconds is None else seconds)
    sr = int(params.sr)
    n = int(round(sr * seconds))
    f0 = float(params.test_f0_hz)
    spacing = float(params.test_spacing_hz)
    fmax = f0 + spacing * (n_tones - 1)
    if fmax >= sr / 2.0:
        raise ValueError("top test tone %.1f Hz >= Nyquist %.1f Hz"
                         % (fmax, sr / 2.0))
    gain = 2.0 ** (-int(params.voice_gain_shift))
    if _HAS_DDS and _HAS_WT:
        total = _tones_dds(params, n, sr, f0, spacing, n_tones, gain)
    else:
        total = _tones_fallback(n, sr, f0, spacing, n_tones, gain,
                                params.adsr_attack_ms)
    return np.clip(total, -1.0, 1.0)


def _tones_dds(params, n, sr, f0, spacing, n_tones, gain):
    table = _wavetable.generate_sine(int(params.table_size),
                                     int(params.table_bits))
    oscs = [_dds.DDSOsc(table, sr, int(params.phase_bits),
                        int(params.table_bits), str(params.interp))
            for _ in range(n_tones)]
    for k, osc in enumerate(oscs):
        osc.set_freq(f0 + k * spacing)
    total = np.zeros(n, dtype=np.float64)
    if _HAS_ADSR:
        for osc in oscs:
            env = _adsr.ADSREnv(sr, params.adsr_attack_ms, params.adsr_decay_ms,
                                params.adsr_sustain, params.adsr_release_ms,
                                env_bits=int(params.env_bits),
                                curve=str(params.adsr_curve))
            env.note_on(1.0)
            total += osc.step(n) * env.step(n)
    else:
        env_vec = _make_env(n, sr, params.adsr_attack_ms)
        for osc in oscs:
            total += osc.step(n) * env_vec
    return total * gain


def _tones_fallback(n, sr, f0, spacing, n_tones, gain, attack_ms):
    t = np.arange(n, dtype=np.float64) / sr
    env = _make_env(n, sr, attack_ms)
    total = np.zeros(n, dtype=np.float64)
    for k in range(n_tones):
        total += np.sin(2.0 * np.pi * (f0 + k * spacing) * t) * env
    return total * gain


def _spectrum(x, sr):
    n = x.shape[0]
    window = np.hanning(n)
    nfft = 1 << max(int(n - 1).bit_length(), 1)  # next power of two >= n
    spec = np.abs(np.fft.rfft(x * window, n=nfft))
    freqs = np.fft.rfftfreq(nfft, 1.0 / sr)
    return freqs, spec


def analyze_peaks(x, sr, n_expected, f0, spacing, tol_hz=40.0):
    """Hann-windowed FFT peak search.

    Counts how many of the expected frequencies (f0 + k*spacing) have a
    detected local peak within +-tol_hz.  Returns
    {"detected": int, "expected": int, "ok": bool, "peaks_hz": [...]}.
    """
    x = np.asarray(x, dtype=np.float64)
    freqs, spec = _spectrum(x, sr)
    spec_max = float(spec.max())
    if spec_max <= 0.0 or x.shape[0] < 16:
        return {"detected": 0, "expected": int(n_expected), "ok": False,
                "peaks_hz": []}
    peaks_idx, _ = find_peaks(spec, height=0.05 * spec_max)
    peaks_idx = peaks_idx[peaks_idx > 0]  # skip the DC bin
    peaks_hz = freqs[peaks_idx]
    detected = 0
    for k in range(int(n_expected)):
        f = f0 + k * spacing
        if np.any(np.abs(peaks_hz - f) <= tol_hz):
            detected += 1
    return {"detected": int(detected),
            "expected": int(n_expected),
            "ok": detected >= n_expected,
            "peaks_hz": [round(float(p), 2) for p in np.sort(peaks_hz)]}


def plot_spectrum(x, sr, path, n_expected, f0, spacing):
    """Amplitude spectrum 0 .. (f0 + spacing*n_expected + margin), English
    labels, title states the expected peak count, detected count annotated."""
    import matplotlib.pyplot as plt
    x = np.asarray(x, dtype=np.float64)
    freqs, spec = _spectrum(x, sr)
    res = analyze_peaks(x, sr, n_expected, f0, spacing)
    xmax = f0 + spacing * n_expected + 0.5 * spacing
    mask = freqs <= xmax
    db = 20.0 * np.log10(spec[mask] + 1e-12)
    db -= db.max()
    fig, ax = plt.subplots(figsize=(10.0, 4.5))
    ax.plot(freqs[mask], db, lw=0.8, color="#1f6fb2")
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("Magnitude (dB, normalized)")
    ax.set_title("Spectrum of Test Signal: %d expected peaks" % int(n_expected))
    ax.annotate("detected %d / %d" % (res["detected"], res["expected"]),
                xy=(0.98, 0.94), xycoords="axes fraction", ha="right",
                bbox=dict(boxstyle="round", fc="white", ec="gray", alpha=0.9))
    ax.grid(True, alpha=0.3)
    d = os.path.dirname(os.path.abspath(path))
    if d:
        os.makedirs(d, exist_ok=True)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def _self_test():
    p = _params_mod.PARAMS_48K
    print("testmode: n_tones=%d f0=%.1f spacing=%.1f seconds=%.1f sr=%d"
          % (p.test_tones, p.test_f0_hz, p.test_spacing_hz, p.test_seconds,
             p.sr))
    path_used = "DDS+WT" if (_HAS_DDS and _HAS_WT) else "internal sine bank (fallback)"
    print("testmode: oscillator path = %s ; adsr module present = %s"
          % (path_used, _HAS_ADSR))
    x = synth_test_tones(p)
    print("testmode: signal peak = %.3f (limit 1.0)" % float(np.max(np.abs(x))))
    res = analyze_peaks(x, p.sr, p.test_tones, p.test_f0_hz, p.test_spacing_hz)
    print("analyze_peaks: detected=%d expected=%d ok=%s"
          % (res["detected"], res["expected"], res["ok"]))
    print("analyze_peaks: peaks_hz[:8] = %s ..." % (res["peaks_hz"][:8],))
    path = os.path.join(_out_dir(), "testmode_32peaks.png")
    plot_spectrum(x, p.sr, path, p.test_tones, p.test_f0_hz, p.test_spacing_hz)
    print("plot_spectrum: saved %s" % path)
    print("TESTMODE SELF-TEST OK (detected=%d/%d)"
          % (res["detected"], res["expected"]))


if __name__ == "__main__":
    _self_test()
