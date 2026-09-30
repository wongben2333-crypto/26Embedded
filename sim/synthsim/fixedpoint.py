"""Fixed-point analysis for the FPGA polyphonic-synth golden model.

Answers analysis question (a): the minimum viable fixed-point bit width per
stage.  Tools: mid-tread uniform re-quantization (models an RTL quantizer),
SNR / ENOB measurement, THD via FFT, and a bit sweep that exposes the classic
~6 dB/bit slope.

Python 3.8 compatible: typing.* only, no PEP-604 unions, no match statement.
Audio convention (CONTRACT.md section 0): float audio is float64 on [-1, 1].
"""
from __future__ import annotations

import os
from typing import List, Sequence, Tuple

import numpy as np

from .params import PARAMS_48K

#: SNR returned when the quantization error is numerically zero (the input
#: already lies exactly on the grid).  A truly noiseless re-quantization has
#: infinite SNR; we clip it so tabular output stays finite and readable.
SNR_CAP_DB = 150.0

#: Error-power floor for the snr_db() epsilon guard, relative to the reference
#: signal power.  Guards against log10(0) / division blow-ups.
_EPS_REL = float(np.finfo(np.float64).eps) * 1e3


def quantize(x: np.ndarray, bits: int, signed: bool = True) -> np.ndarray:
    """Re-quantize audio to ``bits`` and return it on the SAME float scale.

    Assumes ``x`` is normalized to [-1, 1] (signed) or [0, 1] (unsigned) per
    the project audio convention.  Mid-tread uniform grid, round-to-nearest;
    out-of-range values clip to the outermost code (like an RTL saturating
    quantizer).  Returns float64 on the same scale as the input -- this models
    the quantizer, it does not emit integers.
    """
    x = np.asarray(x, dtype=np.float64)
    bits = int(bits)
    if bits < 1:
        raise ValueError("bits must be >= 1")
    if signed:
        # Codes: -2**(bits-1) .. 2**(bits-1)-1  ->  step = 2 / 2**bits
        half = 1 << (bits - 1)
        q = np.round(x * half) / half
        q = np.clip(q, -1.0, 1.0 - 2.0 / float(1 << bits))
    else:
        # Codes: 0 .. 2**bits-1  ->  step = 1 / 2**bits
        n_levels = 1 << bits
        q = np.round(x * n_levels) / n_levels
        q = np.clip(q, 0.0, 1.0 - 1.0 / n_levels)
    return q


def snr_db(ref: np.ndarray, test: np.ndarray) -> float:
    """SNR of ``test`` vs ``ref``: 10*log10(sum(ref^2) / sum((ref-test)^2))."""
    ref = np.asarray(ref, dtype=np.float64)
    err = np.asarray(test, dtype=np.float64) - ref
    p_ref = float(np.sum(ref * ref))
    p_err = float(np.sum(err * err))
    if p_ref <= 0.0:
        return 0.0
    if p_err <= _EPS_REL * p_ref:
        return SNR_CAP_DB
    return 10.0 * np.log10(p_ref / p_err)


def thd_db(sig: np.ndarray, sr: int, f0: float) -> float:
    """Total harmonic distortion (harmonics 2..10) in dBc, via FFT.

    Hann window, coherent-gain corrected; picks the bins nearest to k*f0 for
    k = 1..10.  For a meaningful reading f0 should be bin-aligned
    (f0*n/sr an integer); otherwise spectral leakage fills the harmonic bins.
    Returns a very negative value when the harmonic power is at/below the
    numerical floor (e.g. pure quantization noise, which is white, not
    harmonic).
    """
    sig = np.asarray(sig, dtype=np.float64)
    n = len(sig)
    if n < 8:
        return float("nan")
    window = np.hanning(n)
    spec = np.fft.rfft(sig * window)
    # Power per bin with coherent-gain correction.
    p = (np.abs(spec) ** 2) / float(np.sum(window)) ** 2
    i0 = int(round(f0 * n / float(sr)))
    if i0 >= len(p):
        return float("nan")
    p_fund = float(p[i0])
    p_harm = 0.0
    for k in range(2, 11):
        ih = int(round(k * f0 * n / float(sr)))
        if ih >= len(p):
            break
        p_harm += float(p[ih])
    if p_fund <= 0.0 or p_harm <= 0.0:
        return -300.0
    return 10.0 * np.log10(p_harm / p_fund)


def enob(snr: float) -> float:
    """Effective number of bits from an SNR in dB: (snr - 1.76) / 6.02."""
    return (snr - 1.76) / 6.02


def sweep_requant(x: np.ndarray, bit_list: Sequence[int]) -> List[Tuple[int, float]]:
    """Re-quantize ``x`` at each width in ``bit_list``; return [(bits, snr_db)]."""
    x = np.asarray(x, dtype=np.float64)
    pairs = []  # type: List[Tuple[int, float]]
    for bits in bit_list:
        q = quantize(x, int(bits))
        pairs.append((int(bits), snr_db(x, q)))
    return pairs


def _plot_snr_vs_bits(bits: Sequence[int], snrs: Sequence[float], amp: float) -> str:
    """Save the SNR-vs-bit curve (Agg backend, English labels only)."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    out_dir = r"E:\26Embedded\sim\out"
    os.makedirs(out_dir, exist_ok=True)

    bits_arr = np.asarray(bits, dtype=np.float64)
    snrs_arr = np.asarray(snrs, dtype=np.float64)
    # Classical model for round-to-nearest on a full-scale sine, corrected for
    # the actual amplitude A: SNR = 6.02*b + 1.76 + 20*log10(A).
    theory = 6.02 * bits_arr + 1.76 + 20.0 * np.log10(amp)

    plt.figure(figsize=(7, 5))
    plt.plot(bits_arr, snrs_arr, "o-", label="measured SNR")
    plt.plot(bits_arr, theory, "k--",
             label="theory 6.02b + 1.76 + 20log10(A)")
    plt.xlabel("Quantizer bits")
    plt.ylabel("SNR (dB)")
    plt.title("Sine re-quantization: SNR vs bit width")
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    path = os.path.join(out_dir, "fixedpoint_snr.png")
    plt.savefig(path, dpi=150)
    plt.close()
    return path


def _self_test() -> None:
    sr = PARAMS_48K.sr
    f0 = 440.0
    n = sr  # 1 s -> 440 whole cycles -> coherent sampling (bin 440)
    t = np.arange(n, dtype=np.float64) / sr
    # 0.9 amplitude leaves headroom so the sweep never exercises clipping.
    x = 0.9 * np.sin(2.0 * np.pi * f0 * t)

    bits = list(range(4, 21))
    pairs = sweep_requant(x, bits)

    print("Quantization SNR sweep: 440 Hz sine @ %d Hz, amplitude 0.9" % sr)
    print("theory slope: 6.02 dB/bit; full-scale intercept +1.76 dB, "
          "amplitude correction 20*log10(0.9) = -0.92 dB")
    print("%5s %10s %10s" % ("bits", "SNR dB", "ENOB"))
    for b, s in pairs:
        print("%5d %10.2f %10.2f" % (b, s, enob(s)))

    q16 = quantize(x, 16)
    print("THD of the 16-bit re-quantized sine: %.1f dBc "
          "(quantization error is white, not harmonic)" % thd_db(q16, sr, f0))

    path = _plot_snr_vs_bits(bits, [s for _, s in pairs], 0.9)
    print("SNR-vs-bit curve saved to %s" % path)


if __name__ == "__main__":
    _self_test()
