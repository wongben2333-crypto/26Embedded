"""Timbral demo for the synthsim golden model: organ / music box / e-piano.

Renders the SAME short phrase through three timbres so they can be compared
ear-by-ear, writes ``out\\demo\\*.wav``, and prints a one-line spectral summary
for each.  It reuses the golden model where it matters (ADSR envelope, chorus
effect, WAV I/O); the timbre-specific partial/FM synthesis lives here and
mirrors the per-oscillator structure that will later become RTL.

Run (from E:\\26Embedded\\sim):
    python scripts\\demo_timbres.py            # render WAVs
    python scripts\\demo_timbres.py --play     # render + autoplay on Windows
"""
from __future__ import annotations

import argparse
import os
import sys
from typing import Callable, List, Optional, Tuple

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from synthsim.params import PARAMS_48K  # noqa: E402
from synthsim.adsr import adsr_envelope  # noqa: E402
from synthsim.effects import chorus  # noqa: E402
from synthsim.render import write_wav  # noqa: E402

SR = PARAMS_48K.sr
OUT = os.path.join(ROOT, "out", "demo")
os.makedirs(OUT, exist_ok=True)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def _time(dur: float) -> np.ndarray:
    return np.arange(int(round(dur * SR)), dtype=np.float64) / float(SR)


def _midi_to_freq(note: int) -> float:
    return 440.0 * (2.0 ** ((note - 69) / 12.0))


def _env(n: int, attack_ms: float, release_ms: float, sustain: float = 1.0,
         decay_ms: float = 1.0, curve: str = "lin") -> np.ndarray:
    """Global amplitude envelope via the golden-model ADSR (one-shot)."""
    rel = max(1, int(round(release_ms / 1000.0 * SR)))
    off = max(0, n - rel)
    return adsr_envelope(n, SR, attack_ms, decay_ms, sustain, release_ms,
                         note_off_sample=off, curve=curve)


def _norm(x: np.ndarray, target: float = 0.9) -> np.ndarray:
    peak = float(np.max(np.abs(x))) if x.size else 0.0
    return x if peak <= 0.0 else x * (target / peak)


# ---------------------------------------------------------------------------
# 1. ORGAN -- additive drawbar harmonics, fully sustained (steady spectrum)
# ---------------------------------------------------------------------------
def synth_organ(freq: float, dur: float, vel: float = 1.0) -> np.ndarray:
    t = _time(dur)
    # Hammond-like drawbar registration: fundamental, octaves and fifths
    ratios = [1.0, 2.0, 3.0, 4.0, 6.0, 8.0]
    amps = [1.00, 0.85, 0.72, 0.50, 0.33, 0.22]
    out = np.zeros_like(t)
    for r, a in zip(ratios, amps):
        if r * freq >= SR / 2.0:          # Nyquist guard
            continue
        out += a * np.sin(2.0 * np.pi * r * freq * t)
    out *= _env(len(t), attack_ms=12.0, release_ms=90.0, sustain=1.0)
    return vel * out


# ---------------------------------------------------------------------------
# 2. MUSIC BOX -- a few INHARMONIC bar partials, each with its own fast decay
# ---------------------------------------------------------------------------
def synth_musicbox(freq: float, dur: float, vel: float = 1.0) -> np.ndarray:
    t = _time(dur)
    # (frequency ratio, amplitude, decay time constant in seconds)
    partials = [
        (1.00, 1.00, 1.60),
        (2.76, 0.42, 0.90),
        (5.40, 0.22, 0.55),
        (8.93, 0.12, 0.33),
        (13.3, 0.06, 0.20),
    ]
    out = np.zeros_like(t)
    for r, a, tau in partials:
        if r * freq >= SR / 2.0:          # Nyquist guard
            continue
        out += a * np.exp(-t / tau) * np.sin(2.0 * np.pi * r * freq * t)
    out *= _env(len(t), attack_ms=1.5, release_ms=25.0, sustain=1.0)
    return vel * out


# ---------------------------------------------------------------------------
# 3. ELECTRIC PIANO -- 2-operator FM with a fast-decaying high-ratio "tine"
# ---------------------------------------------------------------------------
def synth_epiano(freq: float, dur: float, vel: float = 1.0) -> np.ndarray:
    t = _time(dur)
    nyq = SR / 2.0
    # 2-operator FM, modulator ratio 1 -> bell-like E.Piano body.
    # FM bandwidth ~= 2*(index+1)*f, kept well under Nyquist (no aliasing).
    idx = 1.9 * np.exp(-t / 0.16) + 0.35
    phase = 2.0 * np.pi * freq * t + idx * np.sin(2.0 * np.pi * freq * t)
    out = np.sin(phase) + 0.25 * np.sin(2.0 * np.pi * freq * t)
    # metallic "tine" ping: a high partial with a very fast decay
    tine_ratio = 6.0
    if freq * tine_ratio < nyq:
        out += 0.30 * np.exp(-t / 0.05) * np.sin(2.0 * np.pi * tine_ratio * freq * t)
    out *= _env(len(t), attack_ms=4.0, release_ms=200.0, sustain=0.45,
                decay_ms=700.0, curve="exp")
    return vel * out


