"""Real-time streaming synth demo: organ / music box / electric piano.

Block-streaming polyphonic engine (sounddevice). Every sample is synthesized in
the audio callback - no pre-rendered PCM (same rule as the FPGA target).

Timbres (researched, physically-informed):
  * ORGAN      - 9 drawbars + 6th-harmonic key click + 5 Hz tonewheel tremolo
                 + Leslie rotary (amplitude modulation + Doppler).
  * MUSIC BOX  - struck-bar modal model (inharmonic partials w/ per-mode decay)
                 + ~11 ms onset timing jitter.
  * E.PIANO    - DX7-style FM: 1:1 body pair + fast-decaying 1:11 tine pair,
                 velocity -> brightness, stereo chorus.

Run (from E:\\26Embedded\\sim):
    python scripts\\realtime_demo.py --list
    python scripts\\realtime_demo.py --render out\\demo\\rt_ep.wav --timbre epiano --auto
    python scripts\\realtime_demo.py                    # live keyboard
    python scripts\\realtime_demo.py --auto             # live auto phrase
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from collections import deque
from typing import Deque, List, Optional, Tuple

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

TWOPI = 2.0 * np.pi

ORGAN, MUSICBOX, EPIANO = 0, 1, 2
TIMBRE_NAMES = {ORGAN: "organ", MUSICBOX: "musicbox", EPIANO: "epiano"}
NAME_TO_TIMBRE = {v: k for k, v in TIMBRE_NAMES.items()}

# ---------------------------------------------------------------------------
# ORGAN -- Hammond-style drawbars (ratio, position 0..8); amp = 10^(-3*(8-pos)/20)
# ---------------------------------------------------------------------------
ORG_DRAWBARS = [
    (0.5, 6), (1.5, 5), (1.0, 8), (2.0, 7), (3.0, 6),
    (4.0, 5), (5.0, 4), (6.0, 3), (8.0, 2),
]
ORG_CLICK_AMP = 0.35           # key click = 6th harmonic ...
ORG_CLICK_DECAY_S = 0.070      # ... with a 70 ms decay
ORG_TREMOLO_HZ = 5.0           # tonewheel mechanical tremolo
ORG_TREMOLO_DEPTH = 0.030
ORG_ATTACK_MS, ORG_RELEASE_MS = 8.0, 90.0

# ---------------------------------------------------------------------------
# MUSIC BOX -- struck-bar modal template (ratio, amp, decay rate 1/s)
# ---------------------------------------------------------------------------
MB_MODES = [
    (1.000, 1.000, 0.40), (2.756, 0.600, 2.00), (5.404, 0.350, 5.00),
    (8.933, 0.200, 10.0), (13.344, 0.100, 18.0),
]
MB_JITTER_S = 0.011            # ~11 ms onset timing variance
MB_ATTACK_MS, MB_RELEASE_MS = 1.2, 25.0

# ---------------------------------------------------------------------------
# E.PIANO -- DX7 "E.PIANO 1": body pair 1:1, tine pair 1:11, both indices decay
# ---------------------------------------------------------------------------
EP_BELL_RATIO = 11.0
EP_BODY_IDX0, EP_BODY_IDX1, EP_BODY_TAU = 1.10, 0.35, 0.50
EP_TINE_IDX0, EP_TINE_TAU = 1.90, 0.11
EP_ATTACK_MS, EP_RELEASE_MS = 3.0, 220.0

TIMBRE_GAIN = {ORGAN: 0.80, MUSICBOX: 0.95, EPIANO: 2.00}


def midi_to_freq(note: int) -> float:
    return 440.0 * (2.0 ** ((note - 69) / 12.0))


def _drawbar_amp(pos: int) -> float:
    return 10.0 ** (-3.0 * (8 - pos) / 20.0)


# ===========================================================================
# Voice
# ===========================================================================
class RTVoice:
    def __init__(self, sr: int, block: int, rng: np.random.Generator) -> None:
        self.sr = sr
        self._tt = np.arange(block, dtype=np.float64) / sr
        self._idx = np.arange(block, dtype=np.float64)
        self.rng = rng
        self.active = False
        self.note = 0
        self.vel = 0.0
        self.timbre = ORGAN
        self.freq = 440.0
        self.base = 0.0
        self.age = 0
        self.rel = -1
        self.gain = 0.0

    def note_on(self, note: int, vel: float, timbre: int) -> None:
        self.active = True
        self.note = note
        self.vel = float(vel)
        self.timbre = timbre
        self.freq = midi_to_freq(note)
        self.base = 0.0
        self.age = 0
        self.rel = -1
        self.gain = 0.0

    def note_off(self) -> None:
        if self.active and self.rel < 0:
            self.rel = 0

    def _target_gain(self, n: int) -> float:
        atk = {ORGAN: ORG_ATTACK_MS, MUSICBOX: MB_ATTACK_MS, EPIANO: EP_ATTACK_MS}[self.timbre]
        atk_n = max(1, int(atk / 1000.0 * self.sr))
        if self.rel >= 0:
            return 0.0
        if self.age < atk_n:
            return self.vel * (self.age / float(atk_n))
        if self.timbre == EPIANO:
            return self.vel * (0.45 + 0.55 * np.exp(-(self.age - atk_n) / (0.7 * self.sr)))
        return self.vel

    # -- timbre synthesis ---------------------------------------------------
    def _render_organ(self, n: int) -> np.ndarray:
        ph = self.base + TWOPI * self.freq * self._tt[:n]
        out = np.zeros(n)
        nyq = self.sr / 2.0
        for r, pos in ORG_DRAWBARS:
            if r * self.freq < nyq:
                out += _drawbar_amp(pos) * np.sin(r * ph)
        out += ORG_CLICK_AMP * np.exp(-self.age / (ORG_CLICK_DECAY_S * self.sr)) * np.sin(6.0 * ph)
        return out

    def _render_musicbox(self, n: int) -> np.ndarray:
        ph = self.base + TWOPI * self.freq * self._tt[:n]
        age = self.age + self._idx[:n]
        out = np.zeros(n)
        nyq = self.sr / 2.0
        for r, a, lam in MB_MODES:
            if r * self.freq >= 0.95 * nyq:
                continue
            out += a * np.exp(-lam * age / self.sr) * np.sin(r * ph)
        return out

    def _render_epiano(self, n: int) -> np.ndarray:
        ph = self.base + TWOPI * self.freq * self._tt[:n]
        age = self.age + self._idx[:n]
        f = self.freq
        v = 0.55 + 0.45 * self.vel                       # velocity -> brightness
        i_body = (EP_BODY_IDX1 + (EP_BODY_IDX0 - EP_BODY_IDX1)
                  * np.exp(-age / (EP_BODY_TAU * self.sr))) * v
        modf = EP_BELL_RATIO * f
        i_cap = max(0.0, (self.sr / 2.0) / (2.0 * modf) - 1.0) if modf > 0 else 0.0
        i_tine = min(i_cap, EP_TINE_IDX0 * v) * np.exp(-age / (EP_TINE_TAU * self.sr))
        out = np.sin(ph + i_body * np.sin(ph) + i_tine * np.sin(EP_BELL_RATIO * ph))
        return out

    def render(self, n: int) -> np.ndarray:
        fn = (self._render_organ, self._render_musicbox, self._render_epiano)[self.timbre]
        raw = fn(n) * TIMBRE_GAIN[self.timbre]
        g1 = self._target_gain(n)
        g = np.linspace(self.gain, g1, n, endpoint=False)
        self.gain = g1
        out = raw * g
        self.age += n
        self.base += TWOPI * self.freq * n / self.sr
        if self.rel >= 0:
            self.rel += n
            rel_n = int({ORGAN: ORG_RELEASE_MS, MUSICBOX: MB_RELEASE_MS,
                         EPIANO: EP_RELEASE_MS}[self.timbre] / 1000.0 * self.sr)
            if self.gain < 1e-4 and self.rel > rel_n:
                self.active = False
        return out


# ===========================================================================
# stereo effects
# ===========================================================================
class Leslie:
    """Rotary speaker: amplitude modulation + Doppler (fractional delay), stereo."""

    def __init__(self, sr: int, rate: float = 6.8, am_depth: float = 0.32,
                 doppler_ms: float = 1.6, base_ms: float = 6.0) -> None:
        self.sr = sr
        self.rate = rate
        self.am = am_depth
        self.n = int(0.03 * sr)
        self.buf = np.zeros(self.n)
        self.w = 0
        self.base = base_ms / 1000.0 * sr
        self.dop = doppler_ms / 1000.0 * sr
        self.ph = 0.0

    def _read(self, delay: float) -> float:
        r = self.w - delay
        i0 = int(np.floor(r)) % self.n
        frac = r - np.floor(r)
        i1 = (i0 + 1) % self.n
        return self.buf[i0] * (1.0 - frac) + self.buf[i1] * frac

    def process(self, mono: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
        n = len(mono)
        L = np.empty(n)
        R = np.empty(n)
        inc = TWOPI * self.rate / self.sr
        for i in range(n):
            self.buf[self.w] = mono[i]
            wet = self._read(self.base + self.dop * np.sin(self.ph))
            amL = 1.0 - self.am * 0.5 * (1.0 + np.sin(self.ph))
            amR = 1.0 - self.am * 0.5 * (1.0 + np.sin(self.ph + np.pi / 2.0))
            L[i] = 0.35 * mono[i] + 0.65 * wet * amL
            R[i] = 0.35 * mono[i] + 0.65 * wet * amR
            self.w = (self.w + 1) % self.n
            self.ph = (self.ph + inc) % TWOPI
        return L, R


class StereoChorus:
    def __init__(self, sr: int, base_ms: float = 16.0, depth_ms: float = 3.0) -> None:
        self.sr = sr
        self.n = int(0.04 * sr)
        self.buf = np.zeros(self.n)
        self.w = 0
        self.base = base_ms / 1000.0 * sr
        self.depth = depth_ms / 1000.0 * sr
        self.phL = 0.0
        self.phR = np.pi / 2.0

    def _read(self, delay: float) -> float:
        r = self.w - delay
        i0 = int(np.floor(r)) % self.n
        frac = r - np.floor(r)
        i1 = (i0 + 1) % self.n
        return self.buf[i0] * (1.0 - frac) + self.buf[i1] * frac

    def process(self, mono: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
        n = len(mono)
        L = np.empty(n)
        R = np.empty(n)
        incL = TWOPI * 0.6 / self.sr
        incR = TWOPI * 0.85 / self.sr
        for i in range(n):
            x = mono[i]
            self.buf[self.w] = x
            dL = self.base + self.depth * 0.5 * (1.0 + np.sin(self.phL))
            dR = self.base + self.depth * 0.5 * (1.0 + np.sin(self.phR))
            L[i] = 0.6 * x + 0.4 * self._read(dL)
            R[i] = 0.6 * x + 0.4 * self._read(dR)
            self.w = (self.w + 1) % self.n
            self.phL = (self.phL + incL) % TWOPI
            self.phR = (self.phR + incR) % TWOPI
        return L, R


# ===========================================================================
# Engine
# ===========================================================================
class Engine:
    def __init__(self, sr: int = 48000, block: int = 256, max_voices: int = 16) -> None:
        self.sr = sr
        self.block = block
        self.rng = np.random.default_rng(2026)
        self.voices = [RTVoice(sr, block, self.rng) for _ in range(max_voices)]
        self.timbre = ORGAN
        self.events: Deque[Tuple[int, int, int, float]] = deque()
        self.pos = 0
        self.fx = {ORGAN: Leslie(sr), EPIANO: StereoChorus(sr), MUSICBOX: None}
        self.tremolo_ph = 0.0

    def note_on(self, note: int, vel: float = 0.9, at: Optional[int] = None) -> None:
        self.events.append((self.pos if at is None else at, 1, note, vel))

    def note_off(self, note: int, at: Optional[int] = None) -> None:
        self.events.append((self.pos if at is None else at, 0, note, 0.0))

    def set_timbre(self, timbre: int) -> None:
        self.timbre = timbre

    def _dispatch(self, on: int, note: int, vel: float) -> None:
        if on:
            free = next((v for v in self.voices if not v.active), None)
            if free is None:
                free = min(self.voices, key=lambda v: v.age)
            free.note_on(note, vel, self.timbre)
        else:
            for v in self.voices:
                if v.active and v.note == note and v.rel < 0:
                    v.note_off()

    def render_block(self) -> np.ndarray:
        n = self.block
        end = self.pos + n
        while self.events and self.events[0][0] <= end:
            _, on, note, vel = self.events.popleft()
            self._dispatch(on, note, vel)
        acc = np.zeros(n)
        for v in self.voices:
            if v.active:
                acc += v.render(n)
        acc *= 0.5
        if self.timbre == ORGAN:
            t = np.arange(n) / self.sr
            acc *= (1.0 + ORG_TREMOLO_DEPTH * np.sin(self.tremolo_ph + TWOPI * ORG_TREMOLO_HZ * t))
            self.tremolo_ph = (self.tremolo_ph + TWOPI * ORG_TREMOLO_HZ * n / self.sr) % TWOPI
        np.clip(acc, -1.0, 1.0, out=acc)
        fx = self.fx.get(self.timbre)
        L, R = fx.process(acc) if fx is not None else (acc, acc)
        self.pos = end
        return np.column_stack((L, R))

    def active_voices(self) -> int:
        return sum(1 for v in self.voices if v.active)


# ===========================================================================
# phrase
# ===========================================================================
PHRASE = [
    (60, 0.0, 0.35), (64, 0.35, 0.35), (67, 0.70, 0.35), (72, 1.05, 0.45),
    (60, 1.70, 1.70), (64, 1.70, 1.70), (67, 1.70, 1.70), (71, 1.70, 1.70),
]


def schedule_phrase(engine: Engine, sr: int, jitter_s: float = 0.0) -> None:
    rng = np.random.default_rng(7)
    for midi, s, dur in PHRASE:
        j = float(rng.normal(0.0, jitter_s)) if jitter_s > 0 else 0.0
        t0 = max(0.0, s + j)
        engine.note_on(midi, 0.9, at=int(t0 * sr))
        engine.note_off(midi, at=int((t0 + dur) * sr))


# ===========================================================================
# drivers
# ===========================================================================
def run_offline(path: str, sr: int, block: int, seconds: float, timbre: int, auto: bool) -> int:
    eng = Engine(sr=sr, block=block)
    eng.set_timbre(timbre)
    if auto:
        schedule_phrase(eng, sr, jitter_s=MB_JITTER_S if timbre == MUSICBOX else 0.0)
    else:
        for midi in (60, 64, 67):
            eng.note_on(midi, 0.9)
    total = int(seconds * sr)
    chunks: List[np.ndarray] = []
    done = 0
    while done < total:
        chunks.append(eng.render_block())
        done += block
    audio = np.concatenate(chunks)[:total]
    from synthsim.render import write_wav
    mono = 0.5 * (audio[:, 0] + audio[:, 1])
    write_wav(path, mono, sr)
    print("offline render: %-9s -> %s  %.2fs  peak=%.3f"
          % (TIMBRE_NAMES[timbre], path, total / sr, float(np.max(np.abs(mono)))))
    return 0


KEYMAP = {c: 60 + i for i, c in enumerate("awsedftgyhujkl")}
TIMBRE_KEYS = {"1": ORGAN, "2": MUSICBOX, "3": EPIANO}


def run_realtime(sr: int, block: int, device: Optional[int], auto: bool) -> int:
    try:
        import sounddevice as sd
    except Exception as exc:
        print("sounddevice unavailable (%s)." % exc)
        print("Running interpreter: %s" % sys.executable)
        print("Fix: run with the interpreter that has sounddevice, e.g.")
        print("    \"C:\\Users\\15812\\AppData\\Local\\Programs\\Python\\Python38\\python.exe\" \"%s\"" % os.path.abspath(__file__))
        print("or install it there:  \"%s\" -m pip install sounddevice" % sys.executable)
        return 2

    eng = Engine(sr=sr, block=block)
    status = {"n": 0}

    def callback(outdata, frames, time_info, st) -> None:
        if st:
            status["n"] += 1
        out = eng.render_block()
        outdata[:] = out[:frames].astype(np.float32)

    print("stream: sr=%d block=%d latency=%.2f ms  timbre=%s"
          % (sr, block, block / sr * 1000.0, TIMBRE_NAMES[eng.timbre]))
    print("keys a w s e d f t g y h u j k l | 1=organ 2=musicbox 3=e-piano | q=quit")
    if auto:
        schedule_phrase(eng, sr, jitter_s=MB_JITTER_S)

    with sd.OutputStream(samplerate=sr, blocksize=block, channels=2,
                         dtype="float32", device=device, callback=callback):
        _keyboard_loop(eng, auto)
    print("stream closed, status flags=%d" % status["n"])
    return 0


def _keyboard_loop(eng: Engine, auto: bool) -> None:
    try:
        import ctypes
        user32 = ctypes.windll.user32
    except Exception:
        print("no keyboard input - running 6 s")
        time.sleep(6.0)
        return

    def down(vk: int) -> bool:
        return bool(user32.GetAsyncKeyState(vk) & 0x8000)

    prev = {c: False for c in KEYMAP}
    prev_t = {c: False for c in TIMBRE_KEYS}
    prev_q = False
    t0 = time.time()
    while True:
        if auto and (time.time() - t0) > 6.0:
            break
        if (not auto) and (time.time() - t0) > 300.0:
            break
        for c, tim in TIMBRE_KEYS.items():
            d = down(ord(c))
            if d and not prev_t[c]:
                eng.set_timbre(tim)
                print("timbre -> %s" % TIMBRE_NAMES[tim])
            prev_t[c] = d
        for c, note in KEYMAP.items():
            d = down(ord(c.upper()))
            if d and not prev[c]:
                eng.note_on(note, 0.9)
            elif (not d) and prev[c]:
                eng.note_off(note)
            prev[c] = d
        dq = down(ord("Q"))
        if dq and not prev_q:
            break
        prev_q = dq
        time.sleep(0.004)


def main() -> int:
    ap = argparse.ArgumentParser(description="real-time synth demo")
    ap.add_argument("--sr", type=int, default=48000)
    ap.add_argument("--blocksize", type=int, default=256)
    ap.add_argument("--device", type=int, default=None)
    ap.add_argument("--auto", action="store_true")
    ap.add_argument("--render", metavar="WAV")
    ap.add_argument("--timbre", choices=list(NAME_TO_TIMBRE), default="organ")
    ap.add_argument("--seconds", type=float, default=4.0)
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if args.list:
        import sounddevice as sd
        print(sd.query_devices())
        return 0
    if args.render:
        return run_offline(args.render, args.sr, args.blocksize, args.seconds,
                           NAME_TO_TIMBRE[args.timbre], args.auto)
    return run_realtime(args.sr, args.blocksize, args.device, args.auto)


if __name__ == "__main__":
    sys.exit(main())
