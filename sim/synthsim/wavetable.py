"""Wavetable generation, band-limited mip-mapping, and .mem export.

Golden reference for the RTL wavetable ROM contents.  All tables are single
periods stored as signed ``int64`` with full-scale ``2**(table_bits-1)-1``.
A mip-map keeps a bright (many-harmonic) table for low notes and progressively
darker tables for high notes so the highest retained harmonic always stays
below Nyquist (anti-aliasing by band-limiting, not by filtering).
"""
from __future__ import annotations

import os
from typing import List

import numpy as np


def generate_sine(table_size: int, table_bits: int) -> np.ndarray:
    """Single-cycle sine, int64 signed, full-scale = 2**(table_bits-1)-1."""
    full = (1 << (table_bits - 1)) - 1
    phase = 2.0 * np.pi * np.arange(table_size, dtype=np.float64) / table_size
    wave = np.sin(phase) * full
    return np.clip(np.round(wave), -full, full).astype(np.int64)


def generate_bandlimited(kind: str, table_size: int, table_bits: int,
                         max_harmonics: int) -> np.ndarray:
    """Band-limited waveform by harmonic summation (Gibbs ripple included).

    kind in {"saw", "square", "triangle"}:
      saw      : sum_{k=1..H} sin(2*pi*k*t) / k
      square   : sum_{odd k<=H} sin(2*pi*k*t) / k
      triangle : sum_{odd k<=H} (-1)^((k-1)/2) * sin(2*pi*k*t) / k^2

    Normalized to near full-scale, then rounded + clipped to int64.
    """
    if kind not in ("saw", "square", "triangle"):
        raise ValueError("kind must be one of 'saw', 'square', 'triangle'")

    full = (1 << (table_bits - 1)) - 1
    t = np.arange(table_size, dtype=np.float64) / table_size
    wave = np.zeros(table_size, dtype=np.float64)

    if kind == "saw":
        for k in range(1, max_harmonics + 1):
            wave += np.sin(2.0 * np.pi * k * t) / k
    elif kind == "square":
        for k in range(1, max_harmonics + 1, 2):
            wave += np.sin(2.0 * np.pi * k * t) / k
    else:  # triangle
        for k in range(1, max_harmonics + 1, 2):
            sign = (-1.0) ** ((k - 1) // 2)
            wave += sign * np.sin(2.0 * np.pi * k * t) / (k * k)

    peak = float(np.max(np.abs(wave)))
    if peak > 0.0:
        wave = wave / peak
    wave = wave * full
    return np.clip(np.round(wave), -full, full).astype(np.int64)


def build_mipmap(kind: str, table_size: int, table_bits: int,
                 mip_octaves: int, base_max_harmonics: int) -> List[np.ndarray]:
    """mip_octaves tables; level k keeps max(1, base_max_harmonics >> k) harmonics."""
    return [
        generate_bandlimited(kind, table_size, table_bits,
                             max(1, base_max_harmonics >> k))
        for k in range(mip_octaves)
    ]


def select_mip(freq_hz: float, sr: int, mip_octaves: int,
               base_max_harmonics: int) -> int:
    """Smallest level k in [0, mip_octaves-1] with max_harmonics*freq < sr/2."""
    nyq = sr / 2.0
    for k in range(mip_octaves):
        if max(1, base_max_harmonics >> k) * freq_hz < nyq:
            return k
    return mip_octaves - 1


def write_mem(tables: List[np.ndarray], path: str, table_bits: int,
              table_size: int, name: str) -> None:
    """Flatten all tables into a signed two's-complement hex .mem, one value/line."""
    mask = (1 << table_bits) - 1
    width = max(1, table_bits // 4)
    lines = [
        "// {} wavetable mipmap".format(name),
        "// mip_count = {}".format(len(tables)),
        "// per_level_length = {}".format(table_size),
        "// bit_width = {}".format(table_bits),
    ]
    for tbl in tables:
        for v in tbl:
            lines.append("{:0{}X}".format(int(v) & mask, width))

    directory = os.path.dirname(path)
    if directory and not os.path.isdir(directory):
        os.makedirs(directory, exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    table_size = 1024
    table_bits = 16
    mip_octaves = 8
    base = 512

    print("=== wavetable self-test ===")
    for kind in ("saw", "square", "triangle"):
        tables = build_mipmap(kind, table_size, table_bits, mip_octaves, base)
        print("kind={}  mip_count={}".format(kind, len(tables)))
        for k, tbl in enumerate(tables):
            h = max(1, base >> k)
            peak = int(np.max(np.abs(tbl)))
            rms = float(np.sqrt(np.mean(tbl.astype(np.float64) ** 2)))
            dc = float(np.mean(tbl.astype(np.float64)))
            print("  level={} max_harmonics={:3d} peak={:5d} rms={:7.1f} dc={:+.5f}"
                  .format(k, h, peak, rms, dc))

    sine = generate_sine(table_size, table_bits)
    print("sine: peak={} rms={:.1f} dc={:+.5f}"
          .format(int(np.max(np.abs(sine))),
                  float(np.sqrt(np.mean(sine.astype(np.float64) ** 2))),
                  float(np.mean(sine.astype(np.float64)))))

    print("select_mip(freq) @48k:")
    for f in (100.0, 200.0, 440.0, 1000.0, 5000.0, 12000.0, 20000.0):
        print("  freq={:>8.1f} Hz -> level {}".format(f, select_mip(f, 48000, mip_octaves, base)))

    mem_path = os.path.join("out", "wavetable_saw.mem")
    write_mem(build_mipmap("saw", table_size, table_bits, mip_octaves, base),
              mem_path, table_bits, table_size, "saw")
    with open(mem_path) as f:
        n_lines = sum(1 for _ in f)
    print("wrote {} ({} lines)".format(mem_path, n_lines))
    print("wavetable OK")
