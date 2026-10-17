"""Targeted requirement checks for the golden model (fpga_ben workspace).

Verifies the four things the competition explicitly cares about:
  1. >=32 independent oscillators in TEST MODE            (scoring rule 3)
  2. real-time pitch change on a single note (portamento) (base requirement 3)
  3. >=2 switchable instrument timbres                    (extension 2)
  4. hardware-style effects: delay / chorus / reverb      (extension 2)

Run (from E:\\26Embedded\\fpga_ben\\sim):
    python scripts\\verify_targeted.py
"""
from __future__ import annotations

import importlib.util
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from synthsim.params import PARAMS_48K  # noqa: E402
from synthsim import dds, effects, testmode, wavetable  # noqa: E402


def check_32voice() -> bool:
    p = PARAMS_48K
    x = testmode.synth_test_tones(p)
    r = testmode.analyze_peaks(x, p.sr, p.test_tones, p.test_f0_hz, p.test_spacing_hz)
    ok = bool(r["ok"])
    print("[1] 32-osc test mode : detected %d / expected %d -> %s"
          % (r["detected"], r["expected"], "PASS" if ok else "FAIL"))
    return ok


def check_pitch_change() -> bool:
    p = PARAMS_48K
    sine = wavetable.generate_sine(p.table_size, p.table_bits)
    osc = dds.DDSOsc(sine, p.sr, p.phase_bits, p.table_bits, interp=p.interp)
    block = int(0.02 * p.sr)                      # 20 ms blocks
    n_steps = int(0.5 / (block / p.sr))           # glide over 0.5 s
    segs = []
    for i in range(n_steps):                      # portamento 440 -> 880 Hz
        osc.set_freq(440.0 + (880.0 - 440.0) * i / n_steps)
        segs.append(osc.step(block))
    osc.set_freq(880.0)                           # settle exactly at 880 Hz
    hold = osc.step(int(0.3 * p.sr))
    x = np.concatenate(segs + [hold])

    N = 1 << 16
    sp = np.abs(np.fft.rfft(hold * np.hanning(len(hold)), N))
    fr = np.fft.rfftfreq(N, 1.0 / p.sr)
    k = int(np.argmax(sp))
    a, b, c = sp[k - 1], sp[k], sp[k + 1]
    d = 0.5 * (a - c) / (a - 2 * b + c)
    pitch = fr[k] + d * (fr[1] - fr[0])

    maxjump = float(np.max(np.abs(np.diff(x))))
    sine_bound = 2.0 * np.pi * 880.0 / p.sr
    ok = abs(pitch - 880.0) < 5.0 and maxjump < 1.5 * sine_bound
    print("[2] real-time pitch bend: final %.1f Hz (target 880), max sample jump %.4f "
          "(sine bound %.4f) -> %s" % (pitch, maxjump, sine_bound, "PASS" if ok else "FAIL"))
    return ok


def check_timbres() -> bool:
    spec = importlib.util.spec_from_file_location("dt", os.path.join(HERE, "demo_timbres.py"))
    dt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(dt)  # type: ignore[union-attr]
    rows = []
    for name, fn in (("organ", dt.synth_organ), ("musicbox", dt.synth_musicbox),
                     ("epiano", dt.synth_epiano)):
        y = fn(440.0, 0.4, 0.9)
        sp = np.abs(np.fft.rfft(y * np.hanning(len(y))))
        fr = np.fft.rfftfreq(len(y), 1.0 / dt.SR)
        rows.append((name, float(np.max(np.abs(y))), float((fr * sp).sum() / sp.sum())))
    ok = len(rows) >= 2 and all(pk > 0.05 for _, pk, _ in rows)
    print("[3] timbres (>=2)     : " + ", ".join(
        "%s peak=%.2f centroid=%.0fHz" % (n, pk, c) for n, pk, c in rows))
    print("                        -> %s" % ("PASS" if ok else "FAIL"))
    return ok


def check_effects() -> bool:
    p = PARAMS_48K
    t = np.arange(int(0.3 * p.sr)) / p.sr
    x = 0.5 * np.sin(2.0 * np.pi * 440.0 * t)
    outs = {
        "delay": effects.delay(x, p.sr, 180.0, 0.4, 0.3),
        "chorus": effects.chorus(x, p.sr),
        "reverb": effects.reverb_schroeder(x, p.sr),
    }
    ok = True
    for k, v in outs.items():
        fin = bool(np.isfinite(v).all())
        inrange = float(np.max(np.abs(v))) <= 1.0 + 1e-6
        ok = ok and fin and inrange
        print("      %-7s peak=%.3f finite=%s in-range=%s"
              % (k, float(np.max(np.abs(v))), fin, inrange))
    print("[4] effects           : -> %s" % ("PASS" if ok else "FAIL"))
    return ok


if __name__ == "__main__":
    res = [check_32voice(), check_pitch_change(), check_timbres(), check_effects()]
    print("\nSUMMARY:", "ALL PASS" if all(res) else "some FAILED")
    sys.exit(0 if all(res) else 1)
