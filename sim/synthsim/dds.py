"""Direct-digital-synthesis (DDS) oscillator: phase accumulator + table lookup.

Fixed-point phase accumulator mirrored exactly to RTL: a ``phase_bits`` wide
counter incremented by a tuning word each sample, wrapped modulo 2**phase_bits.
``phase_sequence`` returns the phase *before* the increment so the RTL can
reproduce the identical index sequence.  Lookup supports integer "none" and
"linear" (fractional) interpolation.
"""
from __future__ import annotations

import math

import numpy as np


def freq_to_word(freq_hz: float, sr: int, phase_bits: int) -> int:
    """Phase increment (tuning word) for a target frequency, rounded to nearest."""
    return int(round(freq_hz / sr * (1 << phase_bits)))


def midi_to_freq(note: int) -> float:
    """MIDI note -> frequency (69 -> 440.0)."""
    return 440.0 * (2.0 ** ((note - 69) / 12.0))


def phase_sequence(freq_word: int, n: int, phase_bits: int) -> np.ndarray:
    """Per-sample phase *before* each increment, int64, wrapped mod 2**phase_bits.

    Sequence is 0, fw, 2*fw, ... so the RTL phase accumulator reproduces it
    bit-for-bit (all arithmetic done in uint64 and masked to phase_bits).
    """
    mask = (1 << phase_bits) - 1
    i = np.arange(n, dtype=np.uint64)
    ph = (i * np.uint64(freq_word)) & np.uint64(mask)
    return ph.astype(np.int64)


def lookup(table: np.ndarray, phase: np.ndarray, phase_bits: int,
           interp: str) -> np.ndarray:
    """Table lookup on phase.

    interp == "none":   idx = phase >> (phase_bits - log2(table_size)),
                        returns int64 table entries.
    interp == "linear": linear interpolation between adjacent entries using a
                        (phase_bits - log2(table_size))-bit fraction, returns
                        float64 normalized to [-1, 1].
    """
    table_size = int(len(table))
    log2_size = int(round(math.log2(table_size)))
    shift = phase_bits - log2_size
    p = np.asarray(phase, dtype=np.uint64)

    idx = (p >> np.uint64(shift)).astype(np.int64)

    if interp == "none":
        return table[idx].astype(np.int64)

    frac = (p & np.uint64((1 << shift) - 1)).astype(np.float64) / float(1 << shift)
    idx_next = (idx + 1) & (table_size - 1)
    y0 = table[idx].astype(np.float64)
    y1 = table[idx_next].astype(np.float64)
    full = float(np.max(np.abs(table)))
    if full <= 0.0:
        full = 1.0
    return (y0 + (y1 - y0) * frac) / full


class DDSOsc:
    """Stateful DDS oscillator producing float64 samples in [-1, 1]."""

    def __init__(self, table: np.ndarray, sr: int, phase_bits: int,
                 table_bits: int, interp: str = "linear"):
        self.table = table
        self.sr = int(sr)
        self.phase_bits = int(phase_bits)
        self.table_bits = int(table_bits)
        self.interp = interp
        self.mask = (1 << self.phase_bits) - 1
        self.full = float((1 << (self.table_bits - 1)) - 1)
        self.phase = 0
        self.freq_word = 0

    def set_freq(self, freq_hz: float) -> None:
        self.freq_word = freq_to_word(freq_hz, self.sr, self.phase_bits)

    def set_table(self, table: np.ndarray) -> None:
        self.table = table

    def step(self, n: int) -> np.ndarray:
        """n float64 samples in [-1, 1], advancing the accumulator."""
        if n <= 0:
            return np.empty(0, dtype=np.float64)

        i = np.arange(n, dtype=np.uint64)
        ph = (np.uint64(self.phase) + i * np.uint64(self.freq_word)) & np.uint64(self.mask)
        self.phase = int((self.phase + n * self.freq_word) & self.mask)

        out = lookup(self.table, ph.astype(np.int64), self.phase_bits, self.interp)
        if self.interp == "none":
            return out.astype(np.float64) / self.full
        return out.astype(np.float64)


if __name__ == "__main__":
    from synthsim.wavetable import generate_sine

    sr = 48000
    phase_bits = 32
    table_bits = 16
    table_size = 1024
    table = generate_sine(table_size, table_bits)

    print("=== dds self-test ===")

    # --- pitch accuracy: synth 440 Hz @ 48k, measure via FFT ---
    osc = DDSOsc(table, sr, phase_bits, table_bits, interp="linear")
    osc.set_freq(440.0)
    n = sr
    x = osc.step(n)

    win = np.hanning(n)
    X = np.abs(np.fft.rfft(x * win))
    k = int(np.argmax(X))
    if 0 < k < len(X) - 1:
        a, b, c = X[k - 1], X[k], X[k + 1]
        denom = a - 2.0 * b + c
        delta = 0.5 * (a - c) / denom if denom != 0.0 else 0.0
        peak_bin = k + delta
    else:
        peak_bin = float(k)
    freq_meas = peak_bin * sr / n
    err_hz = freq_meas - 440.0
    print("pitch: target=440.000 Hz measured={:.4f} Hz error={:+.4f} Hz"
          .format(freq_meas, err_hz))

    # --- THD of the 16-bit sine table (one cycle, harmonic analysis) ---
    s = table.astype(np.float64)
    S = np.abs(np.fft.rfft(s))
    fund = S[1] if len(S) > 1 else 0.0
    harm = S[2:]
    thd = float(np.sqrt(np.sum(harm ** 2)) / fund) if fund > 0.0 else float("inf")
    thd_db = 20.0 * math.log10(thd) if thd > 0.0 else -float("inf")
    print("sine-table THD = {:.6f}% ({:.2f} dB)".format(thd * 100.0, thd_db))

    # --- THD of the DDS-synthesized 440 Hz tone (incl. interpolation) ---
    Xfull = np.abs(np.fft.rfft(x))
    fbin = int(np.argmax(Xfull))
    f0 = fbin * sr / n
    harm_pow = 0.0
    for m in range(2, int((sr / 2.0) / f0) + 1):
        b = int(round(m * fbin))
        if 0 <= b < len(Xfull):
            harm_pow += Xfull[b] ** 2
    dds_thd = float(np.sqrt(harm_pow) / Xfull[fbin]) if Xfull[fbin] > 0.0 else float("inf")
    print("DDS-440Hz THD = {:.6f}% ({:.2f} dB)".format(
        dds_thd * 100.0, 20.0 * math.log10(dds_thd) if dds_thd > 0 else -float("inf")))

    # --- sanity: midi + phase_sequence wrap ---
    print("midi_to_freq(69) = {:.2f} Hz".format(midi_to_freq(69)))
    fw = freq_to_word(440.0, sr, phase_bits)
    seq = phase_sequence(fw, 4, phase_bits)
    print("freq_word(440Hz) = {}  first phases = {}".format(fw, list(seq)))
    print("dds OK")
