"""Voice allocator -- maps MIDI note on/off events onto a fixed voice pool.

Depends on :mod:`synthsim.voice` (``Voice``) and :mod:`synthsim.dds`
(``midi_to_freq``), both owned by parallel agents.  Imports are defensive: if
they are missing the module still imports with ``Voice = None`` /
``midi_to_freq = None``, construction raises a clear ``RuntimeError``, and the
``__main__`` self-test prints a skip message and exits 0.
"""
from __future__ import annotations

from typing import Optional

import numpy as np

from .mixer import mix_sum

try:
    from .voice import Voice
except ImportError:  # pragma: no cover - only if voice/dds not built yet
    Voice = None

try:
    from .dds import midi_to_freq
except ImportError:  # pragma: no cover - only if dds not built yet
    midi_to_freq = None


class VoiceAllocator:
    """Allocates MIDI notes to a fixed pool of voices, with voice stealing."""

    def __init__(self, params, table, n_voices: Optional[int] = None,
                 policy: str = "oldest"):
        if Voice is None:
            raise RuntimeError(
                "VoiceAllocator requires synthsim.voice.Voice, which requires "
                "synthsim.dds (not built yet)"
            )
        if midi_to_freq is None:
            raise RuntimeError(
                "VoiceAllocator requires synthsim.dds.midi_to_freq (not built yet)"
            )
        if policy not in ("oldest", "weakest"):
            raise ValueError("policy must be 'oldest' or 'weakest'")
        self.params = params
        self.policy = policy
        self.n_voices = int(params.max_voices if n_voices is None else n_voices)
        self.voices = [Voice(table, params) for _ in range(self.n_voices)]
        self._clock = 0

    def note_on(self, midi_note: int, velocity: float = 1.0) -> int:
        """Allocate a voice for ``midi_note`` and return its index.

        Prefers a free (idle) voice; when none is free, steals by ``policy``:
        "oldest" (smallest ``start_time``) or "weakest" (smallest ``level``).
        """
        freq = midi_to_freq(midi_note)
        for i, v in enumerate(self.voices):
            if not v.active:
                self._start_voice(v, midi_note, freq, velocity)
                return i
        if self.policy == "oldest":
            i = int(np.argmin([v.start_time for v in self.voices]))
        else:  # weakest
            i = int(np.argmin([v.level for v in self.voices]))
        self._start_voice(self.voices[i], midi_note, freq, velocity)
        return i

    def _start_voice(self, v, midi_note, freq_hz, velocity) -> None:
        v.note = midi_note
        v.start_time = self._clock
        v.note_on(freq_hz, velocity)

    def note_off(self, midi_note: int) -> None:
        """Release every voice currently playing ``midi_note``."""
        for v in self.voices:
            if v.note == midi_note:
                v.note_off()

    def render(self, n: int) -> np.ndarray:
        """Render ``n`` mixed samples (float64 [-1, 1]) via the mixer."""
        n = int(n)
        active = [v for v in self.voices if v.active]
        if not active:
            self._clock += n
            return np.zeros(n, dtype=np.float64)
        signals = [v.step(n) for v in active]
        self._clock += n
        return mix_sum(signals, self.params.voice_gain_shift,
                       saturate=self.params.saturate)

    def active_count(self) -> int:
        """Number of currently active (sounding) voices."""
        return sum(1 for v in self.voices if v.active)


if __name__ == "__main__":
    if Voice is None or midi_to_freq is None:
        print("self-test skipped: synthsim.dds / voice not built yet")
        raise SystemExit(0)

    from .params import PARAMS_48K
    from .wavetable import generate_sine

    p = PARAMS_48K
    table = generate_sine(p.table_size, p.table_bits)

    print("allocator self-test (policy=oldest, shift={})".format(p.voice_gain_shift))

    # --- 4-note chord (C major) -------------------------------------------
    alloc = VoiceAllocator(p, table, policy="oldest")
    chord4 = [60, 64, 67, 71]
    for note in chord4:
        alloc.note_on(note, 1.0)
    print("4-note chord: active_count = {} (expected 4)".format(alloc.active_count()))
    buf4 = alloc.render(int(0.5 * p.sr))
    peak4 = float(np.max(np.abs(buf4)))
    print("4-note mixed peak = {:.6f}".format(peak4))
    assert alloc.active_count() == 4
    assert peak4 <= 1.0 + 1e-9

    for note in chord4:
        alloc.note_off(note)
    alloc.render(int(0.5 * p.sr))  # let release finish
    print("after note_off: active_count = {} (expected 0)".format(alloc.active_count()))
    assert alloc.active_count() == 0

    # --- 32-note chord -----------------------------------------------------
    chord32 = list(range(48, 80))
    for note in chord32:
        alloc.note_on(note, 1.0)
    print("32-note chord: active_count = {} (expected 32)".format(alloc.active_count()))
    buf32 = alloc.render(int(1.0 * p.sr))
    peak32 = float(np.max(np.abs(buf32)))
    print("32-note mixed peak = {:.6f} (< 1.0 required)".format(peak32))
    assert alloc.active_count() == 32
    assert peak32 < 1.0 + 1e-9

    # --- stealing sanity ---------------------------------------------------
    chord32b = list(range(80, 112))  # 32 more notes: must steal all 32 voices
    for note in chord32b:
        alloc.note_on(note, 1.0)
    print("after 32 extra notes: active_count = {} (still 32, all stolen)".format(
        alloc.active_count()))
    assert alloc.active_count() == 32

    print("allocator checks passed")
    print("allocator OK")
