"""ADSR envelope for the polyphonic synth golden model.

Provides two interfaces over the same shape math:

  * :func:`adsr_envelope` -- one-shot generation of a complete envelope
    (attack -> decay -> sustain -> optional release) over ``n`` samples;
  * :class:`ADSREnv` -- a stateful streaming envelope used by the voice
    chain (``note_on`` / ``note_off`` / ``step``).

All outputs are float64 in [0, 1] (peak normalized to 1.0 unless a velocity
peak is supplied).  ``curve`` selects linear ("lin") or exponential ("exp")
segment shapes.  Exponential segments are normalized so their endpoints are
exact: the attack reaches exactly ``peak`` and the release ends exactly at 0.
"""
from __future__ import annotations

from typing import Optional

import numpy as np

_EXP_K = 4.0  # exponential curvature constant (higher = sharper knee)


def _interp(t: np.ndarray, curve: str) -> np.ndarray:
    """Normalized 0 -> 1 segment shape: linear, or exponential fast-then-slow.

    The exponential shape is normalized so that ``_interp(1) == 1.0`` exactly,
    which keeps every segment's endpoint (and the whole-envelope peak) exact.
    """
    if curve == "lin":
        return t
    return (1.0 - np.exp(-_EXP_K * t)) / (1.0 - np.exp(-_EXP_K))


class ADSREnv:
    """Stateful streaming ADSR envelope (float64, [0, 1] nominal)."""

    IDLE = "IDLE"
    ATTACK = "ATTACK"
    DECAY = "DECAY"
    SUSTAIN = "SUSTAIN"
    RELEASE = "RELEASE"

    def __init__(self, sr: int, attack_ms: float, decay_ms: float,
                 sustain: float, release_ms: float,
                 env_bits: int = 16, curve: str = "exp"):
        if curve not in ("lin", "exp"):
            raise ValueError("curve must be 'lin' or 'exp'")
        self.sr = int(sr)
        self._attack_n = max(1, int(round(attack_ms * sr / 1000.0)))
        self._decay_n = max(1, int(round(decay_ms * sr / 1000.0)))
        self._release_n = max(1, int(round(release_ms * sr / 1000.0)))
        self._sustain = float(sustain)
        self.env_bits = int(env_bits)
        self.curve = curve

        self._state = self.IDLE
        self._pos = 0
        self._peak = 1.0
        self._level = 0.0
        self._release_from = 0.0

    def note_on(self, velocity: float = 1.0) -> None:
        """(Re)trigger the envelope from silence; ``velocity`` sets the peak."""
        self._peak = float(velocity)
        self._state = self.ATTACK
        self._pos = 0
        self._level = 0.0
        self._release_from = 0.0

    def note_off(self) -> None:
        """Start the release from the current level (no-op if already released)."""
        if self._state in (self.ATTACK, self.DECAY, self.SUSTAIN):
            self._release_from = self._level
            self._state = self.RELEASE
            self._pos = 0

    def step(self, n: int) -> np.ndarray:
        """Emit ``n`` envelope samples, advancing the state machine."""
        n = int(n)
        out = np.zeros(n, dtype=np.float64)
        written = 0
        while written < n:
            state = self._state
            if state == self.IDLE:
                out[written:] = 0.0
                self._level = 0.0
                written = n
            elif state == self.ATTACK:
                written = self._emit(out, written, n, self._attack_n,
                                     0.0, self._peak, self.DECAY)
            elif state == self.DECAY:
                written = self._emit(out, written, n, self._decay_n,
                                     self._peak, self._sustain * self._peak,
                                     self.SUSTAIN)
            elif state == self.SUSTAIN:
                take = n - written
                out[written:written + take] = self._sustain * self._peak
                self._level = self._sustain * self._peak
                written += take
            elif state == self.RELEASE:
                written = self._emit(out, written, n, self._release_n,
                                     self._release_from, 0.0, self.IDLE)
        return out

    def _emit(self, out: np.ndarray, written: int, n: int, length: int,
              a: float, b: float, next_state: str) -> int:
        """Fill ``out[written:n)`` from a segment of ``length`` samples, a -> b."""
        take = min(length - self._pos, n - written)
        denom = float(max(length - 1, 1))
        t = (self._pos + np.arange(take, dtype=np.float64)) / denom
        seg = a + (b - a) * _interp(t, self.curve)
        out[written:written + take] = seg
        self._level = float(seg[-1])
        self._pos += take
        written += take
        if self._pos >= length:
            self._state = next_state
            self._pos = 0
            if next_state == self.IDLE:
                self._level = 0.0
        return written

    @property
    def active(self) -> bool:
        """True unless idle (including after the release has finished)."""
        return self._state != self.IDLE

    @property
    def level(self) -> float:
        """Current envelope level (used by the "weakest" steal policy)."""
        return self._level


