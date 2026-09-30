"""WAV rendering: float64 [-1,1] <-> 16-bit PCM mono (CONTRACT.md s5)."""
from __future__ import annotations

import os
from typing import Tuple

import numpy as np
from scipy.io import wavfile

# Deterministic dither source so the golden model is reproducible run-to-run.
_RNG = np.random.default_rng(20240901)


def write_wav(path, x, sr):
    """Write mono 16-bit PCM WAV.

    Clamps to [-1, 1], applies +/-1 LSB TPDF dither, then quantizes to int16.
    """
    x = np.asarray(x, dtype=np.float64).ravel()
    x = np.clip(x, -1.0, 1.0)
    dither = (_RNG.random(x.shape[0]) + _RNG.random(x.shape[0]) - 1.0) / 32768.0
    x = np.clip(x + dither, -1.0, 1.0)
    pcm = np.round(x * 32767.0).astype(np.int16)
    d = os.path.dirname(os.path.abspath(path))
    if d:
        os.makedirs(d, exist_ok=True)
    wavfile.write(path, int(sr), pcm)


def load_wav(path):
    """Read a WAV back to float64 in [-1, 1]; returns (x, sr)."""
    sr, data = wavfile.read(path)
    if data.dtype == np.int16:
        x = data.astype(np.float64) / 32768.0
    elif data.dtype == np.int32:
        x = data.astype(np.float64) / 2147483648.0
    elif data.dtype == np.uint8:
        x = (data.astype(np.float64) - 128.0) / 128.0
    else:  # float32 / float64 already scaled to [-1, 1]
        x = data.astype(np.float64)
    return np.clip(x, -1.0, 1.0), int(sr)


def _out_dir():
    return os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "out"))


def _self_test():
    sr = 48000
    dur = 1.0
    t = np.arange(int(sr * dur), dtype=np.float64) / sr
    x = 0.5 * np.sin(2.0 * np.pi * 440.0 * t)
    path = os.path.join(_out_dir(), "render_selftest_440.wav")
    write_wav(path, x, sr)
    y, sr2 = load_wav(path)
    corr = float(np.corrcoef(x, y)[0, 1])
    print("write_wav: sr=%d n=%d peak=%.3f -> %s"
          % (sr, x.shape[0], float(np.max(np.abs(x))), path))
    print("load_wav:  sr=%d n=%d peak=%.3f"
          % (sr2, y.shape[0], float(np.max(np.abs(y)))))
    print("round-trip: sr_match=%s correlation=%.6f (require > 0.99)"
          % (sr == sr2, corr))
    assert sr == sr2
    assert corr > 0.99
    assert float(np.max(np.abs(y))) <= 1.0
    print("RENDER SELF-TEST OK")


if __name__ == "__main__":
    _self_test()
