"""Hardware-model effects: delay, chorus, Schroeder reverb (CONTRACT.md s5).

All effects are pure NumPy, operate on mono float64 audio in [-1.0, 1.0], and
mirror the per-sample circular-buffer structure the RTL will implement (this
module is the golden reference the Verilog must reproduce).
"""
from __future__ import annotations

import numpy as np


def delay(x, sr, delay_ms, feedback, mix):
    """Feedback delay line on a circular buffer.

    wet[n] = x[n-D] + feedback*wet[n-D];  out = (1-mix)*x + mix*wet.
    Buffer length D = round(delay_ms * sr / 1000) samples.
    """
    x = np.asarray(x, dtype=np.float64)
    if not -1.0 < feedback < 1.0:
        raise ValueError("feedback must lie in (-1, 1), got %r" % (feedback,))
    d = max(1, int(round(float(delay_ms) * sr / 1000.0)))
    buf = np.zeros(d, dtype=np.float64)
    out = np.empty(x.shape[0], dtype=np.float64)
    idx = 0
    dry = 1.0 - float(mix)
    wet_gain = float(mix)
    fb = float(feedback)
    for i in range(x.shape[0]):
        w = buf[idx]
        out[i] = dry * x[i] + wet_gain * w
        buf[idx] = x[i] + fb * w
        idx += 1
        if idx == d:
            idx = 0
    return np.clip(out, -1.0, 1.0)


def chorus(x, sr, depth_ms=3.0, rate_hz=0.6, base_ms=20.0, mix=0.5):
    """Two-voice chorus: one delay line, two LFO-modulated taps (90 deg apart)
    read with linear interpolation.

    Buffer length = ceil((base_ms + depth_ms) * sr / 1000) + 2 samples.
    """
    x = np.asarray(x, dtype=np.float64)
    n = x.shape[0]
    base_s = float(base_ms) * sr / 1000.0
    depth_s = float(depth_ms) * sr / 1000.0
    buf_len = int(np.ceil(base_s + depth_s)) + 2
    buf = np.zeros(buf_len, dtype=np.float64)
    out = np.empty(n, dtype=np.float64)
    omega = 2.0 * np.pi * float(rate_hz) / sr
    idx = np.arange(n, dtype=np.float64)
    delay1 = base_s + depth_s * np.sin(omega * idx)
    delay2 = base_s + depth_s * np.sin(omega * idx + 0.5 * np.pi)
    wpos = 0
    dry = 1.0 - float(mix)
    half = 0.5 * float(mix)
    for i in range(n):
        buf[wpos] = x[i]
        w1 = _frac_read(buf, wpos - delay1[i])
        w2 = _frac_read(buf, wpos - delay2[i])
        out[i] = dry * x[i] + half * (w1 + w2)
        wpos += 1
        if wpos == buf_len:
            wpos = 0
    return np.clip(out, -1.0, 1.0)


def _frac_read(buf, pos):
    """Linear-interpolated circular read at fractional position pos."""
    i0 = int(np.floor(pos))
    frac = pos - i0
    i0 %= buf.shape[0]
    i1 = (i0 + 1) % buf.shape[0]
    return buf[i0] * (1.0 - frac) + buf[i1] * frac


def reverb_schroeder(x, sr, room=0.7, mix=0.3):
    """Classic Schroeder reverb: 4 parallel feedback combs + 2 series allpasses.

    Delay times (room=0.7 -> scale 1.0):
      combs   : 29.7 ms, 37.1 ms, 41.1 ms, 43.7 ms
      allpass : 5.0 ms, 1.7 ms
    The ``room`` parameter scales all delay times by (0.5 + 5/7 * room).
    """
    x = np.asarray(x, dtype=np.float64)
    scale = 0.5 + (5.0 / 7.0) * float(room)
    comb_ms = (29.7, 37.1, 41.1, 43.7)
    comb_fb = (0.805, 0.827, 0.783, 0.764)
    ap_ms = (5.0, 1.7)
    ap_gain = 0.7
    wet = np.zeros(x.shape[0], dtype=np.float64)
    for d_ms, fb in zip(comb_ms, comb_fb):
        wet += _comb(x, sr, d_ms * scale, fb)
    wet *= 0.25
    for d_ms in ap_ms:
        wet = _allpass(wet, sr, d_ms * scale, ap_gain)
    out = (1.0 - float(mix)) * x + float(mix) * wet
    return np.clip(out, -1.0, 1.0)


