"""End-to-end latency budget for the polyphonic synth.

Answers analysis question (c): does the full chain meet TOTAL <= 5.0 ms?

Adds up every registered stage between "a key event is scanned" and "the
analog sample leaves the DAC", in sample periods, and converts to ms for a
given sample rate.  Stage latencies are engineering assumptions documented at
their definition sites; the I2S FIFO uses the frozen ``params.i2s_fifo_depth``.

Python 3.8 compatible: typing.* only, no PEP-604 unions, no match statement.
"""
from __future__ import annotations

from typing import List, Tuple

from .params import PARAMS_48K, SynthParams

#: Master clock of the target board; mirrors params.master_clk_hz (FROZEN).
MASTER_CLK_HZ = 100_000_000

#: Per-voice time-multiplexed processing cost in master-clock cycles.
#: Assumption: phase step + dual B-SRAM read + 8x16 interpolation multiply +
#: envelope step + 18x18 amplitude multiply + mixer accumulate ~= 32 cycles.
CYCLES_PER_VOICE_SAMPLE = 32

#: Keep the synth core at <= 50% of the sample period (headroom for control,
#: key scan, I2S, UI).
UTIL_MARGIN = 0.5

# ---------------------------------------------------------------------------
# Stage latencies, in sample periods (documented assumptions).
# ---------------------------------------------------------------------------

# Controller scan: params.scan_block = 1 sample between key-matrix updates.
SCAN_SAMPLES = 1

# Digital debounce of the scanned keys: 2 samples (~42 us at 48 kHz).
# Assumption: mechanical contact-bounce time is NOT part of the audio latency
# path (it only delays note-on detection of a held key, not the audio).
DEBOUNCE_SAMPLES = 2

# Synthesis pipeline: phase -> table read -> interpolation -> envelope ->
# amplitude multiply -> mix.  Assumption: one registered stage per sample
# period = 5 samples.
PIPELINE_SAMPLES = 5

# Wavetable fetch: B-SRAM read is registered (1 sample).
WTABLE_FETCH_SAMPLES = 1

# Envelope update: registered level update (1 sample).
ENV_UPDATE_SAMPLES = 1

# Mixer: adder tree + saturation/register.  Assumption: the (up to) 32-input
# tree is pipelined in 2 register levels = 2 samples.
MIXER_SAMPLES = 2

# DAC/serialization: I2S serializer shift-out + DAC conversion (1 sample).
DAC_SAMPLES = 1


def budget(params: "SynthParams") -> List[Tuple[str, float, float]]:
    """Full-chain latency budget: [(stage_name, samples, ms), ...].

    The list ends with ("TOTAL", total_samples, total_ms).  Sample counts are
    floats so fractional stages (e.g. FIFO depth) stay exact.
    """
    sr = float(params.sr)
    ms_per_sample = 1000.0 / sr
    stages = [
        ("input scan/debounce", SCAN_SAMPLES + DEBOUNCE_SAMPLES),
        ("synthesis pipeline", PIPELINE_SAMPLES),
        ("wavetable fetch", WTABLE_FETCH_SAMPLES),
        ("envelope update", ENV_UPDATE_SAMPLES),
        ("mixer", MIXER_SAMPLES),
        ("I2S FIFO", float(params.i2s_fifo_depth)),
        ("DAC/serialization", DAC_SAMPLES),
    ]
    rows = []  # type: List[Tuple[str, float, float]]
    total = 0.0
    for name, samples in stages:
        total += samples
        rows.append((name, samples, samples * ms_per_sample))
    rows.append(("TOTAL", total, total * ms_per_sample))
    return rows


def max_voices_at_sr(sr: int) -> int:
    """Max polyphony sustainable at ``sr`` with the core at <= UTIL_MARGIN duty.

    cycles_per_sample = MASTER_CLK_HZ / sr; each voice costs
    CYCLES_PER_VOICE_SAMPLE cycles (assumption, see module constants).
    48 kHz -> 32 voices, 96 kHz -> 16 voices with margin (32 voices at 96 kHz
    would leave ~0% core headroom with this per-voice cost).
    """
    cycles_per_sample = MASTER_CLK_HZ / float(sr)
    voices = int(cycles_per_sample / CYCLES_PER_VOICE_SAMPLE * UTIL_MARGIN)
    return max(1, voices)


def _self_test() -> None:
    for sr, params in ((48000, PARAMS_48K), (96000, PARAMS_48K.with_sr(96000))):
        rows = budget(params)
        print("Latency budget @ %d Hz (requirement: TOTAL <= 5.0 ms)" % sr)
        print("%-22s %10s %10s" % ("stage", "samples", "ms"))
        for name, samples, ms in rows:
            print("%-22s %10.1f %10.3f" % (name, samples, ms))
        total_ms = rows[-1][2]
        fifo_ms = 0.0
        for name, _, ms in rows:
            if name == "I2S FIFO":
                fifo_ms = ms
                break
        verdict = "<=" if total_ms <= 5.0 else ">"
        print("TOTAL %.3f ms %s 5.0 ms  ->  budget %s"
              % (total_ms, verdict,
                 "MET" if total_ms <= 5.0 else "EXCEEDED"))
        print("I2S FIFO (depth %d) contributes %.3f ms = %.1f%% of the budget"
              % (params.i2s_fifo_depth, fifo_ms, fifo_ms / total_ms * 100.0))
        print("max voices at %d Hz (core at <= %.0f%% duty): %d"
              % (sr, UTIL_MARGIN * 100.0, max_voices_at_sr(sr)))
        print()

    # Deep-FIFO counterfactual: a deep FIFO alone blows the 5.0 ms budget.
    print("Counterfactual: if i2s_fifo_depth were 256 (a 'generous' FIFO):")
    for sr in (48000, 96000):
        deep_ms = 256 * 1000.0 / sr
        print("  256 samples @ %d Hz = %.3f ms (%.1fx the whole 5.0 ms budget)"
              % (sr, deep_ms, deep_ms / 5.0))
    print("=> keep the I2S FIFO SHALLOW (params.i2s_fifo_depth = %d); "
          "a deep FIFO is the only term that can blow the budget."
          % PARAMS_48K.i2s_fifo_depth)


if __name__ == "__main__":
    _self_test()