def adsr_envelope(n: int, sr: int, attack_ms: float, decay_ms: float,
                  sustain: float, release_ms: float,
                  note_off_sample: Optional[int] = None,
                  curve: str = "exp") -> np.ndarray:
    """One-shot full ADSR over ``n`` samples, float64 in [0, 1].

    ``note_off_sample=None`` means no release: the envelope holds sustain to
    the end of the window.  Otherwise the release begins at that sample index
    (clipped to the window) and decays toward 0.
    """
    env = ADSREnv(sr, attack_ms, decay_ms, sustain, release_ms, curve=curve)
    n = int(n)
    env.note_on(1.0)
    if note_off_sample is None:
        return env.step(n)
    off = int(note_off_sample)
    if off >= n:
        return env.step(n)
    out = np.zeros(n, dtype=np.float64)
    if off > 0:
        out[:off] = env.step(off)
    env.note_off()
    out[off:] = env.step(n - off)
    return out


if __name__ == "__main__":
    from .params import PARAMS_48K

    p = PARAMS_48K
    sr = p.sr
    attack_n = int(round(p.adsr_attack_ms * sr / 1000.0))
    decay_n = int(round(p.adsr_decay_ms * sr / 1000.0))
    release_n = int(round(p.adsr_release_ms * sr / 1000.0))
    sustain_ms = 300.0
    sustain_n = int(round(sustain_ms * sr / 1000.0))
    note_off = attack_n + decay_n + sustain_n
    total = note_off + release_n

    env = adsr_envelope(total, sr, p.adsr_attack_ms, p.adsr_decay_ms,
                        p.adsr_sustain, p.adsr_release_ms,
                        note_off_sample=note_off, curve=p.adsr_curve)

    peak = float(env.max())
    sustain_region = env[attack_n + decay_n: note_off]
    sustain_val = float(sustain_region[0])
    sustain_ok = bool(np.allclose(sustain_region, p.adsr_sustain, atol=1e-12))
    release_end = float(env[-1])

    print("adsr self-test")
    print("sr = {}, curve = {}".format(sr, p.adsr_curve))
    print("attack_n  = {} samples ({:.1f} ms)".format(attack_n, p.adsr_attack_ms))
    print("decay_n   = {} samples ({:.1f} ms)".format(decay_n, p.adsr_decay_ms))
    print("sustain_n = {} samples ({:.1f} ms)".format(sustain_n, sustain_ms))
    print("release_n = {} samples ({:.1f} ms)".format(release_n, p.adsr_release_ms))
    print("total     = {} samples".format(total))
    print("peak          = {:.12f}".format(peak))
    print("sustain level = {:.12f} (target {})".format(sustain_val, p.adsr_sustain))
    print("release end   = {:.12f}".format(release_end))

    assert peak == 1.0, "peak {} != 1.0".format(peak)
    assert sustain_ok, "sustain plateau != sustain"
    assert abs(release_end) < 1e-9, "release end {} not ~0".format(release_end)
    print("checks passed: peak == 1.0, sustain plateau == sustain, release -> 0")

    # streaming class equivalence check (one-shot == ADSREnv replay)
    env2 = ADSREnv(sr, p.adsr_attack_ms, p.adsr_decay_ms, p.adsr_sustain,
                   p.adsr_release_ms, curve=p.adsr_curve)
    env2.note_on(1.0)
    buf = env2.step(note_off)
    env2.note_off()
    buf = np.concatenate([buf, env2.step(release_n)])
    assert np.allclose(buf, env, atol=1e-12), "streaming != one-shot"
    print("streaming ADSREnv matches one-shot envelope: OK")

    # optional plot (Agg, English labels)
    try:
        import os
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        out_dir = r"E:\26Embedded\sim\out"
        os.makedirs(out_dir, exist_ok=True)
        t_ms = np.arange(total, dtype=np.float64) * 1000.0 / sr
        seg_edges = [0, attack_n, attack_n + decay_n, note_off, total]
        labels = ["Attack", "Decay", "Sustain", "Release"]

        plt.figure(figsize=(10, 4))
        plt.plot(t_ms, env, lw=1.5, color="#1f77b4")
        for x in seg_edges[1:-1]:
            plt.axvline(x * 1000.0 / sr, color="gray", ls="--", lw=0.8)
        for (x0, x1), label in zip(zip(seg_edges[:-1], seg_edges[1:]), labels):
            xm = (x0 + x1) * 1000.0 / sr / 2.0
            plt.annotate(label, (xm, 0.55), ha="center", fontsize=10)
        plt.xlabel("Time (ms)")
        plt.ylabel("Envelope level")
        plt.title("ADSR envelope: attack / decay / sustain / release")
        plt.ylim(-0.05, 1.05)
        plt.tight_layout()
        path = os.path.join(out_dir, "adsr.png")
        plt.savefig(path, dpi=120)
        plt.close()
        print("saved {}".format(path))
    except Exception as exc:  # plotting is optional, never fatal
        print("plot skipped: {!r}".format(exc))

    print("adsr OK")