# ---------------------------------------------------------------------------
# phrase: same notes for every timbre -> easy A/B comparison
#   C major arpeggio (C4 E4 G4 C5) then a held Cmaj7 chord
# ---------------------------------------------------------------------------
PHRASE: List[Tuple[int, float, float]] = [
    (60, 0.00, 0.35), (64, 0.35, 0.35), (67, 0.70, 0.35), (72, 1.05, 0.45),
    (60, 1.70, 1.70), (64, 1.70, 1.70), (67, 1.70, 1.70), (71, 1.70, 1.70),
]
PHRASE_LEN = 3.55  # seconds


def build_phrase(synth: Callable[[float, float, float], np.ndarray]) -> np.ndarray:
    n = int(round(PHRASE_LEN * SR))
    buf = np.zeros(n, dtype=np.float64)
    for midi, start, dur in PHRASE:
        w = synth(_midi_to_freq(midi), dur, 0.9)
        s = int(round(start * SR))
        e = min(n, s + len(w))
        buf[s:e] += w[:e - s]
    return _norm(buf, 0.9)


def summarize(x: np.ndarray) -> Tuple[float, int]:
    n = len(x)
    spec = np.abs(np.fft.rfft(x * np.hanning(n)))
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    centroid = float((freqs * spec).sum() / (spec.sum() + 1e-20))
    try:
        from scipy.signal import find_peaks
        pk, _ = find_peaks(spec, height=spec.max() * 0.05)
        npeaks = int(len(pk))
    except Exception:
        npeaks = -1
    return centroid, npeaks


def render_timbre(name: str, synth: Callable[[float, float, float], np.ndarray],
                  fx: Optional[Callable[[np.ndarray], np.ndarray]] = None) -> np.ndarray:
    x = build_phrase(synth)
    if fx is not None:
        x = _norm(fx(x), 0.9)
    path = os.path.join(OUT, name + ".wav")
    write_wav(path, x, SR)
    cent, npeaks = summarize(x)
    print("  %-9s -> %-28s  %.2fs  peak=%.3f  centroid=%7.1f Hz  peaks=%d"
          % (name, os.path.basename(path), len(x) / SR,
             float(np.max(np.abs(x))), cent, npeaks))
    return x


def autoplay(paths: List[str]) -> None:
    if sys.platform != "win32":
        print("[play] skipped (winsound is Windows-only)")
        return
    try:
        import winsound  # type: ignore
    except Exception as exc:  # pragma: no cover
        print("[play] winsound unavailable: %s" % exc)
        return
    for p in paths:
        print("[play] %s" % os.path.basename(p))
        winsound.PlaySound(p, winsound.SND_FILENAME)


def main() -> int:
    ap = argparse.ArgumentParser(description="Timbral demo: organ / music box / e-piano")
    ap.add_argument("--play", action="store_true", help="autoplay the WAVs on Windows")
    args = ap.parse_args()

    print("timbral demo @ %d Hz -> %s" % (SR, OUT))
    print("phrase: C-E-G-C arpeggio + held Cmaj7 chord (same for all timbres)")

    paths: List[str] = []
    chunks: List[np.ndarray] = []

    organ = render_timbre("organ", synth_organ)
    paths.append(os.path.join(OUT, "organ.wav"))
    chunks.append(organ)

    musicbox = render_timbre("musicbox", synth_musicbox)
    paths.append(os.path.join(OUT, "musicbox.wav"))
    chunks.append(musicbox)

    epiano = render_timbre("epiano", synth_epiano,
                           fx=lambda x: chorus(x, SR, depth_ms=2.5,
                                               rate_hz=0.8, base_ms=18.0, mix=0.45))
    paths.append(os.path.join(OUT, "epiano.wav"))
    chunks.append(epiano)

    # combined demo: timbre, gap, timbre, gap, timbre
    gap = np.zeros(int(0.4 * SR), dtype=np.float64)
    combined: List[np.ndarray] = []
    for c in chunks:
        combined.append(c)
        combined.append(gap)
    allx = np.concatenate(combined[:-1])
    allx = _norm(allx, 0.92)
    all_path = os.path.join(OUT, "demo_all.wav")
    write_wav(all_path, allx, SR)
    paths.append(all_path)
    print("  %-9s -> %-28s  %.2fs" % ("all", os.path.basename(all_path), len(allx) / SR))

    if args.play:
        autoplay(paths)

    print("demo OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