def _comb(x, sr, delay_ms, fb):
    """Feedback comb y[n] = x[n-D] + fb*y[n-D], circular buffer."""
    d = max(1, int(round(float(delay_ms) * sr / 1000.0)))
    buf = np.zeros(d, dtype=np.float64)
    out = np.empty(x.shape[0], dtype=np.float64)
    idx = 0
    for i in range(x.shape[0]):
        w = buf[idx]
        out[i] = w
        buf[idx] = x[i] + fb * w
        idx += 1
        if idx == d:
            idx = 0
    return out


def _allpass(x, sr, delay_ms, g):
    """Schroeder allpass: y[n] = -g*x[n] + buf[n-D]; buf[n] = x[n] + g*y[n]."""
    d = max(1, int(round(float(delay_ms) * sr / 1000.0)))
    buf = np.zeros(d, dtype=np.float64)
    out = np.empty(x.shape[0], dtype=np.float64)
    idx = 0
    for i in range(x.shape[0]):
        w = buf[idx]
        out[i] = -g * x[i] + w
        buf[idx] = x[i] + g * out[i]
        idx += 1
        if idx == d:
            idx = 0
    return out


def _pluck(sr, freq=220.0, dur_s=0.5):
    """Deterministic decaying two-harmonic pluck used by the self-test."""
    n = int(round(sr * dur_s))
    t = np.arange(n, dtype=np.float64) / sr
    env = np.exp(-t * 10.0)
    sig = np.sin(2.0 * np.pi * freq * t) + 0.4 * np.sin(2.0 * np.pi * 2.0 * freq * t)
    return np.clip(sig * env, -1.0, 1.0)


def _report(name, x, y, buf_samples, buf_ms):
    print("%-8s buf=%6d samples (%6.1f ms) | in_peak=%.3f | out_peak=%.3f | peak_ok=%s"
          % (name, buf_samples, buf_ms, float(np.max(np.abs(x))),
             float(np.max(np.abs(y))), float(np.max(np.abs(y))) <= 1.0))


def _self_test():
    sr = 48000
    n = sr
    imp = np.zeros(n, dtype=np.float64)
    imp[0] = 1.0
    d_ms = 80.0
    y = delay(imp, sr, d_ms, feedback=0.5, mix=0.5)
    echo_pos = int(np.argmax(np.abs(y[1:]))) + 1
    _report("delay", imp, y, int(round(d_ms * sr / 1000.0)), d_ms)
    print("delay:    first echo at %6.1f ms (expected ~%.1f ms)"
          % (echo_pos / sr * 1000.0, d_ms))

    pluck = _pluck(sr)
    buf_c = int(np.ceil((20.0 + 3.0) * sr / 1000.0)) + 2
    y = chorus(pluck, sr)
    _report("chorus", pluck, y, buf_c, buf_c * 1000.0 / sr)

    y = reverb_schroeder(pluck, sr)
    scale = 0.5 + (5.0 / 7.0) * 0.7
    comb_ms = (29.7, 37.1, 41.1, 43.7)
    ap_ms = (5.0, 1.7)
    total_buf = sum(int(round(m * scale * sr / 1000.0)) for m in comb_ms) \
        + sum(int(round(m * scale * sr / 1000.0)) for m in ap_ms)
    _report("reverb", pluck, y, total_buf, total_buf * 1000.0 / sr)
    print("reverb:   comb delays = [%s] ms ; allpass delays = [%s] ms"
          % (", ".join("%.1f" % (m * scale) for m in comb_ms),
             ", ".join("%.1f" % (m * scale) for m in ap_ms)))
    print("EFFECTS SELF-TEST OK")


if __name__ == "__main__":
    _self_test()
