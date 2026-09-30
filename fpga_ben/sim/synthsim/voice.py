"""Voice -- one polyphonic voice: oscillator x ADSR envelope x velocity.

Depends on :mod:`synthsim.dds` (``DDSOsc``), which is owned by a parallel
agent.  The import is defensive: if ``dds`` is missing the module still
imports with ``DDSOsc = None``, and constructing a ``Voice`` raises a clear
``RuntimeError``.  The ``__main__`` self-test prints a skip message and exits 0
when ``dds`` is absent.
"""
from __future__ import annotations

import numpy as np

try:
    from .dds import DDSOsc
except ImportError:  # pragma: no cover - only if dds not built yet
    DDSOsc = None

from .adsr import ADSREnv
from .params import SynthParams


class Voice:
    """A single synth voice: DDS oscillator -> ADSR envelope -> velocity gain.

    ``step(n)`` returns ``osc * env * velocity`` in float64 [-1, 1].  The
    envelope is normalized to [0, 1] and the velocity is applied as a separate
    output gain so the RTL's three-term product (osc * env * velocity) maps
    one-to-one -- velocity is applied exactly once, never twice.
    """

    def __init__(self, table: np.ndarray, params: SynthParams,
                 curve: str = "exp"):
        if DDSOsc is None:
            raise RuntimeError(
                "Voice requires synthsim.dds.DDSOsc, which is not built yet "
                "(build the oscillator module first)"
            )
        self.params = params
        self.osc = DDSOsc(table, params.sr, params.phase_bits,
                          params.table_bits, params.interp)
        self.env = ADSREnv(params.sr, params.adsr_attack_ms, params.adsr_decay_ms,
                           params.adsr_sustain, params.adsr_release_ms,
                           params.env_bits, curve)
        self._velocity = 0.0
        self.note = None        # midi note, settable by the allocator
        self.start_time = 0.0   # sample clock at note_on, settable by the allocator

    def note_on(self, freq_hz: float, velocity: float = 1.0) -> None:
        self.osc.set_freq(freq_hz)
        self._velocity = float(velocity)
        self.env.note_on(1.0)   # envelope normalized to [0, 1]

    def note_off(self) -> None:
        self.env.note_off()

    def step(self, n: int) -> np.ndarray:
        """n samples of ``osc * env * velocity`` in float64 [-1, 1]."""
        osc = self.osc.step(n)
        env = self.env.step(n)
        return osc * env * self._velocity

    @property
    def active(self) -> bool:
        return self.env.active

    @property
    def level(self) -> float:
        """Current envelope level (used by the "weakest" steal policy)."""
        return self.env.level


if __name__ == "__main__":
    if DDSOsc is None:
        print("self-test skipped: synthsim.dds not built yet")
        raise SystemExit(0)

    from .params import PARAMS_48K
    from .wavetable import generate_sine

    p = PARAMS_48K
    table = generate_sine(p.table_size, p.table_bits)

    v = Voice(table, p)
    print("voice self-test")
    v.note_on(440.0, 0.8)
    buf = v.step(p.sr)          # 1 second of attack -> decay -> sustain
    peak = float(np.max(np.abs(buf)))
    print("note_on(440, 0.8): active={} level~{:.3f} peak={:.6f}".format(
        v.active, v.level, peak))
    assert v.active
    assert peak <= 1.0 + 1e-3, "voice peak {} exceeded 1.0".format(peak)

    v.note_off()
    tail = v.step(p.sr)         # release (180 ms) finishes well within 1 s
    print("after note_off + release: active={} level={:.6f}".format(
        v.active, v.level))
    assert not v.active
    print("voice checks passed")
    print("voice OK")
