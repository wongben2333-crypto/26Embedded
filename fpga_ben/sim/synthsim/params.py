"""Global parameters for the FPGA polyphonic-synth golden model.

Mirrors the intended RTL parameter set one-to-one.  This file is FROZEN by the
interface contract (see CONTRACT.md) -- every other module imports it, and
``export_params.py`` re-emits it as a Verilog header ``synth_params.vh``.

Stage plan (see project decisions):
  * Stage 1 : sr = 48000, 32 voices  (safe target)
  * Stage 2 : sr = 96000, 32 voices  (score-doubling target)

Python >= 3.8 compatible (no PEP-604 unions at runtime, no match statement).
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class SynthParams:
    # ---- clock / audio interface -------------------------------------------
    sr: int = 48000                     # I2S output sample rate (Hz)
    master_clk_hz: int = 100_000_000    # FPGA fabric clock used by the RTL

    # ---- oscillator --------------------------------------------------------
    phase_bits: int = 32                # phase accumulator width
    table_size: int = 1024              # wavetable entries per mip level
    table_bits: int = 16                # wavetable sample width (signed)
    interp: str = "linear"              # "none" | "linear"

    # ---- envelope (ADSR) ---------------------------------------------------
    env_bits: int = 16                  # envelope amplitude width
    adsr_attack_ms: float = 5.0
    adsr_decay_ms: float = 120.0
    adsr_sustain: float = 0.70
    adsr_release_ms: float = 180.0
    adsr_curve: str = "exp"             # "lin" | "exp"

    # ---- polyphony / mixing ------------------------------------------------
    max_voices: int = 32                # 4 -> 8 -> 16 -> 32
    voice_gain_shift: int = 5           # right shift applied to each voice before sum
    saturate: bool = True               # hard-limit the mixed bus

    # ---- wavetable anti-aliasing (mipmap) ----------------------------------
    mip_octaves: int = 8                # number of band-limited tables
    base_max_harmonics: int = 512       # harmonics in the brightest (lowest) table

    # ---- latency budget ----------------------------------------------------
    i2s_fifo_depth: int = 4             # samples per channel (keep SHALLOW!)
    scan_block: int = 1                 # key-scan update period, in samples

    # ---- test mode (rule 3: N independent spectral peaks) ------------------
    test_tones: int = 32
    test_f0_hz: float = 200.0
    test_spacing_hz: float = 200.0
    test_seconds: float = 2.0

    # ---- derived helpers ---------------------------------------------------
    @property
    def nyquist(self) -> float:
        return self.sr / 2.0

    def freq_word(self, freq_hz: float) -> int:
        """Phase increment (tuning word) for a target frequency, rounded."""
        return int(round(freq_hz / self.sr * (1 << self.phase_bits)))

    def with_sr(self, sr: int) -> "SynthParams":
        """Return a copy at a different sample rate (stage 1 -> stage 2)."""
        clone = SynthParams(**self.__dict__)
        clone.sr = int(sr)
        return clone


# Convenient module-level defaults -------------------------------------------
PARAMS_48K = SynthParams(sr=48000)
PARAMS_96K = SynthParams(sr=96000)

# Target device: Sipeed Tang Mega 138K Dock (GW5AST-LV138PG484A) --------------
DEVICE = {
    "name": "GW5AST-LV138PG484A (Tang Mega 138K Dock)",
    "lut": 138240,
    "ff": 138240,
    "dsp": 298,          # 18x18 multipliers
    "bsram_kb": 6120,    # B-SRAM bits / 8
    "pll": 12,
}
