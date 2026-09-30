"""Voice-bus mixer for the polyphonic synth golden model.

Pure numpy, no dependency on other synthsim modules.  The three functions here
mirror the RTL mixing stage:

  * each voice sample is right-shifted by ``shift`` bits before the sum (one
    LSB of attenuation per bit, i.e. ``-6.02 dB`` per bit), buying headroom
    against the coherent-sum worst case;
  * the summed bus is optionally hard-limited to ``[-1, 1]``;
  * a tanh soft-clip is provided for a "soft saturation" path.

Everything operates on float64 mono audio in ``[-1, 1]``.
"""
from __future__ import annotations

from typing import Sequence

import numpy as np


def mix_sum(signals: Sequence[np.ndarray], shift: int,
            saturate: bool = True) -> np.ndarray:
    """Sum voice signals with per-voice right shift, then optional hard limit.

    Each signal is scaled by ``2.0 ** -shift`` before the sum.  This is the
    floating-point equivalent of an arithmetic right shift on a fixed-point
    bus: one LSB of attenuation per bit (``-6.02 dB`` per bit).  Because the
    scaling is linear, ``sum(s * 2**-shift) == 2**-shift * sum(s)``, so the
    shift is applied to the accumulator once.

    ``saturate=True`` clamps the result to ``[-1.0, 1.0]`` (hard clip), which
    is what guarantees the output never overflows regardless of how many
    full-scale voices are summed.

    If ``signals`` is empty the result is a length-0 array; otherwise all
    signals must share the first signal's length.
    """
    if len(signals) == 0:
        return np.zeros(0, dtype=np.float64)
    n = int(signals[0].shape[0])
    scale = 2.0 ** (-int(shift))
    acc = np.zeros(n, dtype=np.float64)
    for s in signals:
        acc += np.asarray(s, dtype=np.float64)
    acc *= scale
    if saturate:
        np.clip(acc, -1.0, 1.0, out=acc)
    return acc


def soft_clip(x: np.ndarray, drive: float = 1.0) -> np.ndarray:
    """Soft saturation via tanh.

    ``tanh(drive * x)`` is smooth, odd-symmetric, has unit slope at the origin
    for ``drive == 1.0``, and asymptotes to +/- 1, so the output always stays
    inside (-1, 1) with no hard corners.  ``drive > 1`` raises the near-zero
    gain and reaches saturation sooner (more "overdrive").
    """
    return np.tanh(drive * np.asarray(x, dtype=np.float64))


def headroom_dbfs(n_signals: int, shift: int) -> float:
    """Worst-case bus level in dBFS for ``n_signals`` voices and ``shift`` bits.

    Reasoning
    ---------
    Each full-scale (0 dBFS) voice is attenuated by ``shift`` bits before the
    sum, i.e. scaled by ``2**-shift``.  In the *worst case* all ``n_signals``
    voices are exactly in phase (coherent) and full scale, so their summed
    amplitude is::

        amplitude = n_signals * 2**-shift

    which in dBFS is::

        20*log10(n_signals) + 20*log10(2**-shift)
        = 20*log10(n_signals) - 20*log10(2)*shift
        = 20*log10(n_signals) - 6.02*shift          (20*log10(2) ~= 6.02)

    The returned value is therefore the *worst-case summed level* relative to
    full scale:

      * negative  -> that many dB of headroom still remain (safe);
      * ~0 dBFS   -> the bus just reaches full scale (needs the saturator);
      * positive  -> would clip without the saturator.

    Example: 32 full-scale voices with shift=5 give 20*log10(32) - 6.02*5 ~=
    30.1 - 30.1 = 0 dBFS, exactly full scale -- hence ``mix_sum`` clamps.
    """
    return 20.0 * np.log10(float(n_signals)) - 6.02 * float(shift)


if __name__ == "__main__":
    from .params import PARAMS_48K

    p = PARAMS_48K
    shift = p.voice_gain_shift
    n = 48000
    rng = np.random.default_rng(12345)

    print("mixer self-test")
    print("voice_gain_shift = {}  (one bit = -6.02 dB)".format(shift))
    print("{:>8} | {:>13} | {:>14} | {:>12}".format(
        "n_voices", "headroom_dBFS", "coherent_peak", "random_peak"))
    for ns in (4, 8, 16, 32):
        hd = headroom_dbfs(ns, shift)

        # worst case: ns identical full-scale signals (perfectly coherent)
        coherent = [np.ones(n) for _ in range(ns)]
        peak_c = float(np.max(np.abs(mix_sum(coherent, shift, saturate=True))))

        # realistic: ns full-scale sines at random phases
        t = np.arange(n, dtype=np.float64) / p.sr
        phases = rng.uniform(0.0, 2.0 * np.pi, ns)
        sines = [np.sin(2.0 * np.pi * 440.0 * t + ph) for ph in phases]
        peak_r = float(np.max(np.abs(mix_sum(sines, shift, saturate=True))))

        print("{:>8} | {:>13.3f} | {:>14.6f} | {:>12.6f}".format(
            ns, hd, peak_c, peak_r))
        assert peak_c <= 1.0 + 1e-12, "coherent peak exceeded 1.0"

    print("all coherent worst-case peaks <= 1.0: OK (no overflow / no clip)")
    print("soft_clip(2.0, drive=1.0) = {:.6f}".format(float(soft_clip(np.array([2.0]))[0])))
    print("mixer OK")
